#!/bin/bash
# build.sh — сборка frontend (PROJECT.md §3). Backend и intake — Python, сборки не требуют.
# Exit: 0 = собрано или собирать нечего (SKIP) · иначе код npm
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"
if [ ! -f frontend/package.json ]; then
  echo "SKIP build: frontend/package.json нет (frontend — задача T080)"
  exit 0
fi
cd frontend && npm run build
