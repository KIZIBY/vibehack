"""T035: шина событий и SSE ``app.services.events`` + ``app.routers.events``. Тесты написаны ДО реализации (RED).

Контракт:
- ``EventBus(clock=time.time, retention=300.0, max_buffer=1000, queue_size=100)``;
  ``publish(project_id, event_type, data) -> int`` (синхронный, потокобезопасный; id монотонен в проекте;
  тип из белого списка, иначе ``ValueError``; data должен сериализоваться в JSON, иначе ``TypeError``/``ValueError``);
- ``subscribe(project_id, last_event_id=None)`` -> асинхронный итератор ``Event(id, type, data, ts)``, подписка
  оформляется при вызове (без щели до первого ``__anext__``): сначала повтор событий с id > last_event_id
  за окно ``retention`` (возраст ровно ``retention`` ещё входит), затем живые; ``aclose()`` отписывает;
  переполнение очереди (``queue_size``) отключает подписчика: уже поставленные в очередь события
  доставляются, затем итерация заканчивается; ``bus.subscriber_count(project_id)``;
- ``routers.events``: ``GET /api/v1/projects/{project_id}/events`` (``text/event-stream``, ``Cache-Control: no-cache``,
  ``X-Accel-Buffering: no``), кадр ``id: <n>\\nevent: <type>\\ndata: <JSON>\\n\\n``, ``Last-Event-ID``,
  heartbeat ``: ping\\n\\n`` (``app.state.sse_heartbeat``, по умолчанию 15 с), шина — ``get_event_bus(app)``
  (``app.state.event_bus`` или лениво созданная); ``event_stream(subscription, *, heartbeat)`` — генератор кадров.
  Неверная форма ``project_id`` -> 404, мусорный ``Last-Event-ID`` игнорируется.

httpx.ASGITransport не стримит, поэтому поток читается прямым вызовом ASGI-приложения.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import json
import time

import pytest

TYPES = ["submission.inventory_ready", "rubric.drafted", "run.progress", "run.completed", "score.changed", "message.created"]


class Clock:
    def __init__(self, now: float = 1000.0):
        self.now = now

    def __call__(self) -> float:
        return self.now


def run(coro):
    return asyncio.run(coro)


async def take(sub, count, timeout=1.0):
    return [await asyncio.wait_for(sub.__anext__(), timeout) for _ in range(count)]


async def assert_quiet(sub, delay=0.05):
    with pytest.raises(asyncio.TimeoutError):
        await asyncio.wait_for(sub.__anext__(), delay)


def make_bus(**kwargs):
    from app.services.events import EventBus
    return EventBus(**kwargs)


# --- EventBus --------------------------------------------------------------------------------------------


def test_publish_ids_monotonic_per_project():
    bus = make_bus()
    assert [bus.publish("p1", "run.progress", {"n": i}) for i in range(3)] == [1, 2, 3]
    assert bus.publish("p2", "run.completed", {}) == 1
    assert bus.publish("p1", "score.changed", {}) == 4


@pytest.mark.parametrize("event_type", ["", "run", "run.progress ", "RUN.PROGRESS", "x.y", "run.progress\nid: 9"])
def test_unknown_type_rejected(event_type):
    bus = make_bus()
    with pytest.raises(ValueError):
        bus.publish("p", event_type, {})
    assert bus.publish("p", "run.progress", {}) == 1      # id не потрачен на отклонённое событие


def test_all_whitelisted_types_accepted():
    bus = make_bus()
    for event_type in TYPES:
        bus.publish("p", event_type, {"ok": True})


def test_non_serializable_data_rejected_at_publish():
    bus = make_bus()
    with pytest.raises((TypeError, ValueError)):
        bus.publish("p", "run.progress", {"x": object()})
    assert bus.publish("p", "run.progress", {}) == 1


def test_live_delivery_in_order_and_event_fields():
    async def scenario():
        clock = Clock(5.0)
        bus = make_bus(clock=clock)
        sub = bus.subscribe("p")
        for i in range(3):
            bus.publish("p", "run.progress", {"i": i})
        events = await take(sub, 3)
        await sub.aclose()
        return events

    events = run(scenario())
    assert [e.id for e in events] == [1, 2, 3]
    assert [e.data for e in events] == [{"i": 0}, {"i": 1}, {"i": 2}]
    assert all(e.type == "run.progress" and e.ts == 5.0 for e in events)


def test_subscribe_without_last_event_id_gets_no_history():
    async def scenario():
        bus = make_bus()
        bus.publish("p", "run.progress", {"old": True})
        sub = bus.subscribe("p")
        await assert_quiet(sub)
        bus.publish("p", "run.progress", {"new": True})
        got = await take(sub, 1)
        await sub.aclose()
        return got

    assert run(scenario())[0].data == {"new": True}


def test_replay_after_last_event_id_then_live():
    async def scenario():
        bus = make_bus()
        for i in range(5):
            bus.publish("p", "run.progress", {"i": i})
        sub = bus.subscribe("p", last_event_id=2)
        replayed = await take(sub, 3)
        await assert_quiet(sub)
        bus.publish("p", "run.completed", {"status": "done"})
        live = await take(sub, 1)
        await sub.aclose()
        return replayed, live

    replayed, live = run(scenario())
    assert [e.id for e in replayed] == [3, 4, 5]
    assert live[0].id == 6 and live[0].type == "run.completed"


def test_replay_zero_means_everything_and_future_id_means_nothing():
    async def scenario():
        bus = make_bus()
        for _ in range(3):
            bus.publish("p", "run.progress", {})
        everything = bus.subscribe("p", last_event_id=0)
        nothing = bus.subscribe("p", last_event_id=99)
        got = await take(everything, 3)
        await assert_quiet(nothing)
        await everything.aclose()
        await nothing.aclose()
        return got

    assert [e.id for e in run(scenario())] == [1, 2, 3]


def test_replay_window_five_minutes_with_fake_clock():
    async def scenario():
        clock = Clock(1000.0)
        bus = make_bus(clock=clock, retention=300.0)
        bus.publish("p", "run.progress", {"at": 1000})           # id 1
        clock.now = 1100.0
        bus.publish("p", "run.progress", {"at": 1100})           # id 2
        clock.now = 1300.0                                       # возраст id 1 ровно 300 — ещё в окне
        in_window = [e.id for e in await take(bus.subscribe("p", last_event_id=0), 2)]
        clock.now = 1301.0                                       # id 1 старше 300 — вне окна
        sub = bus.subscribe("p", last_event_id=0)
        late = await take(sub, 1)
        await assert_quiet(sub)
        clock.now = 1401.0                                       # теперь вне окна и id 2
        empty = bus.subscribe("p", last_event_id=0)
        await assert_quiet(empty)
        for s in (sub, empty):
            await s.aclose()
        return in_window, late

    in_window, late = run(scenario())
    assert in_window == [1, 2]
    assert [e.id for e in late] == [2]


def test_ids_continue_after_buffer_expiry():
    clock = Clock(0.0)
    bus = make_bus(clock=clock, retention=10.0)
    bus.publish("p", "run.progress", {})
    clock.now = 100.0
    assert bus.publish("p", "run.progress", {}) == 2


def test_max_buffer_keeps_latest():
    async def scenario():
        bus = make_bus(max_buffer=3)
        for i in range(5):
            bus.publish("p", "run.progress", {"i": i})
        sub = bus.subscribe("p", last_event_id=0)
        got = await take(sub, 3)
        await assert_quiet(sub)
        await sub.aclose()
        return got

    assert [e.id for e in run(scenario())] == [3, 4, 5]


def test_project_isolation():
    async def scenario():
        bus = make_bus()
        a = bus.subscribe("a")
        b = bus.subscribe("b")
        bus.publish("a", "run.progress", {"p": "a"})
        bus.publish("b", "message.created", {"p": "b"})
        got_a = await take(a, 1)
        got_b = await take(b, 1)
        await assert_quiet(a)
        await assert_quiet(b)
        replay_b = bus.subscribe("b", last_event_id=0)
        replayed = await take(replay_b, 1)
        await assert_quiet(replay_b)
        for s in (a, b, replay_b):
            await s.aclose()
        return got_a, got_b, replayed

    got_a, got_b, replayed = run(scenario())
    assert got_a[0].data == {"p": "a"} and got_b[0].data == {"p": "b"} and replayed[0].data == {"p": "b"}


def test_many_subscribers_all_receive():
    async def scenario():
        bus = make_bus()
        subs = [bus.subscribe("p") for _ in range(5)]
        bus.publish("p", "score.changed", {"k": 1})
        results = [await take(s, 1) for s in subs]
        for s in subs:
            await s.aclose()
        return results

    assert all(r[0].id == 1 for r in run(scenario()))


def test_data_is_snapshotted_at_publish():
    async def scenario():
        bus = make_bus()
        payload = {"nested": {"v": 1}}
        bus.publish("p", "run.progress", payload)
        payload["nested"]["v"] = 2
        sub = bus.subscribe("p", last_event_id=0)
        got = await take(sub, 1)
        await sub.aclose()
        return got

    assert run(scenario())[0].data == {"nested": {"v": 1}}


def test_unsubscribe_on_aclose_and_pending_reader_wakes():
    async def scenario():
        bus = make_bus()
        sub = bus.subscribe("p")
        assert bus.subscriber_count("p") == 1
        waiter = asyncio.ensure_future(sub.__anext__())
        await asyncio.sleep(0.01)
        await sub.aclose()
        with pytest.raises(StopAsyncIteration):
            await asyncio.wait_for(waiter, 1)
        assert bus.subscriber_count("p") == 0
        with pytest.raises(StopAsyncIteration):
            await sub.__anext__()
        bus.publish("p", "run.progress", {})                     # публикация без подписчиков не падает
        await sub.aclose()                                       # повторное закрытие безопасно
        return bus.subscriber_count("p")

    assert run(scenario()) == 0


def test_cancelled_read_loses_no_event():
    async def scenario():
        bus = make_bus()
        sub = bus.subscribe("p")
        with pytest.raises(asyncio.TimeoutError):
            await asyncio.wait_for(sub.__anext__(), 0.02)
        bus.publish("p", "run.progress", {"after": "timeout"})
        got = await take(sub, 1)
        await sub.aclose()
        return got

    assert run(scenario())[0].data == {"after": "timeout"}


def test_slow_consumer_is_disconnected_without_blocking_publishers():
    async def scenario():
        bus = make_bus(queue_size=3)
        slow = bus.subscribe("p")
        fast = bus.subscribe("p")
        started = time.monotonic()
        fast_ids = []
        for i in range(10):
            bus.publish("p", "run.progress", {"i": i})
            fast_ids.append((await take(fast, 1))[0].id)
        elapsed = time.monotonic() - started
        count_after = bus.subscriber_count("p")
        delivered = []
        async for event in slow:                                 # итерация завершается сама
            delivered.append(event.id)
        await fast.aclose()
        return elapsed, count_after, delivered, fast_ids

    elapsed, count_after, delivered, fast_ids = run(scenario())
    assert elapsed < 1.0
    assert count_after == 1                                      # остался только быстрый
    assert delivered == [1, 2, 3]                                # очередь из 3, остальное — переподключением
    assert fast_ids == list(range(1, 11))


def test_reconnect_after_overflow_resumes_from_buffer():
    async def scenario():
        bus = make_bus(queue_size=2)
        slow = bus.subscribe("p")
        for i in range(6):
            bus.publish("p", "run.progress", {"i": i})
        first = [e.id async for e in slow]
        again = bus.subscribe("p", last_event_id=first[-1])
        rest = await take(again, 4)
        await again.aclose()
        return first, rest

    first, rest = run(scenario())
    assert first == [1, 2] and [e.id for e in rest] == [3, 4, 5, 6]


def test_publish_from_another_thread_wakes_subscriber():
    async def scenario():
        bus = make_bus()
        sub = bus.subscribe("p")
        reader = asyncio.ensure_future(sub.__anext__())
        await asyncio.sleep(0.01)
        await asyncio.to_thread(bus.publish, "p", "message.created", {"m": 1})
        event = await asyncio.wait_for(reader, 1)
        await sub.aclose()
        return event

    assert run(scenario()).data == {"m": 1}


# --- SSE: генератор кадров -------------------------------------------------------------------------------


def parse_frames(text: str):
    frames = []
    for block in text.split("\n\n"):
        if block.strip():
            frames.append(block)
    return frames


def test_event_stream_frame_format_and_json_data():
    from app.routers.events import event_stream

    async def scenario():
        bus = make_bus()
        sub = bus.subscribe("p")
        gen = event_stream(sub, heartbeat=5.0)
        bus.publish("p", "run.progress", {"run_id": "r1", "state": "готово", "n": 1})
        frame = await asyncio.wait_for(gen.__anext__(), 1)
        await gen.aclose()
        return frame, bus.subscriber_count("p")

    frame, count = run(scenario())
    assert frame.endswith("\n\n")
    lines = frame.rstrip("\n").split("\n")
    assert lines[0] == "id: 1" and lines[1] == "event: run.progress" and lines[2].startswith("data: ")
    assert len(lines) == 3
    assert json.loads(lines[2][len("data: "):]) == {"run_id": "r1", "state": "готово", "n": 1}
    assert count == 0                                            # закрытие генератора отписывает


def test_event_stream_heartbeat_when_idle():
    from app.routers.events import event_stream

    async def scenario():
        bus = make_bus()
        sub = bus.subscribe("p")
        gen = event_stream(sub, heartbeat=0.05)
        pings = [await asyncio.wait_for(gen.__anext__(), 1) for _ in range(2)]
        bus.publish("p", "run.completed", {"status": "done"})
        event = await asyncio.wait_for(gen.__anext__(), 1)
        await gen.aclose()
        return pings, event

    pings, event = run(scenario())
    assert pings == [": ping\n\n", ": ping\n\n"]
    assert event.startswith("id: 1\nevent: run.completed\n")


def test_event_stream_ends_when_subscriber_dropped():
    from app.routers.events import event_stream

    async def scenario():
        bus = make_bus(queue_size=2)
        sub = bus.subscribe("p")
        for i in range(5):
            bus.publish("p", "run.progress", {"i": i})
        return [frame async for frame in event_stream(sub, heartbeat=5.0)]

    frames = run(scenario())
    assert [f.split("\n")[0] for f in frames] == ["id: 1", "id: 2"]


# --- SSE: HTTP -------------------------------------------------------------------------------------------


class Stream:
    """Прямой вызов ASGI-приложения: читаем сообщения, шлём http.disconnect."""

    def __init__(self, app, path, headers=None):
        self.app = app
        self.sent = asyncio.Queue()
        self.incoming = asyncio.Queue()
        raw = [(k.lower().encode(), v.encode()) for k, v in (headers or {}).items()]
        self.scope = {
            "type": "http", "asgi": {"version": "3.0", "spec_version": "2.3"}, "http_version": "1.1", "method": "GET",
            "scheme": "http", "path": path, "raw_path": path.encode(), "query_string": b"", "root_path": "",
            "headers": raw, "client": ("127.0.0.1", 50000), "server": ("testserver", 80),
        }
        self.task = None
        self.start = None

    async def receive(self):
        return await self.incoming.get()

    async def send(self, message):
        await self.sent.put(message)

    async def open(self):
        self.incoming.put_nowait({"type": "http.request", "body": b"", "more_body": False})
        self.task = asyncio.ensure_future(self.app(self.scope, self.receive, self.send))
        self.start = await asyncio.wait_for(self.sent.get(), 2)
        return self

    async def read(self, count=1, timeout=1.0):
        parts = []
        for _ in range(count):
            message = await asyncio.wait_for(self.sent.get(), timeout)
            assert message["type"] == "http.response.body"
            parts.append(message.get("body", b"").decode())
        return "".join(parts)

    def headers(self):
        return {k.decode().lower(): v.decode() for k, v in self.start["headers"]}

    async def disconnect(self, timeout=2.0):
        self.incoming.put_nowait({"type": "http.disconnect"})
        await asyncio.wait_for(self.task, timeout)


def make_app(bus=None, heartbeat=None):
    from app.config import Settings
    from app.main import create_app
    app = create_app(Settings())
    if bus is not None:
        app.state.event_bus = bus
    if heartbeat is not None:
        app.state.sse_heartbeat = heartbeat
    return app


def test_http_headers_and_stream_with_replay_and_disconnect():
    async def scenario():
        bus = make_bus()
        for i in range(3):
            bus.publish("proj-1", "run.progress", {"i": i})
        app = make_app(bus)
        stream = await Stream(app, "/api/v1/projects/proj-1/events", {"Last-Event-ID": "1"}).open()
        status, headers = stream.start["status"], stream.headers()
        text = await stream.read(2)
        bus.publish("proj-1", "run.completed", {"status": "done"})
        live = await stream.read(1)
        subscribed = bus.subscriber_count("proj-1")
        await stream.disconnect()
        return status, headers, text, live, subscribed, bus.subscriber_count("proj-1")

    status, headers, text, live, subscribed, after = run(scenario())
    assert status == 200
    assert headers["content-type"].startswith("text/event-stream")
    assert headers["cache-control"] == "no-cache" and headers["x-accel-buffering"] == "no"
    assert headers.get("x-request-id")
    assert [f.split("\n")[0] for f in parse_frames(text)] == ["id: 2", "id: 3"]
    assert live == 'id: 4\nevent: run.completed\ndata: {"status": "done"}\n\n' or live.startswith("id: 4\nevent: run.completed\n")
    assert subscribed == 1 and after == 0                        # обрыв клиента не оставляет подписку


def test_http_no_last_event_id_gets_only_live_and_heartbeat():
    async def scenario():
        bus = make_bus()
        bus.publish("p", "run.progress", {"old": True})
        stream = await Stream(make_app(bus, heartbeat=0.05), "/api/v1/projects/p/events").open()
        ping = await stream.read(1)
        bus.publish("p", "score.changed", {"submission_id": "s"})
        event = await stream.read(1)
        await stream.disconnect()
        return ping, event

    ping, event = run(scenario())
    assert ping == ": ping\n\n"
    assert event.startswith("id: 2\nevent: score.changed\n")


def test_http_replay_respects_five_minute_window():
    async def scenario():
        clock = Clock(0.0)
        bus = make_bus(clock=clock)
        bus.publish("p", "run.progress", {"n": 1})
        clock.now = 200.0
        bus.publish("p", "run.progress", {"n": 2})
        clock.now = 400.0                                        # первое событие старше 300 с, второе — нет
        stream = await Stream(make_app(bus), "/api/v1/projects/p/events", {"Last-Event-ID": "0"}).open()
        text = await stream.read(1)
        await stream.disconnect()
        return text

    assert run(scenario()).startswith("id: 2\n")


@pytest.mark.parametrize("value", ["abc", "-5", "", "1.5", "99999999999999999999999"])
def test_http_garbage_last_event_id_is_ignored(value):
    async def scenario():
        bus = make_bus()
        bus.publish("p", "run.progress", {"old": True})
        stream = await Stream(make_app(bus, heartbeat=0.05), "/api/v1/projects/p/events", {"Last-Event-ID": value}).open()
        first = await stream.read(1)
        await stream.disconnect()
        return stream.start["status"], first

    status, first = run(scenario())
    assert status == 200 and first == ": ping\n\n"


def test_http_bus_created_lazily_and_shared():
    from app.routers.events import get_event_bus
    from app.services.events import EventBus

    async def scenario():
        app = make_app(heartbeat=5.0)
        assert not hasattr(app.state, "event_bus")
        stream = await Stream(app, "/api/v1/projects/p/events").open()
        bus = get_event_bus(app)
        assert isinstance(bus, EventBus) and app.state.event_bus is bus and get_event_bus(app) is bus
        bus.publish("p", "rubric.drafted", {"version": 1})
        frame = await stream.read(1)
        await stream.disconnect()
        return frame

    assert run(scenario()).startswith("id: 1\nevent: rubric.drafted\n")


def test_http_disconnect_before_first_chunk_does_not_leak_subscription():
    async def scenario():
        bus = make_bus()
        app = make_app(bus)
        stream = Stream(app, "/api/v1/projects/p/events")
        stream.incoming.put_nowait({"type": "http.disconnect"})
        stream.task = asyncio.ensure_future(app(stream.scope, stream.receive, stream.send))
        await asyncio.wait_for(stream.task, 2)
        await asyncio.sleep(0.05)
        return bus.subscriber_count("p")

    assert run(scenario()) == 0


@pytest.mark.parametrize("project_id", ["bad%20id", "a%2Fb", "x" * 65, "pr%21"])
def test_http_bad_project_id_is_404(project_id):
    async def scenario():
        app = make_app(make_bus())
        stream = Stream(app, "/api/v1/projects/" + project_id + "/events")
        stream.scope["raw_path"] = ("/api/v1/projects/" + project_id + "/events").encode()
        from urllib.parse import unquote
        stream.scope["path"] = unquote(stream.scope["raw_path"].decode())
        stream.incoming.put_nowait({"type": "http.request", "body": b"", "more_body": False})
        stream.task = asyncio.ensure_future(app(stream.scope, stream.receive, stream.send))
        start = await asyncio.wait_for(stream.sent.get(), 2)
        body = await asyncio.wait_for(stream.sent.get(), 2)
        await asyncio.wait_for(stream.task, 2)
        return start["status"], body["body"]

    status, body = run(scenario())
    assert status == 404
    assert json.loads(body)["error"]["code"] == "not_found"
