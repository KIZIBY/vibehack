"""Запуск intake подпроцессом: чистое окружение, лимиты ресурсов, таймаут с убийством группы, проверка описи."""
import asyncio
import json
import os
import shutil
import signal
import stat
import sys
import tempfile
from pathlib import Path
from typing import Any, Optional, Sequence, Union

import jsonschema

try:
    import resource
except ImportError:     # не POSIX: лимиты ресурсов недоступны
    resource = None

REPO_ROOT = Path(__file__).resolve().parents[3]
SCHEMA_PATH = REPO_ROOT / "specs" / "001-ai-judge-platform" / "contracts" / "inventory.schema.json"
INVENTORY_NAME = "inventory.json"
MAX_INVENTORY_BYTES = 10 * 1024 * 1024
DRAIN_GRACE_SECONDS = 2.0
CPU_HARD_MARGIN = 5

PathLike = Union[str, Path]


class IntakeFailed(Exception):
    """Intake не дал годной описи. reason: timeout | exit_code | no_inventory | bad_inventory | spawn_failed."""

    def __init__(self, reason: str, *, returncode: Optional[int] = None, stderr_tail: str = ""):
        self.reason = reason
        self.returncode = returncode
        self.stderr_tail = stderr_tail
        suffix = f" (код {returncode})" if returncode is not None else ""
        super().__init__(f"intake: {reason}{suffix}")


_schema_cache: dict = {}


def _load_schema(path: Path) -> dict:
    key = str(path)
    if key not in _schema_cache:
        schema = json.loads(path.read_text(encoding="utf-8"))
        jsonschema.Draft202012Validator.check_schema(schema)
        _schema_cache[key] = schema
    return _schema_cache[key]


