#!/bin/bash
# test-unit.sh — unit-тесты зон проекта (PROJECT.md §3).
# Usage: bash scripts/test-unit.sh [backend|intake|hermes|frontend|contracts|all]   (без аргумента = all)
# Exit:  0 = зелёный или у зоны нет тестов (печатается SKIP) · 1 = красная зона ·
#        2 = неизвестная зона или нет pytest при наличии тестов (подсказка: bash scripts/setup.sh)
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"

zone_backend()  { run_pytest backend tests/backend; }
zone_intake()   { run_pytest intake tests/intake; }
zone_contracts() { run_pytest contracts tests/contracts; }

zone_hermes() {
  local scan=0
  scan_tests hermes/tests || scan=$?
  if [ "$scan" -eq 2 ]; then return 2; fi
  if [ "$scan" -eq 1 ]; then echo "SKIP hermes: тестов нет"; return 0; fi
  "$PY" -m unittest discover -s hermes/tests || { echo "FAIL hermes: unittest красный" >&2; return 1; }
}

zone_frontend() {
  if [ ! -f frontend/package.json ]; then echo "SKIP frontend: тестов нет"; return 0; fi
  local has_test
  # perl с JSON::PP из ядра: не зависит от интерпретатора Python проекта; нечитаемый JSON — fail-closed
  has_test="$(perl -MJSON::PP -0777 -e 'my $d = decode_json(<>); print exists $d->{scripts}{test} ? "yes" : "no"' frontend/package.json 2>/dev/null)" || {
    echo "test-unit: frontend/package.json не читается (невалидный JSON)" >&2; return 2; }
  if [ "$has_test" != "yes" ]; then echo "SKIP frontend: тестов нет (в package.json нет скрипта test)"; return 0; fi
  (cd frontend && npm test) || { echo "FAIL frontend: npm test красный" >&2; return 1; }
}

ZONE="${1:-all}"
case "$ZONE" in
  backend|intake|hermes|frontend|contracts) "zone_$ZONE"; exit $? ;;
  all) ;;
  *) echo "test-unit: неизвестная зона '$ZONE' (usage: backend|intake|hermes|frontend|contracts|all)" >&2; exit 2 ;;
esac

worst=0; red=""
for z in backend intake contracts hermes frontend; do
  rc=0; "zone_$z" || rc=$?
  if [ "$rc" -ne 0 ]; then red="$red $z"; [ "$rc" -gt "$worst" ] && worst=$rc; fi
done
if [ "$worst" -ne 0 ]; then echo "test-unit: красные зоны:$red" >&2; exit "$worst"; fi
echo "test-unit: OK"
