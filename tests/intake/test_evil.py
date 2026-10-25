from __future__ import annotations

import io
import tarfile
import zipfile
from pathlib import Path

import pytest

from intake.inventory import build_inventory
from intake.unpack import UnsafeArchive, safe_unpack


def test_path_traversal_is_rejected(tmp_path: Path) -> None:
    archive = tmp_path / "traversal.zip"
    with zipfile.ZipFile(archive, "w") as handle:
        handle.writestr("../../outside.txt", "escape")
    with pytest.raises(UnsafeArchive, match="traversal|escapes"):
        safe_unpack(archive, tmp_path / "out")


def test_tar_symlink_is_not_materialized(tmp_path: Path) -> None:
    archive = tmp_path / "symlink.tar"
    with tarfile.open(archive, "w") as handle:
        info = tarfile.TarInfo("etc-passwd")
        info.type = tarfile.SYMTYPE
        info.linkname = "/etc/passwd"
        handle.addfile(info)
    report = safe_unpack(archive, tmp_path / "out")
    assert report.skipped_symlinks == 1
    assert not (tmp_path / "out" / "etc-passwd").exists()


def test_expanded_size_limit_rejects_archive_bomb(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    archive = tmp_path / "bomb.zip"
    with zipfile.ZipFile(archive, "w") as handle:
        handle.writestr("large.txt", "0123456789")
    monkeypatch.setattr("intake.unpack.MAX_BYTES", 5)
    with pytest.raises(UnsafeArchive, match="size limit"):
        safe_unpack(archive, tmp_path / "out")


def test_inventory_marks_missing_repository_and_keeps_injection_as_data() -> None:
    fixture = Path("tests/fixtures/submissions/prompt-injection")
    inventory = build_inventory(fixture, required=["repository"])
    assert inventory["completeness"] == {"status": "incomplete", "required": ["repository"], "missing": ["repository"]}
    assert any("судья" in fixture_file.read_text(encoding="utf-8") for fixture_file in fixture.glob("*.md"))


def test_fixture_corpus_contains_three_educational_cases() -> None:
    root = Path("tests/fixtures/submissions")
    assert {"good", "weak", "prompt-injection"}.issubset({item.name for item in root.iterdir() if item.is_dir()})
