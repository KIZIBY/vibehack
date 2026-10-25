"""Шлюз агентов: запуск ролей в Hermes (``POST /v1/runs``) и подмена для тестов.

Контракт — ``specs/001-ai-judge-platform/contracts/agent-run.md`` §2–§4 и ``docs/design-doc.md`` §4.
Шлюз запускает роль, ждёт терминального статуса и возвращает ``RoleResult``; структурный результат роли
лежит в файле ``runs/<run_id>/reports/<role>__<scope>.json`` — его читает и перепроверяет вызывающий код, не шлюз.
``scope`` — ``submission_id`` для задач работы и литерал ``project`` для project-level задач (рубрика, метрики UX):
разные работы одной роли внутри прогона не делят ни сессию Hermes, ни ключ идемпотентности, ни файл отчёта.

Секреты: ключ API живёт только в заголовке запроса; в ``reason``, логи и ``repr`` не попадает ни он, ни
текст исключений httpx (в них бывают заголовки и адреса) — только имя класса ошибки.
"""
from __future__ import annotations

import asyncio
import copy
import json
import logging
import os
import re
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Awaitable, Callable, Iterable, Mapping, Protocol, runtime_checkable

import httpx

log = logging.getLogger("app.gateway")

TERMINAL_STATUSES = frozenset({"completed", "failed", "cancelled", "interrupted"})
BACKOFF_START = 2.0
BACKOFF_CAP = 30.0
POST_NETWORK_RETRIES = 2        # повтор POST после потери ответа — с тем же Idempotency-Key
POLL_ERRORS_TOLERATED = 3       # столько подряд сетевых сбоев опроса терпим, потом stop и failed
_SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
PROJECT_SCOPE = "project"
SCOPE_SEPARATOR = "__"          # между ролью и scope в имени файла отчёта; в самих ролях и scope его быть не может


def run_scope(submission_id: str | None) -> str:
    """``scope`` задачи: ``submission_id`` работы или ``project`` для project-level задачи (agent-run.md §1)."""
    return PROJECT_SCOPE if submission_id is None else submission_id


def report_filename(role: str, scope: str) -> str:
    """Имя принятого документа роли: ``<role>__<scope>.json``. Небезопасные части (обход каталога, ``__``) — ValueError."""
    for name, value in (("role", role), ("scope", scope)):
        if not (isinstance(value, str) and _SAFE_NAME.match(value)) or SCOPE_SEPARATOR in value:
            raise ValueError(f"недопустимый {name}: {value!r}")
    return f"{role}{SCOPE_SEPARATOR}{scope}.json"


@dataclass(frozen=True)
class RoleRun:
    """Запрос на запуск одной роли (agent-run.md §2)."""

    run_id: str
    role: str
    submission_id: str | None
    workdir: str
    rubric_version: int
    instructions: str
    input: str
    attempt: int = 1

    @property
    def scope(self) -> str:
        return run_scope(self.submission_id)


@dataclass(frozen=True)
class RoleResult:
    """Итог запуска роли. ``status``: completed | failed | timeout | cancelled."""

    status: str
    hermes_run_id: str | None = None
    output: str = ""
    tokens_in: int | None = None
    tokens_out: int | None = None
    provider: str | None = None
    model: str | None = None
    reason: str | None = None


@runtime_checkable
class AgentGateway(Protocol):
    async def run_role(self, run: RoleRun) -> RoleResult: ...

    async def probe(self) -> str: ...   # "up" | "down"


def _count(value: Any) -> int | None:
    """Токены — только фактическое неотрицательное целое от провайдера; ничего не оцениваем."""
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        return None
    return value


def _text(value: Any) -> str | None:
    return value if isinstance(value, str) and value else None


