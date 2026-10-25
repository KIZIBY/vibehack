from __future__ import annotations

import json
import time
from pathlib import Path

from intake import similarity


def _body(seed: int) -> str:
    return "\n".join(f"x{i} = foo(bar, {seed * 1009 + i * 37 + 311}) + {seed * 503 + i * 29 + 607}" for i in range(40))


def _write(root: Path, name: str, files: dict[str, str]) -> Path:
    base = root / name
    for rel, text in files.items():
        (base / rel).parent.mkdir(parents=True, exist_ok=True)
        (base / rel).write_text(text, encoding="utf-8")
    return base


def test_comment_in_first_line_does_not_hide_the_rest_of_file(tmp_path: Path) -> None:
    shared = _body(1)
    a = _write(tmp_path, "a", {"m.py": "#!/usr/bin/env python\n# coding: utf-8\nurl = 'http://example.org/x'\n" + shared})
    b = _write(tmp_path, "b", {"m.py": shared})
    c = _write(tmp_path, "c", {"m.py": _body(2)})
    doc = similarity.compare({"a": a, "b": b, "c": c}, "p")
    assert any({p["submission_a"], p["submission_b"]} == {"a", "b"} and p["similarity"] >= 0.5 for p in doc["pairs"])


def test_hostile_comment_and_string_input_is_linear(tmp_path: Path) -> None:
    a = _write(tmp_path, "a", {"x.js": "/*" * 400_000, "y.js": '"' * 400_000, "z.js": "'\\" * 200_000})
    started = time.monotonic()
    similarity.compare({"a": a, "b": a}, "p")
    assert time.monotonic() - started < 10
    json.dumps(similarity.compare({"a": a}, "p"))
