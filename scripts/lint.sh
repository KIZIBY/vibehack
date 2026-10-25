#!/bin/bash
# lint.sh — линт проекта: ruff по Python-зонам (конфиг — ruff.toml), npm run lint во frontend.
# ruff берётся из .venv (scripts/setup.sh). Есть Python-код продукта (backend/intake/hermes), а ruff нет —
# exit 2 (fail-closed); линтить нечего — честный SKIP.
# Exit: 0 = чисто или линтить нечего · 2 = нет ruff при наличии кода · иначе код инструмента
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"

rc=0
dirs=""
for d in backend intake hermes tests; do [ -d "$d" ] && dirs="$dirs $d"; done
has_product_py=0
for d in backend intake hermes; do
  [ -d "$d" ] && [ -n "$(find "$d" -name '*.py' -print -quit)" ] && has_product_py=1
done
if [ -x .venv/bin/ruff ]; then
  # shellcheck disable=SC2086
  .venv/bin/ruff check $dirs || rc=$?
elif [ "$has_product_py" -eq 1 ]; then
  echo "lint: есть Python-код продукта, а .venv/bin/ruff нет — выполни: bash scripts/setup.sh" >&2
  exit 2
else
  echo "SKIP lint python: Python-кода продукта нет"
fi

if [ -f frontend/package.json ] && grep -q '"lint"' frontend/package.json; then
  (cd frontend && npm run lint) || rc=$?
else
  echo "SKIP lint frontend: нет frontend/package.json со скриптом lint"
fi
[ "$rc" -eq 0 ] && echo "lint: OK"
exit "$rc"