class HermesGateway:
    def __init__(
        self,
        base_url: str,
        api_key: str,
        *,
        client: httpx.AsyncClient | None = None,
        poll_interval: float = 1.0,
        role_timeout: float = 900.0,
        max_attempts_429: int = 6,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
        monotonic: Callable[[], float] = time.monotonic,
    ) -> None:
        self._base = base_url.rstrip("/")
        self._api_key = api_key
        self._owns_client = client is None
        self._client = client if client is not None else httpx.AsyncClient(timeout=httpx.Timeout(30.0))
        self._poll_interval = poll_interval
        self._role_timeout = role_timeout
        self._max_attempts_429 = max_attempts_429
        self._sleep = sleep
        self._monotonic = monotonic

    def __repr__(self) -> str:
        return f"HermesGateway(base_url={self._base!r})"

    async def aclose(self) -> None:
        if self._owns_client:
            await self._client.aclose()

    # ── публичный интерфейс ─────────────────────────────────────────────────────────────────

    async def probe(self) -> str:
        try:
            response = await self._client.get(f"{self._base}/health")
        except Exception as exc:  # noqa: BLE001 — любой сбой = агентский слой недоступен
            log.warning("hermes probe failed: %s", type(exc).__name__)
            return "down"
        return "up" if response.status_code == 200 else "down"

    async def run_role(self, run: RoleRun) -> RoleResult:
        state: dict[str, str | None] = {"hermes_run_id": None}
        try:
            return await self._run(run, state)
        except httpx.HTTPError as exc:
            log.warning("hermes network error run_id=%s role=%s: %s", run.run_id, run.role, type(exc).__name__)
            return RoleResult(status="failed", hermes_run_id=state["hermes_run_id"],
                              reason=f"network_error:{type(exc).__name__}")

    # ── внутренности ────────────────────────────────────────────────────────────────────────

    def _headers(self) -> dict[str, str]:
        return {"Authorization": f"Bearer {self._api_key}"}

    async def _run(self, run: RoleRun, state: dict[str, str | None]) -> RoleResult:
        hermes_id = await self._start(run)
        if isinstance(hermes_id, RoleResult):
            return hermes_id
        state["hermes_run_id"] = hermes_id

        started = self._monotonic()
        poll_errors = 0
        while True:
            try:
                response = await self._client.get(f"{self._base}/v1/runs/{hermes_id}", headers=self._headers())
            except httpx.TransportError as exc:
                poll_errors += 1
                log.warning("hermes poll error run_id=%s role=%s: %s", run.run_id, run.role, type(exc).__name__)
                if poll_errors >= POLL_ERRORS_TOLERATED:
                    await self._stop(hermes_id)   # запуск не оставляем работающим: иначе гонка записи отчёта
                    raise
            else:
                poll_errors = 0
                if response.status_code != 200:
                    return RoleResult(status="failed", hermes_run_id=hermes_id, reason=f"http_{response.status_code}")
                data = _json_object(response)
                if data is None:
                    return RoleResult(status="failed", hermes_run_id=hermes_id, reason="bad_response")
                if data.get("status") in TERMINAL_STATUSES:
                    return _terminal_result(hermes_id, data)

            elapsed = self._monotonic() - started
            if elapsed >= self._role_timeout:
                await self._stop(hermes_id)
                return RoleResult(status="timeout", hermes_run_id=hermes_id, reason="timeout")
            await self._sleep(min(self._poll_interval, self._role_timeout - elapsed))

    async def _start(self, run: RoleRun) -> str | RoleResult:
        """POST /v1/runs с повтором после 429 (2 с, удваивая до 30 с). Возвращает id запуска Hermes."""
        session_id = f"{run.run_id}:{run.role}:{run.scope}"
        headers = {**self._headers(), "Idempotency-Key": f"{session_id}:{run.attempt}"}
        body = {"session_id": session_id, "instructions": run.instructions, "input": run.input}
        delay = BACKOFF_START
        for retry in range(self._max_attempts_429 + 1):
            response = await self._post_run(headers, body)
            if response.status_code != 429:
                break
            if retry == self._max_attempts_429:
                log.warning("hermes rate limited run_id=%s role=%s", run.run_id, run.role)
                return RoleResult(status="failed", reason="rate_limited")
            await self._sleep(delay)
            delay = min(delay * 2, BACKOFF_CAP)

        if response.status_code not in (200, 201, 202):
            return RoleResult(status="failed", reason=f"http_{response.status_code}")
        data = _json_object(response)
        hermes_id = data.get("run_id") if data else None
        if not isinstance(hermes_id, str) or not hermes_id:
            return RoleResult(status="failed", reason="bad_response")
        return hermes_id

    async def _post_run(self, headers: dict[str, str], body: dict[str, str]) -> httpx.Response:
        """POST /v1/runs; после потери ответа повторяет с тем же Idempotency-Key (запуск не плодится)."""
        for attempt in range(POST_NETWORK_RETRIES + 1):
            try:
                return await self._client.post(f"{self._base}/v1/runs", headers=headers, json=body)
            except httpx.TransportError as exc:
                if attempt == POST_NETWORK_RETRIES:
                    raise
                log.warning("hermes post error, retrying: %s", type(exc).__name__)
                await self._sleep(BACKOFF_START * 2 ** attempt)
        raise AssertionError("unreachable")   # pragma: no cover

    async def _stop(self, hermes_id: str) -> None:
        """Best-effort: отмена не должна ломать вызывающего."""
        try:
            await self._client.post(f"{self._base}/v1/runs/{hermes_id}/stop", headers=self._headers())
        except Exception as exc:  # noqa: BLE001
            log.warning("hermes stop failed: %s", type(exc).__name__)


