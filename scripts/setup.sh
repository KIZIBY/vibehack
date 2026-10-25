#!/bin/bash
# setup.sh — установка зависимостей: .venv с requirements-dev.txt, npm install во frontend и tests/e2e.
# SETUP_DRY_RUN=1 — только напечатать шаги. Нужны python3 (3.11+) и, для frontend, node/npm.
# Exit: 0 = готово · иначе код упавшего шага
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"

DRY="${SETUP_DRY_RUN:-0}"
run() {
  if [ "$DRY" = 1 ]; then echo "setup[dry-run]: $*"; else echo "setup: $*"; "$@"; fi
}

[ -d .venv ] || run python3 -m venv .venv || exit $?
run .venv/bin/python -m pip install -q -r requirements-dev.txt || exit $?
if [ -f frontend/package.json ]; then
  if [ "$DRY" = 1 ]; then echo "setup[dry-run]: (cd frontend && npm install)"
  else echo "setup: (cd frontend && npm install)"; (cd frontend && npm install) || exit $?; fi
fi
if [ -f tests/e2e/package.json ]; then
  if [ "$DRY" = 1 ]; then echo "setup[dry-run]: (cd tests/e2e && npm install)"
  else echo "setup: (cd tests/e2e && npm install)"; (cd tests/e2e && npm install) || exit $?; fi
fi
echo "setup: OK"
