from __future__ import annotations

import os
import shutil
import stat
import tarfile
import zipfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath


MAX_BYTES = 1_000_000_000
MAX_FILES = 20_000
MAX_NESTING = 2


class UnsafeArchive(ValueError):
    """Archive rejected before or during extraction."""


@dataclass
class UnpackReport:
    files: int = 0
    bytes: int = 0
    archives: int = 0
    skipped_symlinks: int = 0


def _safe_member(root: Path, name: str) -> Path:
    raw = PurePosixPath(name)
    if raw.is_absolute() or ".." in raw.parts:
        raise UnsafeArchive(f"path traversal: {name}")
    target = (root / Path(*raw.parts)).resolve()
    root_resolved = root.resolve()
    if target != root_resolved and root_resolved not in target.parents:
        raise UnsafeArchive(f"path escapes destination: {name}")
    return target


def _check_limits(report: UnpackReport, size: int) -> None:
    if report.files + 1 > MAX_FILES:
        raise UnsafeArchive(f"file limit exceeded: {MAX_FILES}")
    if report.bytes + size > MAX_BYTES:
        raise UnsafeArchive(f"expanded size limit exceeded: {MAX_BYTES} bytes")


def _write_stream(source, target: Path, report: UnpackReport, size: int) -> None:
    _check_limits(report, size)
    target.parent.mkdir(parents=True, exist_ok=True)
    with target.open("wb") as destination:
        remaining = size
        while remaining:
            chunk = source.read(min(1024 * 1024, remaining))
            if not chunk:
                break
            destination.write(chunk)
            remaining -= len(chunk)
    report.files += 1
    report.bytes += size - remaining


def _extract_zip(archive: Path, root: Path, report: UnpackReport) -> list[Path]:
    nested: list[Path] = []
    with zipfile.ZipFile(archive) as handle:
        for info in handle.infolist():
            target = _safe_member(root, info.filename)
            mode = (info.external_attr >> 16) & 0o170000
            if mode == stat.S_IFLNK:
                report.skipped_symlinks += 1
                continue
            if info.is_dir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            _write_stream(handle.open(info, "r"), target, report, info.file_size)
            if target.suffix.lower() in {".zip", ".tar", ".tgz", ".tar.gz"}:
                nested.append(target)
    return nested


def _extract_tar(archive: Path, root: Path, report: UnpackReport) -> list[Path]:
    nested: list[Path] = []
    with tarfile.open(archive) as handle:
        for member in handle.getmembers():
            target = _safe_member(root, member.name)
            if member.issym() or member.islnk():
                report.skipped_symlinks += 1
                continue
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
                continue
            if not member.isfile():
                raise UnsafeArchive(f"unsupported tar member: {member.name}")
            stream = handle.extractfile(member)
            if stream is None:
                raise UnsafeArchive(f"cannot read tar member: {member.name}")
            _write_stream(stream, target, report, member.size)
            if target.suffix.lower() in {".zip", ".tar", ".tgz", ".gz"}:
                nested.append(target)
    return nested


def _extract_one(archive: Path, root: Path, report: UnpackReport) -> list[Path]:
    if zipfile.is_zipfile(archive):
        return _extract_zip(archive, root, report)
    if tarfile.is_tarfile(archive):
        return _extract_tar(archive, root, report)
    raise UnsafeArchive(f"unsupported archive format: {archive.name}")


def safe_unpack(archive: str | Path, destination: str | Path, *, max_depth: int = MAX_NESTING) -> UnpackReport:
    archive = Path(archive)
    destination = Path(destination)
    if not archive.is_file():
        raise FileNotFoundError(archive)
    destination.mkdir(parents=True, exist_ok=True)
    report = UnpackReport()
    queue: list[tuple[Path, int]] = [(archive, 0)]
    try:
        while queue:
            current, depth = queue.pop(0)
            report.archives += 1
            nested = _extract_one(current, destination, report)
            if depth >= max_depth and nested:
                raise UnsafeArchive(f"nested archive depth exceeds {max_depth}")
            queue.extend((item, depth + 1) for item in nested)
    except Exception:
        shutil.rmtree(destination, ignore_errors=True)
        raise
    return report
