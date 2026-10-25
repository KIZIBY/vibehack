"""Хранилище файлов в каталоге данных (``data_dir``): безопасные пути, потоковая атомарная запись, удаление."""
import asyncio
import hashlib
import os
import re
import unicodedata
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import AsyncIterator, Optional, Union

ID_RE = re.compile(r"[A-Za-z0-9_-]{1,64}")
KINDS = ("briefs", "submissions")
MAX_NAME_LENGTH = 120
MAX_EXTENSION_LENGTH = 20
WRITE_BUFFER_BYTES = 256 * 1024
_SEPARATORS = re.compile(r"[/\\]")


class UnsafePath(ValueError):
    """Путь выходит за пределы корня (``..``, абсолютный путь, симлинк наружу)."""


class PayloadTooLarge(Exception):
    """Загружаемый файл больше разрешённого размера."""


@dataclass(frozen=True)
class SavedFile:
    path_rel: str
    size_bytes: int
    sha256: str
    material_id: str


def safe_join(root: Union[str, Path], *parts: str) -> Path:
    """Склеивает пути строго внутри ``root``; результат разрешён (``resolve``), симлинки наружу запрещены."""
    root_resolved = Path(root).resolve()
    for part in parts:
        text = os.fspath(part)
        if "\x00" in text or text.startswith(("/", "\\")) or re.match(r"^[A-Za-z]:", text):
            raise UnsafePath("недопустимая часть пути")
        if any(segment == ".." for segment in _SEPARATORS.split(text)):
            raise UnsafePath("недопустимая часть пути")
    result = root_resolved.joinpath(*parts).resolve()
    if not result.is_relative_to(root_resolved):
        raise UnsafePath("путь выходит за пределы корня")
    return result


def sanitize_filename(name: str) -> str:
    """Безопасное имя файла: последний компонент, без управляющих символов и ``..``, NFC, до 120 символов."""
    text = unicodedata.normalize("NFC", str(name))
    text = _SEPARATORS.split(text)[-1]
    text = "".join(ch for ch in text if unicodedata.category(ch) not in ("Cc", "Cf"))   # управляющие и bidi/невидимые
    while ".." in text:
        text = text.replace("..", ".")
    text = text.strip().rstrip(". ")
    if not text or not text.strip("."):
        return "file"
    if len(text) > MAX_NAME_LENGTH:
        stem, dot, extension = text.rpartition(".")
        if dot and stem and len(extension) + 1 <= MAX_EXTENSION_LENGTH:
            text = stem[:MAX_NAME_LENGTH - len(extension) - 1] + "." + extension
        else:
            text = text[:MAX_NAME_LENGTH]
        text = text.rstrip(". ") or "file"
    return text


def _check_id(value: str, label: str) -> str:
    if not isinstance(value, str) or not ID_RE.fullmatch(value):
        raise ValueError(f"{label}: ожидается ^[A-Za-z0-9_-]{{1,64}}$")
    return value


class Storage:
    def __init__(self, data_dir: Union[str, Path]):
        self.root = Path(data_dir)

    def _expected_dir(self, *parts: str) -> Path:
        """Каталог внутри корня без симлинков на пути: разрешённый путь обязан совпасть с буквальным."""
        root_resolved = self.root.resolve()
        resolved = safe_join(root_resolved, *parts)
        if resolved != root_resolved.joinpath(*parts):
            raise UnsafePath("симлинк в пути каталога")
        return resolved

    async def save_upload(self, project_id: str, kind: str, filename: str, chunks: AsyncIterator[bytes], *,
                          max_bytes: int, material_id: Optional[str] = None) -> SavedFile:
        _check_id(project_id, "project_id")
        if kind not in KINDS:
            raise ValueError(f"kind: ожидается одно из {KINDS}")
        material_id = _check_id(material_id, "material_id") if material_id is not None else uuid.uuid4().hex
        name = sanitize_filename(filename)
        parts = ("projects", project_id, kind, material_id)
        directory = self._expected_dir(*parts)
        await asyncio.to_thread(directory.mkdir, parents=True, exist_ok=True)
        directory = self._expected_dir(*parts)      # после создания: ни один компонент не подменён симлинком
        temp = directory / f".upload-{uuid.uuid4().hex}.tmp"
        digest = hashlib.sha256()
        total = 0
        fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o600)
        try:
            with os.fdopen(fd, "wb") as handle:
                pending: list = []
                pending_size = 0
                async for chunk in chunks:
                    if not isinstance(chunk, (bytes, bytearray, memoryview)):
                        raise TypeError("chunks должен отдавать байты")
                    total += len(chunk)
                    if total > max_bytes:
                        raise PayloadTooLarge(f"файл больше {max_bytes} байт")
                    digest.update(chunk)
                    pending.append(bytes(chunk))
                    pending_size += len(chunk)
                    if pending_size >= WRITE_BUFFER_BYTES:
                        await asyncio.to_thread(handle.write, b"".join(pending))
                        pending, pending_size = [], 0
                if pending:
                    await asyncio.to_thread(handle.write, b"".join(pending))
                await asyncio.to_thread(handle.flush)
                await asyncio.to_thread(os.fsync, handle.fileno())
            final = directory / name
            await asyncio.to_thread(_publish_without_overwrite, temp, final)
        except BaseException:
            try:
                os.unlink(temp)
            except FileNotFoundError:
                pass
            try:
                directory.rmdir()       # пустой каталог материала не оставляем
            except OSError:
                pass
            raise
        return SavedFile(path_rel="/".join((*parts, name)), size_bytes=total, sha256=digest.hexdigest(),
                         material_id=material_id)

    def delete_project_materials(self, project_id: str) -> int:
        """Удаляет содержимое briefs/ и submissions/ проекта (каталоги остаются); симлинки не разворачивает."""
        _check_id(project_id, "project_id")
        removed = 0
        for kind in KINDS:
            try:
                directory = self._expected_dir("projects", project_id, kind)
            except UnsafePath:
                continue                # каталог или его родитель — симлинк: наружу не ходим
            if not directory.is_dir():
                continue
            removed += _empty_directory(directory)
        return removed


def _publish_without_overwrite(temp: Path, final: Path) -> None:
    """Переносит временный файл на место, не затирая существующий (FileExistsError)."""
    try:
        os.link(temp, final)
    except FileExistsError:
        raise
    except OSError:                 # файловая система без жёстких ссылок
        if os.path.lexists(final):
            raise FileExistsError(str(final.name)) from None
        os.replace(temp, final)
        return
    os.unlink(temp)


def _empty_directory(directory: Path) -> int:
    removed = 0
    for current, dirnames, filenames in os.walk(directory, topdown=False, followlinks=False):
        for name in filenames:
            os.unlink(os.path.join(current, name))
            removed += 1
        for name in dirnames:
            path = os.path.join(current, name)
            if os.path.islink(path):
                os.unlink(path)
                removed += 1
            else:
                os.rmdir(path)
    return removed
