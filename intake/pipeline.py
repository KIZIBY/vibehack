from __future__ import annotations

import json
import traceback
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def run_pipeline(source: Path, output: Path, *, project_id: str = "project", submission_id: str | None = None, team_name: str | None = None, required: list[str] | None = None) -> dict:
    """Run intake stages and always write an inventory, including partial failures."""
    submission_id = submission_id or source.name
    required = required or []
    inventory = {"schema_version": "1", "submission_id": submission_id, "project_id": project_id, "team_name": team_name or source.name, "created_at": _now(), "materials": [], "completeness": {"status": "complete", "required": required, "missing": []}, "limits_applied": [], "warnings": []}
    stages: list[tuple[str, Callable[[], None]]] = []

    def collect() -> None:
        if not source.is_dir():
            raise FileNotFoundError(f"source directory does not exist: {source}")
        for item in sorted(source.rglob("*")):
            if not item.is_file():
                continue
            relative = item.relative_to(source).as_posix()
            inventory["materials"].append({"material_id": relative, "type": "other", "source": {"kind": "upload", "path": relative}, "status": "available", "size_bytes": item.stat().st_size})

    stages.append(("collect", collect))
    failures: list[str] = []
    for name, stage in stages:
        try:
            stage()
        except Exception as exc:  # intake must preserve partial results
            reason = f"{name}: {exc}"
            failures.append(reason)
            inventory["warnings"].append(reason)
            traceback.print_exc()

    available_types = {item["type"] for item in inventory["materials"]}
    missing = [item for item in required if item not in available_types]
    inventory["completeness"] = {"status": "incomplete" if missing or failures else "complete", "required": required, "missing": missing}
    output.mkdir(parents=True, exist_ok=True)
    target = output / "inventory.json"
    target.write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return inventory

