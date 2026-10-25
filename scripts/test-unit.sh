#!/bin/bash
# test-unit.sh — unit-тесты зон проекта (PROJECT.md §3).
# Usage: bash scripts/test-unit.sh [backend|intake|hermes|frontend|all]   (без аргумента = all)
# Exit:  0 = зелёный или у зоны нет тестов (печатается SKIP) · 1 = красная зона ·
#        2 = неизвестная зона или нет pytest при наличии тестов (подсказка: bash scripts/setup.sh)
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"

zone_backend()  { run_pytest backend tests/backend; }
zone_intake()   { run_pytest intake tests/intake; }

zone_hermes() {
  local scan=0
  scan_tests hermes/tests || scan=$?
  if [ "$scan" -eq 2 ]; then return 2; fi
  if [ "$scan" -eq 1 ]; then echo "SKIP hermes: тестов нет"; return 0; fi
  "$PY" -m unittest discover -s hermes/tests || { echo "FAIL hermes: unittest красный" >&2; return 1; }
}

zone_frontend() {
  if [ ! -f frontend/package.json ]; then echo "SKIP frontend: тестов нет"; return 0; fi
  (cd frontend && npm test) || { echo "FAIL frontend: npm test красный" >&2; return 1; }
}

ZONE="${1:-all}"
case "$ZONE" in
  backend|intake|hermes|frontend) "zone_$ZONE"; exit $? ;;
  all) ;;
  *) echo "test-unit: неизвестная зона '$ZONE' (usage: backend|intake|hermes|frontend|all)" >&2; exit 2 ;;
esac

worst=0; red=""
for z in backend intake hermes frontend; do
  rc=0; "zone_$z" || rc=$?
  if [ "$rc" -ne 0 ]; then red="$red $z"; [ "$rc" -gt "$worst" ] && worst=$rc; fi
done
if [ "$worst" -ne 0 ]; then echo "test-unit: красные зоны:$red" >&2; exit "$worst"; fi
echo "test-unit: OK"
