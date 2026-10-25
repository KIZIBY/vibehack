from __future__ import annotations

import argparse
import sys
from pathlib import Path

from .pipeline import run_pipeline


def main() -> int:
    parser = argparse.ArgumentParser(description="Build an inventory for one submission")
    parser.add_argument("source", type=Path, help="submission directory")
    parser.add_argument("--out", required=True, type=Path, help="directory for inventory.json")
    parser.add_argument("--project-id", default="project")
    parser.add_argument("--submission-id")
    parser.add_argument("--team-name")
    parser.add_argument("--required", action="append", default=[], help="тип обязательного материала; можно повторять или через запятую")
    parser.add_argument("--data-root", type=Path, help="корень данных платформы (по умолчанию определяется по раскладке projects/<p>/submissions/<s>)")
    args, unknown = parser.parse_known_args()
    if unknown:
        print(f"intake: неизвестные аргументы проигнорированы: {len(unknown)}", file=sys.stderr)
    try:
        run_pipeline(args.source, args.out, project_id=args.project_id, submission_id=args.submission_id, team_name=args.team_name, required=args.required, data_root=args.data_root)
    except Exception as exc:  # noqa: BLE001 — выход 0 даже при сбое: причина в stderr, опись пишет конвейер
        print(f"intake: сбой конвейера: {type(exc).__name__}", file=sys.stderr)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