def _json_object(response: httpx.Response) -> dict[str, Any] | None:
    try:
        data = response.json()
    except ValueError:
        return None
    return data if isinstance(data, dict) else None


def _terminal_result(hermes_id: str, data: Mapping[str, Any]) -> RoleResult:
    status = data["status"]
    usage = data.get("usage") if isinstance(data.get("usage"), dict) else {}
    runtime = data.get("runtime") if isinstance(data.get("runtime"), dict) else {}
    output = data.get("output")
    common = dict(
        hermes_run_id=hermes_id,
        output=output if isinstance(output, str) else "",
        tokens_in=_count(usage.get("input_tokens")),
        tokens_out=_count(usage.get("output_tokens")),
        provider=_text(runtime.get("provider")),
        model=_text(runtime.get("model")),
    )
    if status == "completed":
        return RoleResult(status="completed", **common)
    if status == "cancelled":
        return RoleResult(status="cancelled", reason="cancelled", **common)
    if status == "interrupted":
        return RoleResult(status="failed", reason="interrupted", **common)
    return RoleResult(status="failed", reason="run_failed", **common)


class FakeAgentGateway:
    """Подмена для тестов и демо без Hermes: кладёт готовые документы туда, куда их кладёт плагин."""

    def __init__(
        self,
        data_dir: str | Path,
        reports: Mapping[str, Mapping[str, Any]] | None = None,
        *,
        fail_roles: Iterable[str] = (),
        timeout_roles: Iterable[str] = (),
        probe_state: str = "up",
    ) -> None:
        self._data_dir = Path(data_dir)
        self._reports = dict(reports or {})
        self._fail_roles = frozenset(fail_roles)
        self._timeout_roles = frozenset(timeout_roles)
        self._probe_state = probe_state
        self.calls: list[RoleRun] = []

    async def probe(self) -> str:
        return self._probe_state

    async def run_role(self, run: RoleRun) -> RoleResult:
        if not _SAFE_NAME.match(run.run_id):
            raise ValueError(f"недопустимый run_id: {run.run_id!r}")
        filename = report_filename(run.role, run.scope)
        self.calls.append(run)
        fake_id = f"fake-{run.run_id}-{run.role}"

        if run.role in self._fail_roles:
            return RoleResult(status="failed", hermes_run_id=fake_id, reason="simulated_failure")
        if run.role in self._timeout_roles:
            return RoleResult(status="timeout", hermes_run_id=fake_id, reason="timeout")
        template = self._reports.get(run.role)
        if template is None:
            return RoleResult(status="failed", hermes_run_id=fake_id, reason="no_report_configured")

        document = copy.deepcopy(dict(template))
        carries_ids = document.get("kind") in ("scores", "inventory_patch")
        if carries_ids or "run_id" in document:
            document["run_id"] = run.run_id
        if document.get("kind") == "scores" or "rubric_version" in document:
            document["rubric_version"] = run.rubric_version
        if run.submission_id is not None and (carries_ids or "submission_id" in document):
            document["submission_id"] = run.submission_id
        self._write(run, filename, document)
        return RoleResult(status="completed", hermes_run_id=fake_id, output="fake report written")

    def _write(self, run: RoleRun, filename: str, document: Mapping[str, Any]) -> None:
        target_dir = self._data_dir / "runs" / run.run_id / "reports"
        target_dir.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=target_dir, prefix=f".{run.role}.", suffix=".tmp")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(document, handle, ensure_ascii=False, indent=2)
            os.replace(tmp_name, target_dir / filename)
        except BaseException:
            Path(tmp_name).unlink(missing_ok=True)
            raise
