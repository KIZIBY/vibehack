#!/usr/bin/env bash
# run_role.sh — Ручной запуск роли Hermes на каталоге работы (T070)
# Usage: hermes/scripts/run_role.sh <role> <каталог работы>
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ $# -lt 2 ]; then
  echo "Usage: hermes/scripts/run_role.sh <role> <каталог работы>" >&2
  exit 2
fi

PYTHON_BIN="python3"
if ! command -v python3 >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

exec "$PYTHON_BIN" "$SCRIPT_DIR/run_role.py" "$@"
