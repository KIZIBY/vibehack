from __future__ import annotations

import json
from pathlib import Path

import jsonschema

from intake import similarity

SCHEMA = Path(__file__).resolve().parents[2] / "specs" / "001-ai-judge-platform" / "contracts" / "similarity.schema.json"


def _funcs(seed: int, count: int = 12) -> str:
    """Код, чья структура зависит от seed: числа, операторы и ветвления различаются."""
    lines = []
    for index in range(count):
        op = "+-*%"[(seed + index) % 4]
        lines += [
            f"def handler_{seed}_{index}(value, limit):",
            f"    total = value {op} {seed * 1009 + index * 37 + 311}",
            f"    if total > limit * {seed * 211 + index * 17 + 101}:",
            f"        return total {op} {seed * 503 + index * 29 + 607}",
            f"    for step in range({seed * 307 + index * 13 + 401}):",
            f"        total = total {op} step * {seed * 619 + index * 23 + 701}",
            "    return total",
            "",
        ]
    return "\n".join(lines)


def _work(root: Path, name: str, files: dict[str, str]) -> Path:
    base = root / name
    for rel, text in files.items():
        target = base / rel
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(text, encoding="utf-8")
    return base


def _doc(tmp_path: Path, works: dict[str, Path]) -> dict:
    target = tmp_path / "similarity.json"
    similarity.write_similarity("proj", works, target)
    return json.loads(target.read_text(encoding="utf-8"))


def _pair(doc: dict, a: str, b: str) -> dict | None:
    for item in doc["pairs"]:
        if {item["submission_a"], item["submission_b"]} == {a, b}:
            return item
    return None


def test_copied_file_gives_high_similarity_with_fragments(tmp_path: Path) -> None:
    shared = _funcs(1)
    a = _work(tmp_path, "a", {"src/main.py": shared, "util.py": _funcs(2)})
    b = _work(tmp_path, "b", {"app/core.py": shared, "other.py": _funcs(3)})
    c = _work(tmp_path, "c", {"main.py": _funcs(4)})
    doc = _doc(tmp_path, {"a": a, "b": b, "c": c})
    pair = _pair(doc, "a", "b")
    assert pair is not None and pair["similarity"] >= 0.4
    assert pair["fragments"] and pair["fragments"][0]["a"].startswith("src/main.py:")
    assert pair["fragments"][0]["b"].startswith("app/core.py:")
    assert pair["fragments"][0]["lines"] >= 5
    assert pair["submission_a"] < pair["submission_b"]


def test_independent_works_have_no_pair(tmp_path: Path) -> None:
    works = {name: _work(tmp_path, name, {"main.py": _funcs(seed)}) for seed, name in enumerate("abc", start=1)}
    assert _doc(tmp_path, works)["pairs"] == []


def test_renamed_identifiers_are_still_detected(tmp_path: Path) -> None:
    original = _funcs(5)
    renamed = original.replace("total", "acc").replace("value", "x").replace("limit", "cap").replace("step", "i")
    a = _work(tmp_path, "a", {"m.py": original})
    b = _work(tmp_path, "b", {"m.py": renamed})
    pair = _pair(_doc(tmp_path, {"a": a, "b": b}), "a", "b")
    assert pair is not None and pair["similarity"] >= 0.5


def test_boilerplate_shared_by_everyone_is_excluded(tmp_path: Path) -> None:
    template = _funcs(9)
    works = {name: _work(tmp_path, name, {"template.py": template, "own.py": _funcs(seed)}) for seed, name in enumerate("abcd", start=20)}
    assert _doc(tmp_path, works)["pairs"] == []


def test_lockfiles_and_dependency_dirs_are_ignored(tmp_path: Path) -> None:
    shared = _funcs(7)
    a = _work(tmp_path, "a", {"node_modules/dep/index.js": shared, "main.py": _funcs(1)})
    b = _work(tmp_path, "b", {"node_modules/dep/index.js": shared, "package-lock.json": shared, "main.py": _funcs(2)})
    assert _doc(tmp_path, {"a": a, "b": b})["pairs"] == []


def test_at_most_twenty_fragments_per_pair(tmp_path: Path) -> None:
    parts = [_funcs(40 + i, 1) + f"\nmarker_{i} = {i * 977}\nprint('{'x' * (i + 3)}', {i * 13})\n" for i in range(30)]
    a = _work(tmp_path, "a", {f"f{i}.py": text for i, text in enumerate(parts)})
    b = _work(tmp_path, "b", {f"g{i}.py": text for i, text in enumerate(parts)})
    pair = _pair(_doc(tmp_path, {"a": a, "b": b}), "a", "b")
    assert pair is not None and 1 <= len(pair["fragments"]) <= 20


def test_output_matches_contract_schema(tmp_path: Path) -> None:
    shared = _funcs(1)
    a = _work(tmp_path, "a", {"m.py": shared})
    b = _work(tmp_path, "b", {"m.py": shared})
    doc = _doc(tmp_path, {"a": a, "b": b})
    jsonschema.Draft202012Validator(json.loads(SCHEMA.read_text(encoding="utf-8")), format_checker=jsonschema.FormatChecker()).validate(doc)
    assert doc["project_id"] == "proj" and doc["method"]


def test_works_without_code_or_missing_dirs_give_empty_result(tmp_path: Path) -> None:
    a = _work(tmp_path, "a", {"README.md": "# hi"})
    doc = _doc(tmp_path, {"a": a, "b": tmp_path / "missing"})
    assert doc["pairs"] == []
