from __future__ import annotations

import argparse
import json
import time
from pathlib import Path

from .inventory import build_inventory


def main() -> int:
    parser = argparse.ArgumentParser(description="Measure intake inventory build time")
    parser.add_argument("source", type=Path, help="prepared benchmark submission directory")
    parser.add_argument("--output", type=Path, default=Path("intake-benchmark.json"))
    args = parser.parse_args()
    started = time.monotonic()
    inventory = build_inventory(args.source, required=["repository", "presentation", "screencast"])
    result = {"source": args.source.as_posix(), "elapsed_seconds": round(time.monotonic() - started, 3), "material_count": len(inventory["materials"]), "completeness": inventory["completeness"], "limits_applied": inventory["limits_applied"], "target_seconds": 180, "within_target": False}
    result["within_target"] = result["elapsed_seconds"] <= result["target_seconds"]
    args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