class IntakeRunner:
    def __init__(self, command: Optional[Sequence[str]] = None, timeout: float = 300.0, max_output_bytes: int = 65536,
                 cpu_seconds: int = 240, memory_bytes: int = 2 * 1024 ** 3, max_open_files: int = 256, *,
                 cwd: Optional[PathLike] = None, schema_path: Optional[PathLike] = None):
        self.command = list(command) if command is not None else [sys.executable, "-m", "intake"]
        self.timeout = timeout
        self.max_output_bytes = max_output_bytes
        self.cpu_seconds = cpu_seconds
        self.memory_bytes = memory_bytes
        self.max_open_files = max_open_files
        self.cwd = str(cwd) if cwd is not None else (str(REPO_ROOT) if command is None else None)
        self.schema_path = Path(schema_path) if schema_path is not None else SCHEMA_PATH

    def build_command(self, submission_dir: PathLike, out_dir: PathLike) -> list:
        return [*self.command, str(submission_dir), "--out", str(out_dir)]

    def _apply_limits(self) -> None:
        """preexec_fn: каждый лимит best-effort (на macOS RLIMIT_AS не поддерживается)."""
        for name, soft, hard in (
            ("RLIMIT_NOFILE", self.max_open_files, self.max_open_files),
            ("RLIMIT_CPU", self.cpu_seconds, self.cpu_seconds + CPU_HARD_MARGIN),
            ("RLIMIT_AS", self.memory_bytes, self.memory_bytes),
        ):
            kind = getattr(resource, name)
            try:
                _, current_hard = resource.getrlimit(kind)
                if current_hard != resource.RLIM_INFINITY:
                    soft, hard = min(soft, current_hard), min(hard, current_hard)
                resource.setrlimit(kind, (soft, hard))
            except (ValueError, OSError):
                pass

    async def run(self, submission_dir: PathLike, out_dir: PathLike) -> dict:
        out_path = Path(out_dir)
        out_path.mkdir(parents=True, exist_ok=True)
        inventory_path = out_path / INVENTORY_NAME
        if inventory_path.is_symlink() or inventory_path.exists():     # устаревшей описи не верим
            inventory_path.unlink()
        home = tempfile.mkdtemp(prefix="intake-home-")
        try:
            tail = await self._execute(submission_dir, out_dir, home)
            if tail[0] != 0:
                raise IntakeFailed("exit_code", returncode=tail[0],
                                   stderr_tail=self._scrub(tail[1], submission_dir, out_dir, home))
            return self._read_inventory(inventory_path)
        finally:
            shutil.rmtree(home, ignore_errors=True)

    async def _execute(self, submission_dir: PathLike, out_dir: PathLike, home: str):
        env = {"PATH": os.environ.get("PATH") or "/usr/bin:/bin", "LANG": os.environ.get("LANG") or "C.UTF-8", "HOME": home}
        try:
            process = await asyncio.create_subprocess_exec(
                *self.build_command(submission_dir, out_dir), stdin=asyncio.subprocess.DEVNULL,
                stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE, env=env, cwd=self.cwd,
                start_new_session=True,
                preexec_fn=self._apply_limits if resource is not None else None)
        except (OSError, ValueError, TypeError):
            raise IntakeFailed("spawn_failed") from None
        drains = [asyncio.ensure_future(self._drain(process.stdout, 0)),
                  asyncio.ensure_future(self._drain(process.stderr, self.max_output_bytes))]
        try:
            try:
                await asyncio.wait_for(process.wait(), self.timeout)
            except asyncio.TimeoutError:
                self._kill_group(process)
                await process.wait()
                raise IntakeFailed("timeout") from None
            self._kill_group(process)      # потомки, пережившие основной процесс, не остаются сиротами
            done, pending = await asyncio.wait(drains, timeout=DRAIN_GRACE_SECONDS)
            stderr_tail = drains[1].result() if drains[1] in done and not drains[1].cancelled() else bytearray()
        except BaseException:
            self._kill_group(process)
            raise
        finally:
            for task in drains:
                if not task.done():
                    task.cancel()
            await asyncio.gather(*drains, return_exceptions=True)
        text = bytes(stderr_tail).decode("utf-8", errors="ignore")
        return process.returncode, text

    @staticmethod
    async def _drain(stream, keep: int) -> bytearray:
        """Читает поток до конца, храня только последние ``keep`` байт (0 — выбрасывает всё)."""
        tail = bytearray()
        while True:
            chunk = await stream.read(65536)
            if not chunk:
                return tail
            if keep:
                tail += chunk
                if len(tail) > keep:
                    del tail[:len(tail) - keep]

    @staticmethod
    def _kill_group(process) -> None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, PermissionError, AttributeError):
            try:
                process.kill()
            except ProcessLookupError:
                pass

    @staticmethod
    def _scrub(text: str, *paths: PathLike) -> str:
        """Пути машины в хвосте stderr заменяются метками."""
        for path, label in zip(paths, ("<submission>", "<out>", "<home>")):
            if str(path):
                text = text.replace(str(path), label)
        return text

    def _read_inventory(self, path: Path) -> dict:
        try:
            fd = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_NONBLOCK", 0))
        except FileNotFoundError:
            raise IntakeFailed("no_inventory") from None
        except OSError:        # в том числе ELOOP: опись — симлинк
            raise IntakeFailed("bad_inventory") from None
        try:
            with os.fdopen(fd, "rb") as handle:
                if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):      # FIFO/устройство вместо файла
                    raise IntakeFailed("bad_inventory")
                raw = handle.read(MAX_INVENTORY_BYTES + 1)
        except OSError:
            raise IntakeFailed("bad_inventory") from None
        if len(raw) > MAX_INVENTORY_BYTES:
            raise IntakeFailed("bad_inventory")
        try:
            data: Any = json.loads(raw.decode("utf-8"))
            jsonschema.validate(data, _load_schema(self.schema_path))
        except (ValueError, jsonschema.ValidationError):
            raise IntakeFailed("bad_inventory") from None
        return data
