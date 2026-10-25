from __future__ import annotations

import json
from datetime import datetime, timezone
from pathlib import Path

from .classify import classify


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def build_inventory(source: str | Path, *, project_id: str = "project", submission_id: str | None = None, team_name: str | None = None, required: list[str] | None = None, limits_applied: list[str] | None = None, warnings: list[str] | None = None) -> dict:
    source = Path(source)
    required = required or []
    materials: list[dict] = []
    local_warnings = list(warnings or [])
    if not source.is_dir():
        local_warnings.append(f"source unavailable: {source}")
    else:
        for path in sorted(item for item in source.rglob("*") if item.is_file()):
            relative = path.relative_to(source).as_posix()
            try:
                info = classify(path, relative=relative)
                materials.append({"material_id": relative, "type": info["type"], "source": {"kind": "upload", "path": relative}, "status": "available", "size_bytes": path.stat().st_size})
            except OSError as exc:
                materials.append({"material_id": relative, "type": "other", "source": {"kind": "upload", "path": relative}, "status": "unavailable", "reason": str(exc)})
    available_types = {item["type"] for item in materials if item["status"] == "available"}
    missing = [item for item in required if item not in available_types]
    return {"schema_version": "1", "submission_id": submission_id or source.name, "project_id": project_id, "team_name": team_name or source.name, "created_at": _now(), "materials": materials, "completeness": {"status": "incomplete" if missing or local_warnings else "complete", "required": required, "missing": missing}, "limits_applied": limits_applied or [], "warnings": local_warnings}


def write_inventory(source: str | Path, output: str | Path, **kwargs) -> dict:
    inventory = build_inventory(source, **kwargs)
    target = Path(output)
    target.mkdir(parents=True, exist_ok=True)
    (target / "inventory.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return inventory
