"""Сравнение кода работ внутри проекта: отпечатки токенов (шингл 5) + winnowing → similarity.json (T049, FR-018).

Идентификаторы нормализуются (переименование не прячет копию), общий для большинства работ код считается шаблонным.
Результат — подсказка проверяющему, не вердикт. Содержимое работ — данные.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import datetime, timezone
from math import ceil
from pathlib import Path


K = 5
WINDOW = 4
MIN_REPORT = 0.1
MAX_FRAGMENTS = 20
MAX_FILE_BYTES = 1_000_000
METHOD = "token-shingles-5 + winnowing"
SKIP_DIRS = {".git", "node_modules", "vendor", "dist", "build", "target", "out", ".venv", "venv", "__pycache__", ".next", "site-packages"}
SKIP_FILES = {"package-lock.json", "yarn.lock", "pnpm-lock.yaml", "poetry.lock", "Cargo.lock", "go.sum", "composer.lock", "Pipfile.lock"}
CODE_EXT = {".py", ".js", ".jsx", ".ts", ".tsx", ".java", ".kt", ".go", ".rs", ".rb", ".php", ".cs", ".cpp", ".cc", ".c", ".h", ".swift", ".sql", ".sh"}
KEYWORDS = set("""def class return if elif else for while in not and or is import from as with try except finally raise yield lambda pass break continue
function const let var new this typeof async await export default switch case throw catch true false null none undefined static public private protected
void int long float double bool boolean string char struct enum interface implements extends package fn pub use mod impl match loop mut self func go
range print del global nonlocal assert do goto sizeof extern typedef namespace template using unsigned signed short""".split())
_STR = r"\"(?:\\.|[^\"\\\n])*\"?|'(?:\\.|[^'\\\n])*'?"
_BODY = r"|(?P<s>" + _STR + r")|(?P<n>\d+(?:\.\d+)?)|(?P<i>[A-Za-z_]\w*)|(?P<o>\S)"
_BLOCK = r"(?P<c>/\*(?:[^*]|\*(?!/))*(?:\*/|\Z)"
_LEX_HASH = re.compile(_BLOCK.replace("/\\*", "(?!)") + r"|#[^\n]*)" + _BODY)  # py/rb/sh: только # (блочных нет)
_LEX_SLASH = re.compile(_BLOCK + r"|//[^\n]*)" + _BODY)
_HASH_EXT = {".py", ".rb", ".sh"}


def _tokens(text: str, suffix: str = ".py") -> list[tuple[str, int]]:
    """Один линейный проход: строки, комментарии и токены; номер строки считается по переводам \\n."""
    lexer = _LEX_HASH if suffix in _HASH_EXT else _LEX_SLASH
    out: list[tuple[str, int]] = []
    line, last = 1, 0
    for match in lexer.finditer(text):
        line += text.count("\n", last, match.start())
        last = match.start()
        kind = match.lastgroup
        if kind == "c":
            continue
        token = match.group(0)
        if len(token) > 20_000:  # минифицированный код или мусор
            continue
        if kind == "i":
            token = token if token.lower() in KEYWORDS else "ID"
        out.append((token.lower() if token != "ID" else token, line))
    return out


def _hash(parts: list[str]) -> int:
    return int.from_bytes(hashlib.blake2b("\x1f".join(parts).encode("utf-8"), digest_size=8).digest(), "big")


_EMPTY = 1 << 64


def _gram(window: list[tuple[str, int]]) -> int:
    """Хеш шингла; чисто структурные шингла (def ID ( ID ,) не информативны и отбрасываются."""
    values = [t for t, _ in window]
    if not any((t[0].isdigit() and len(t) > 1) or t[0] in "\"'" for t in values):
        return _EMPTY
    return _hash(values)


def _winnow(tokens: list[tuple[str, int]]) -> list[tuple[int, int, int]]:
    """[(хеш, строка начала, строка конца)] выбранных отпечатков."""
    count = len(tokens) - K + 1
    if count <= 0:
        return []
    grams = [_gram(tokens[i:i + K]) for i in range(count)]
    chosen: dict[int, tuple[int, int, int]] = {}
    for start in range(max(1, count - WINDOW + 1)):
        window = grams[start:start + WINDOW]
        smallest = min(window)
        if smallest == _EMPTY:
            continue
        position = start + len(window) - 1 - window[::-1].index(smallest)
        chosen[position] = (smallest, tokens[position][1], tokens[position + K - 1][1])
    return [chosen[key] for key in sorted(chosen)]


def _code_files(root: Path) -> list[Path]:
    found: list[Path] = []
    for current, dirs, files in os.walk(root):
        dirs[:] = sorted(name for name in dirs if name not in SKIP_DIRS and not (Path(current) / name).is_symlink())
        for name in sorted(files):
            path = Path(current) / name
            if name in SKIP_FILES or name.endswith((".min.js", ".min.css")) or path.suffix.lower() not in CODE_EXT or path.is_symlink():
                continue
            try:
                if path.stat().st_size <= MAX_FILE_BYTES:
                    found.append(path)
            except OSError:
                continue
    return found


def _fingerprints(root: Path) -> dict[int, list[tuple[str, int, int]]]:
    index: dict[int, list[tuple[str, int, int]]] = {}
    if not root.is_dir():
        return index
    for path in _code_files(root):
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        relative = path.relative_to(root).as_posix()
        for value, first, last in _winnow(_tokens(text, path.suffix.lower())):
            index.setdefault(value, []).append((relative, first, last))
    return index


def _fragments(a: dict[int, list], b: dict[int, list], shared: set[int]) -> list[dict]:
    records = []
    for value in shared:
        fa, la1, la2 = a[value][0]
        fb, lb1, lb2 = b[value][0]
        records.append([fa, fb, la1, la2, lb1, lb2])
    records.sort(key=lambda r: (r[0], r[1], r[2], r[3]))
    merged: list[list] = []
    for rec in records:
        last = merged[-1] if merged else None
        if last and last[0] == rec[0] and last[1] == rec[1] and rec[2] <= last[3] + 1:
            last[3] = max(last[3], rec[3])
            last[4] = min(last[4], rec[4])
            last[5] = max(last[5], rec[5])
        else:
            merged.append(rec)
    merged.sort(key=lambda r: (-(r[3] - r[2] + 1), r[0], r[2]))
    return [{"a": f"{r[0]}:{r[2]}-{r[3]}", "b": f"{r[1]}:{r[4]}-{r[5]}", "lines": r[3] - r[2] + 1} for r in merged[:MAX_FRAGMENTS]]


def compare(works: dict[str, str | Path], project_id: str) -> dict:
    indexes = {name: _fingerprints(Path(path)) for name, path in sorted(works.items())}
    total = len(indexes)
    presence: dict[int, int] = {}
    for index in indexes.values():
        for value in index:
            presence[value] = presence.get(value, 0) + 1
    limit = max(3, ceil(0.75 * total))  # общий для почти всех код — шаблон, не плагиат
    kept = {name: {v: pos for v, pos in index.items() if presence[v] < limit} for name, index in indexes.items()}
    names = sorted(kept)
    pairs = []
    for i, left in enumerate(names):
        for right in names[i + 1:]:
            shared = set(kept[left]) & set(kept[right])
            smaller = min(len(kept[left]), len(kept[right]))
            if not shared or not smaller:
                continue
            score = len(shared) / smaller
            if score >= MIN_REPORT:
                pairs.append({"submission_a": left, "submission_b": right, "similarity": round(min(score, 1.0), 4), "fragments": _fragments(kept[left], kept[right], shared)})
    pairs.sort(key=lambda p: (-p["similarity"], p["submission_a"], p["submission_b"]))
    return {"schema_version": "1", "project_id": project_id, "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"), "method": METHOD, "pairs": pairs}


def write_similarity(project_id: str, works: dict[str, str | Path], target: str | Path) -> dict:
    document = compare(works, project_id)
    target = Path(target)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(json.dumps(document, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return document
