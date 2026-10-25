"""T025 (часть): хранилище файлов ``app.services.storage``. Тесты написаны ДО реализации (RED).

Контракт:
- ``safe_join(root, *parts) -> Path`` — результат строго внутри ``root`` (``..``, абсолютные части,
  симлинки наружу), иначе ``UnsafePath(ValueError)``;
- ``sanitize_filename(name) -> str`` — последний компонент по ``/`` и ``\\``, без управляющих символов и
  ``..``, NFC, ≤ 120 символов с сохранением расширения, пустое/из точек -> ``"file"``;
- ``Storage(data_dir).save_upload(project_id, kind, filename, chunks, *, max_bytes, material_id=None)``
  (async, ``chunks`` — async-итератор байтов) -> ``SavedFile(path_rel, size_bytes, sha256, material_id)``;
  путь ``projects/<project_id>/<kind>/<material_id>/<имя>`` (``kind`` ∈ briefs|submissions);
  превышение ``max_bytes`` на лету -> ``PayloadTooLarge`` без остатков; id по ``^[A-Za-z0-9_-]{1,64}$``;
- ``Storage.delete_project_materials(project_id) -> int`` — удаляет содержимое ``briefs`` и
  ``submissions`` проекта (каталоги остаются), симлинки не разворачивает, подкаталог-симлинк пропускает.

Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import asyncio
import hashlib
import os
import tracemalloc
from pathlib import Path

import pytest

KB = 1024
MB = 1024 * 1024


def run(coro):
    return asyncio.run(coro)


async def chunked(data: bytes, size: int = KB):
    for i in range(0, len(data), size):
        yield data[i:i + size]


def files_under(root: Path):
    return sorted(p for p in root.rglob("*") if p.is_file() or p.is_symlink())


def make_storage(tmp_path: Path):
    from app.services.storage import Storage
    root = tmp_path / "data"
    root.mkdir()
    return Storage(root), root


# --- safe_join ------------------------------------------------------------------------------------------


def test_safe_join_inside_root(tmp_path):
    from app.services.storage import safe_join
    result = safe_join(tmp_path, "a", "b.txt")
    assert result == (tmp_path / "a" / "b.txt").resolve()


@pytest.mark.parametrize("parts", [("..",), ("a", "..", "..", "x"), ("/etc/passwd",), ("a/../../x",), ("..\\x",)])
def test_safe_join_rejects_escape(tmp_path, parts):
    from app.services.storage import UnsafePath, safe_join
    assert issubclass(UnsafePath, ValueError)
    with pytest.raises(UnsafePath):
        safe_join(tmp_path, *parts)


def test_safe_join_rejects_symlink_out(tmp_path):
    from app.services.storage import UnsafePath, safe_join
    outside = tmp_path / "outside"
    outside.mkdir()
    root = tmp_path / "root"
    root.mkdir()
    (root / "link").symlink_to(outside, target_is_directory=True)
    with pytest.raises(UnsafePath):
        safe_join(root, "link", "file.txt")


# --- sanitize_filename ----------------------------------------------------------------------------------


@pytest.mark.parametrize("raw,expected", [
    ("../../etc/passwd", "passwd"),
    ("..\\..\\x.txt", "x.txt"),
    ("a/b\\c/d.pdf", "d.pdf"),
    ("report.pdf", "report.pdf"),
    ("Презентация финал.pdf", "Презентация финал.pdf"),
    ("ab\x00c\x1f\x7f.txt", "abc.txt"),
    ("", "file"),
    (".", "file"),
    ("..", "file"),
    ("....", "file"),
    ("dir/", "file"),
    ("   ", "file"),
])
def test_sanitize_filename_cases(raw, expected):
    from app.services.storage import sanitize_filename
    assert sanitize_filename(raw) == expected


def test_sanitize_removes_dotdot_inside_name():
    from app.services.storage import sanitize_filename
    result = sanitize_filename("a..b...c.txt")
    assert ".." not in result and result.endswith(".txt") and result.startswith("a")


def test_sanitize_normalizes_unicode_nfc():
    from app.services.storage import sanitize_filename
    decomposed = "é.txt"
    assert sanitize_filename(decomposed) == "é.txt"
    assert sanitize_filename("й".encode("utf-8").decode() + ".md") == "й.md"


def test_sanitize_truncates_keeping_extension():
    from app.services.storage import sanitize_filename
    result = sanitize_filename("я" * 300 + ".pdf")
    assert len(result) <= 120 and result.endswith(".pdf") and result.startswith("я")
    assert len(sanitize_filename("x" * 500)) <= 120


# --- save_upload ----------------------------------------------------------------------------------------


def test_save_upload_basic(tmp_path):
    storage, root = make_storage(tmp_path)
    data = os.urandom(10 * KB + 7)
    saved = run(storage.save_upload("proj_1", "briefs", "Бриф.pdf", chunked(data), max_bytes=MB))
    assert saved.size_bytes == len(data)
    assert saved.sha256 == hashlib.sha256(data).hexdigest()
    assert saved.material_id and saved.material_id.replace("-", "").replace("_", "").isalnum()
    assert saved.path_rel == f"projects/proj_1/briefs/{saved.material_id}/Бриф.pdf"
    assert (root / saved.path_rel).read_bytes() == data
    assert [p for p in root.rglob("*.tmp")] == []


def test_save_upload_explicit_material_id_and_submissions(tmp_path):
    storage, root = make_storage(tmp_path)
    saved = run(storage.save_upload("p", "submissions", "a.zip", chunked(b"zip"), max_bytes=100, material_id="mat-1"))
    assert saved.material_id == "mat-1"
    assert saved.path_rel == "projects/p/submissions/mat-1/a.zip"


@pytest.mark.parametrize("raw", ["../../etc/passwd", "..\\..\\x.txt"])
def test_save_upload_traversal_name_stays_inside_project(tmp_path, raw):
    storage, root = make_storage(tmp_path)
    saved = run(storage.save_upload("proj", "briefs", raw, chunked(b"data"), max_bytes=100))
    target = (root / saved.path_rel).resolve()
    assert target.is_relative_to((root / "projects" / "proj").resolve())
    assert target.read_bytes() == b"data"
    # ничего не появилось вне каталога проекта
    for path in files_under(tmp_path):
        assert path.resolve().is_relative_to((root / "projects" / "proj").resolve()), path


def test_save_upload_size_boundaries(tmp_path):
    from app.services.storage import PayloadTooLarge
    storage, root = make_storage(tmp_path)
    exact = run(storage.save_upload("p", "briefs", "exact.bin", chunked(b"x" * 1000, 100), max_bytes=1000))
    assert exact.size_bytes == 1000
    with pytest.raises(PayloadTooLarge):
        run(storage.save_upload("p", "briefs", "over.bin", chunked(b"x" * 1001, 100), max_bytes=1000))
    assert not any(p.name == "over.bin" for p in files_under(root))


def test_payload_too_large_leaves_no_partial_or_tmp(tmp_path):
    from app.services.storage import PayloadTooLarge
    storage, root = make_storage(tmp_path)
    with pytest.raises(PayloadTooLarge):
        run(storage.save_upload("p", "briefs", "big.bin", chunked(b"x" * 10 * KB, KB), max_bytes=3 * KB))
    assert files_under(root) == []


def test_stops_reading_at_limit(tmp_path):
    from app.services.storage import PayloadTooLarge
    storage, _ = make_storage(tmp_path)
    consumed = 0

    async def source():
        nonlocal consumed
        for _ in range(5 * 1024):
            consumed += 1
            yield b"x" * KB

    with pytest.raises(PayloadTooLarge):
        run(storage.save_upload("p", "briefs", "big.bin", source(), max_bytes=MB))
    assert consumed <= 1024 + 2


def test_source_error_leaves_no_tmp(tmp_path):
    storage, root = make_storage(tmp_path)

    async def broken():
        yield b"abc" * KB
        raise ConnectionError("client gone")

    with pytest.raises(ConnectionError):
        run(storage.save_upload("p", "briefs", "x.bin", broken(), max_bytes=MB))
    assert files_under(root) == []


def test_streaming_does_not_buffer_whole_file(tmp_path):
    storage, root = make_storage(tmp_path)
    on_disk_at_4mb = []

    async def source():
        for i in range(5 * 1024):
            if i == 4 * 1024:
                on_disk_at_4mb.append(sum(p.stat().st_size for p in files_under(root)))
            yield b"y" * KB

    tracemalloc.start()
    try:
        saved = run(storage.save_upload("p", "briefs", "five.bin", source(), max_bytes=10 * MB))
        _, peak = tracemalloc.get_traced_memory()
    finally:
        tracemalloc.stop()
    assert saved.size_bytes == 5 * MB
    assert on_disk_at_4mb and on_disk_at_4mb[0] >= 2 * MB      # данные уже на диске, а не в памяти
    assert peak < 2 * MB


def test_concurrent_same_name_do_not_clobber(tmp_path):
    storage, root = make_storage(tmp_path)

    async def many():
        payloads = [bytes([i]) * (3 * KB) for i in range(8)]
        return payloads, await asyncio.gather(*[
            storage.save_upload("p", "briefs", "same.txt", chunked(data), max_bytes=MB) for data in payloads
        ])

    payloads, saved = run(many())
    assert len({s.material_id for s in saved}) == 8
    assert len({s.path_rel for s in saved}) == 8
    for data, item in zip(payloads, saved):
        assert (root / item.path_rel).read_bytes() == data


@pytest.mark.parametrize("bad", ["../x", "a/b", "", "x" * 65, "пробел", "a b", "a\x00b", ".."])
def test_ids_validated(tmp_path, bad):
    storage, root = make_storage(tmp_path)
    with pytest.raises(ValueError):
        run(storage.save_upload(bad, "briefs", "a.txt", chunked(b"1"), max_bytes=10))
    with pytest.raises(ValueError):
        run(storage.save_upload("p", "briefs", "a.txt", chunked(b"1"), max_bytes=10, material_id=bad))
    assert files_under(root) == []


def test_id_boundary_64_ok(tmp_path):
    storage, _ = make_storage(tmp_path)
    saved = run(storage.save_upload("A" * 64, "briefs", "a.txt", chunked(b"1"), max_bytes=10, material_id="z_-" * 21 + "z"))
    assert saved.size_bytes == 1


def test_kind_validated(tmp_path):
    storage, root = make_storage(tmp_path)
    with pytest.raises(ValueError):
        run(storage.save_upload("p", "other", "a.txt", chunked(b"1"), max_bytes=10))
    with pytest.raises(ValueError):
        run(storage.save_upload("p", "../briefs", "a.txt", chunked(b"1"), max_bytes=10))
    assert files_under(root) == []


def test_symlink_out_in_target_dir_rejected(tmp_path):
    from app.services.storage import UnsafePath
    storage, root = make_storage(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    project = root / "projects" / "p"
    project.mkdir(parents=True)
    (project / "briefs").symlink_to(outside, target_is_directory=True)
    with pytest.raises(UnsafePath):
        run(storage.save_upload("p", "briefs", "a.txt", chunked(b"secret"), max_bytes=100))
    assert list(outside.iterdir()) == []


def test_symlink_as_material_dir_rejected(tmp_path):
    from app.services.storage import UnsafePath
    storage, root = make_storage(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    briefs = root / "projects" / "p" / "briefs"
    briefs.mkdir(parents=True)
    (briefs / "m1").symlink_to(outside, target_is_directory=True)
    with pytest.raises(UnsafePath):
        run(storage.save_upload("p", "briefs", "a.txt", chunked(b"secret"), max_bytes=100, material_id="m1"))
    assert list(outside.iterdir()) == []


# --- delete_project_materials ---------------------------------------------------------------------------


def test_delete_project_materials(tmp_path):
    storage, root = make_storage(tmp_path)
    a = run(storage.save_upload("p", "briefs", "a.txt", chunked(b"1"), max_bytes=10))
    b = run(storage.save_upload("p", "submissions", "b.txt", chunked(b"2"), max_bytes=10))
    c = run(storage.save_upload("p", "submissions", "c.txt", chunked(b"3"), max_bytes=10))
    other = run(storage.save_upload("q", "briefs", "o.txt", chunked(b"4"), max_bytes=10))
    assert storage.delete_project_materials("p") == 3
    for kind in ("briefs", "submissions"):
        directory = root / "projects" / "p" / kind
        assert directory.is_dir() and list(directory.iterdir()) == []
    assert (root / other.path_rel).read_bytes() == b"4"
    assert not any((root / s.path_rel).exists() for s in (a, b, c))


def test_delete_unknown_project_returns_zero(tmp_path):
    storage, _ = make_storage(tmp_path)
    assert storage.delete_project_materials("nope") == 0
    with pytest.raises(ValueError):
        storage.delete_project_materials("../p")


def test_delete_does_not_follow_symlinks(tmp_path):
    storage, root = make_storage(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("keep")
    outside_file = tmp_path / "outside.txt"
    outside_file.write_text("keep")
    briefs = root / "projects" / "p" / "briefs"
    briefs.mkdir(parents=True)
    (briefs / "dirlink").symlink_to(outside, target_is_directory=True)
    (briefs / "filelink").symlink_to(outside_file)
    removed = storage.delete_project_materials("p")
    assert removed == 2
    assert (outside / "keep.txt").read_text() == "keep" and outside_file.read_text() == "keep"
    assert list(briefs.iterdir()) == []


def test_delete_skips_kind_dir_that_is_symlink(tmp_path):
    storage, root = make_storage(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.txt").write_text("keep")
    project = root / "projects" / "p"
    project.mkdir(parents=True)
    (project / "briefs").symlink_to(outside, target_is_directory=True)
    saved = run(storage.save_upload("p", "submissions", "s.txt", chunked(b"1"), max_bytes=10))
    assert storage.delete_project_materials("p") == 1
    assert (outside / "keep.txt").read_text() == "keep"
    assert not (root / saved.path_rel).exists()
