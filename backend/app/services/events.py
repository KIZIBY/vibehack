"""Шина событий проекта в памяти процесса: кольцевой буфер для повтора и живые подписчики (источник SSE)."""
import asyncio
import json
import threading
import time
from collections import deque
from dataclasses import dataclass
from typing import Any, Callable, Deque, Dict, Optional, Set

EVENT_TYPES = frozenset({
    "submission.inventory_ready", "rubric.drafted", "run.progress", "run.completed", "score.changed", "message.created",
})


@dataclass(frozen=True)
class Event:
    id: int
    type: str
    data: Any
    ts: float


def _set_result(future: "asyncio.Future") -> None:
    if not future.done():
        future.set_result(None)


class Subscription:
    """Асинхронный итератор событий одной подписки. Создаётся ``EventBus.subscribe`` и уже зарегистрирован."""

    def __init__(self, bus: "EventBus", project_id: str, backlog: list, queue_size: int):
        self._bus = bus
        self._lock = bus._lock
        self.project_id = project_id
        self._backlog: Deque[Event] = deque(backlog)
        self._queue: Deque[Event] = deque()
        self._queue_size = queue_size
        self._waiter = None
        self._closed = False
        self._dropped = False

    def __aiter__(self) -> "Subscription":
        return self

    async def __anext__(self) -> Event:
        while True:
            with self._lock:
                if self._backlog:
                    return self._backlog.popleft()
                if self._queue:
                    return self._queue.popleft()
                if self._closed or self._dropped:
                    raise StopAsyncIteration
                loop = asyncio.get_running_loop()
                future = loop.create_future()
                self._waiter = (loop, future)
            try:
                await future
            finally:
                with self._lock:
                    if self._waiter is not None and self._waiter[1] is future:
                        self._waiter = None

    async def aclose(self) -> None:
        with self._lock:
            self._closed = True
            self._backlog.clear()
            self._queue.clear()
            self._bus._detach(self)
            self._wake()

    # --- вызывается шиной под её блокировкой -----------------------------------------------------------

    def _push(self, event: Event) -> None:
        if self._closed or self._dropped:
            return
        if len(self._queue) >= self._queue_size:     # медленный потребитель: отключаем, публикатор не ждёт
            self._dropped = True
            self._bus._detach(self)
        else:
            self._queue.append(event)
        self._wake()

    def _wake(self) -> None:
        waiter, self._waiter = self._waiter, None
        if waiter is not None:
            loop, future = waiter
            try:
                loop.call_soon_threadsafe(_set_result, future)
            except RuntimeError:      # цикл уже закрыт
                pass


class _ProjectState:
    def __init__(self, max_buffer: int):
        self.last_id = 0
        self.buffer: Deque[Event] = deque(maxlen=max_buffer)
        self.subscribers: Set[Subscription] = set()


class EventBus:
    """Потокобезопасная шина: ``publish`` синхронный и никогда не блокируется на подписчиках.

    События живут только в памяти процесса: после перезапуска счётчик id начинается заново, а клиент по
    контракту перечитывает состояние через REST.
    """

    def __init__(self, clock: Callable[[], float] = time.time, retention: float = 300.0, max_buffer: int = 1000,
                 queue_size: int = 100):
        self._clock = clock
        self._retention = retention
        self._max_buffer = max_buffer
        self._queue_size = queue_size
        self._lock = threading.RLock()
        self._projects: Dict[str, _ProjectState] = {}

    def _state(self, project_id: str) -> _ProjectState:
        state = self._projects.get(project_id)
        if state is None:
            state = self._projects[project_id] = _ProjectState(self._max_buffer)
        return state

    def _prune(self, state: _ProjectState) -> None:
        now = self._clock()
        while state.buffer and now - state.buffer[0].ts > self._retention:
            state.buffer.popleft()

    def publish(self, project_id: str, event_type: str, data: Any) -> int:
        if not isinstance(project_id, str) or not project_id:
            raise ValueError("project_id: ожидается непустая строка")
        if event_type not in EVENT_TYPES:
            raise ValueError(f"неизвестный тип события: {event_type!r}")
        snapshot = json.loads(json.dumps(data, allow_nan=False))      # TypeError/ValueError до выдачи id
        with self._lock:
            state = self._state(project_id)
            self._prune(state)
            state.last_id += 1
            event = Event(state.last_id, event_type, snapshot, self._clock())
            state.buffer.append(event)
            for subscription in list(state.subscribers):
                subscription._push(event)
            return event.id

    def subscribe(self, project_id: str, last_event_id: Optional[int] = None) -> Subscription:
        if last_event_id is not None and (isinstance(last_event_id, bool) or not isinstance(last_event_id, int)):
            raise TypeError("last_event_id: ожидается целое число")
        with self._lock:
            state = self._state(project_id)
            self._prune(state)
            backlog = [] if last_event_id is None else [e for e in state.buffer if e.id > last_event_id]
            subscription = Subscription(self, project_id, backlog, self._queue_size)
            state.subscribers.add(subscription)
            return subscription

    def subscriber_count(self, project_id: str) -> int:
        with self._lock:
            state = self._projects.get(project_id)
            return len(state.subscribers) if state else 0

    def _detach(self, subscription: Subscription) -> None:
        with self._lock:
            state = self._projects.get(subscription.project_id)
            if state is not None:
                state.subscribers.discard(subscription)
