from __future__ import annotations

import argparse
from pathlib import Path

from .pipeline import run_pipeline


def main() -> int:
    parser = argparse.ArgumentParser(description="Build an inventory for one submission")
    parser.add_argument("source", type=Path, help="submission directory")
    parser.add_argument("--out", required=True, type=Path, help="directory for inventory.json")
    parser.add_argument("--project-id", default="project")
    parser.add_argument("--submission-id")
    parser.add_argument("--team-name")
    parser.add_argument("--required", action="append", default=[])
    args = parser.parse_args()
    run_pipeline(args.source, args.out, project_id=args.project_id, submission_id=args.submission_id, team_name=args.team_name, required=args.required)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
