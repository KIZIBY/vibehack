#!/usr/bin/env bash
# tests/harness/cases/dashboards-smoke.sh — генератор наблюдаемости pipeline-dashboard (Flight Deck).
# Контракты: структурные маркеры HTML (НЕ пиксели/вёрстка), пустой вход = валидный пустой
# дашборд, прогон спеки виден, отсутствие утечки станционных путей, несуществующий корень → exit 2.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "dashboards (pipeline flight-deck)"

PD="$ROOT/scripts/pipeline-dashboard.sh"

# ── pipeline-dashboard: пустые specs → валидный пустой; спека → прогон; без утечек путей ──
R="$TMP/pd"; mkdir -p "$R/specs"
t "flight-deck: пустые specs → exit 0" 0 bash "$PD" "$R" "$R/out.html"
t_out "честный счётчик «прогонов: 0»" 'прогонов: 0'
assert_file_contains "пустой дашборд честно пуст" "$R/out.html" 'Прогонов пока нет'
ps_ init "$R/specs/001-demo" "smoke run" >/dev/null 2>&1
t "flight-deck: одна спека → exit 0" 0 bash "$PD" "$R" "$R/out.html"
t_out "счётчик «прогонов: 1»" 'прогонов: 1'
assert_file_contains "прогон спеки виден в HTML" "$R/out.html" '001-demo'
assert_file_absent "нет утечки станционных путей (/Users|/home)" "$R/out.html" '/(Users|home)/'
t "flight-deck: несуществующий корень → exit 2" 2 bash "$PD" "$TMP/nope" "$R/o2.html"

harness_exit
