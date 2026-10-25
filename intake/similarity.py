from __future__ import annotations

import hashlib
import json
import re
from itertools import combinations
from pathlib import Path


WINDOW = 5
MAX_FRAGMENTS = 20
EXCLUDED_PARTS = {"node_modules", "dist", "build", ".git", "__pycache__", ".venv", "vendor"}
TOKEN = re.compile(r"[A-Za-z_][A-Za-z0-9_]*|\d+|[^\sA-Za-z0-9_]", re.UNICODE)


def _tokens(text: str) -> list[str]:
    return [token.lower() for token in TOKEN.findall(text)]


def _fingerprints(tokens: list[str]) -> dict[str, tuple[int, int]]:
    result: dict[str, tuple[int, int]] = {}
    for index in range(max(0, len(tokens) - WINDOW + 1)):
        window = " ".join(tokens[index:index + WINDOW])
        digest = hashlib.sha1(window.encode("utf-8")).hexdigest()
        result.setdefault(digest, (index, index + WINDOW))
    return result


def _files(root: Path) -> list[Path]:
    return [path for path in root.rglob("*") if path.is_file() and not any(part in EXCLUDED_PARTS for part in path.relative_to(root).parts) and path.suffix.lower() in {".py", ".js", ".jsx", ".ts", ".tsx", ".java", ".go", ".rs", ".rb", ".php", ".c", ".cpp", ".h"}]


def compare_submissions(submissions: dict[str, str | Path], output: str | Path | None = None) -> dict:
    fingerprints: dict[str, dict[str, tuple[int, int]]] = {}
    for submission_id, root_value in submissions.items():
        root = Path(root_value)
        current: dict[str, tuple[int, int]] = {}
        for path in _files(root):
            try:
                current.update({f"{digest}:{path.relative_to(root).as_posix()}": span for digest, span in _fingerprints(path.read_text(encoding="utf-8", errors="ignore" )).items()})
            except OSError:
                continue
        fingerprints[submission_id] = current
    pairs = []
    for left, right in combinations(sorted(fingerprints), 2):
        left_by_digest = {key.split(":", 1)[0]: (key, span) for key, span in fingerprints[left].items()}
        right_by_digest = {key.split(":", 1)[0]: (key, span) for key, span in fingerprints[right].items()}
        shared = sorted(set(left_by_digest) & set(right_by_digest))
        left_count = len(fingerprints[left])
        right_count = len(fingerprints[right])
        score = len(shared) / max(1, min(left_count, right_count))
        fragments = [{"left": left_by_digest[digest][0].split(":", 1)[1], "right": right_by_digest[digest][0].split(":", 1)[1], "hash": digest} for digest in shared[:MAX_FRAGMENTS]]
        pairs.append({"submission_a": left, "submission_b": right, "score": round(score, 4), "shared_windows": len(shared), "fragments": fragments})
    result = {"schema_version": "1", "pairs": pairs}
    if output:
        target = Path(output); target.parent.mkdir(parents=True, exist_ok=True); target.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result
