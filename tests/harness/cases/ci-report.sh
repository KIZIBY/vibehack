#!/usr/bin/env bash
# tests/harness/cases/ci-report.sh — контракт стримингового репортера scripts/ci-test-report.py:
# stdout сьюта → консольный прогресс + полный лог-артефакт + JUnit report.xml (вкладка
# тестов любого CI, читающего JUnit). Это guard формата, на который опираются ВСЕ кейсы:
# `── секция ──` / `ok   ` / `FAIL  ` / детали `      | …` / маркер обрыва без `ИТОГ:`.
# Репортер сам по контракту ВСЕГДА exit 0 (реальный код сьюта берёт CI из PIPESTATUS).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "ci-report (JUnit-контракт стримингового репортера)"

REPORTER="$ROOT/scripts/ci-test-report.py"

# ── синтетический прогон: 2 секции, 3 ok + 1 FAIL с деталью, юникод/кавычки в именах ──
cat >"$TMP/suite-mixed.txt" <<'EOF'
── альфа ──
ok    первый
ok    второй "в кавычках" <и скобки>
FAIL  третий (exit 1, ожидал 0)
      | деталь-строка diag
── бета-юникод ──
ok    четвёртый
SUITE_TIME 1.00s
ИТОГ: pass=3 fail=1 cases=2 tier=full
EOF

run_reporter() { # <input> <log> <xml> <console>
  python3 "$REPORTER" "$2" "$3" <"$1" >"$4" 2>&1
}

t "репортер на смешанном прогоне → всегда exit 0" 0 \
  run_reporter "$TMP/suite-mixed.txt" "$TMP/mixed.log" "$TMP/mixed.xml" "$TMP/mixed.console"
assert_file_contains "полный лог-артефакт содержит деталь падения" "$TMP/mixed.log" 'деталь-строка diag'
assert_xml_wellformed "JUnit XML well-formed (кавычки/скобки экранированы)" "$TMP/mixed.xml"

xml_structure_ok() {
  python3 - "$TMP/mixed.xml" <<'PY'
import sys, xml.etree.ElementTree as ET
r = ET.parse(sys.argv[1]).getroot()
assert r.attrib["tests"] == "4" and r.attrib["failures"] == "1", r.attrib
suites = [s.attrib["name"] for s in r.iter("testsuite")]
assert "альфа" in suites and "бета-юникод" in suites, suites
names = [tc.attrib["name"] for tc in r.iter("testcase")]
assert any("второй" in n for n in names), names
fails = [tc for tc in r.iter("testcase") if tc.find("failure") is not None]
assert len(fails) == 1 and "третий" in fails[0].attrib["name"], fails
PY
}
t "JUnit: счётчики 4/1, обе секции (юникод), FAIL → <failure>" 0 xml_structure_ok
assert_file_contains "текст детали доехал до <failure>" "$TMP/mixed.xml" 'деталь-строка diag'
assert_file_contains "консоль показывает падение сразу (не в конце)" "$TMP/mixed.console" 'FAIL.*третий'
assert_file_absent "полный прогон (есть ИТОГ) → нет маркера обрыва" "$TMP/mixed.console" 'ОБОРВАЛСЯ'

# ── обрыв: сьют не дошёл до `ИТОГ:` (краш под set -u) → красный маркер ──
grep -v '^ИТОГ:' "$TMP/suite-mixed.txt" >"$TMP/suite-truncated.txt"
t "обрыв без ИТОГ → репортер всё равно exit 0" 0 \
  run_reporter "$TMP/suite-truncated.txt" "$TMP/trunc.log" "$TMP/trunc.xml" "$TMP/trunc.console"
assert_file_contains "консоль кричит про обрыв сьюта" "$TMP/trunc.console" 'ОБОРВАЛСЯ'
assert_file_contains "обрыв = красный гейт в консоли" "$TMP/trunc.console" 'КРАСНЫЙ'

# ── полностью зелёный прогон ──
cat >"$TMP/suite-green.txt" <<'EOF'
── гамма ──
ok    единственный
ИТОГ: pass=1 fail=0 cases=1 tier=fast
EOF
t "зелёный прогон → exit 0" 0 \
  run_reporter "$TMP/suite-green.txt" "$TMP/green.log" "$TMP/green.xml" "$TMP/green.console"
assert_file_contains "зелёный вердикт в консоли" "$TMP/green.console" 'ВСЁ ЗЕЛЁНОЕ'
assert_file_contains "зелёный JUnit: failures=0" "$TMP/green.xml" 'failures="0"'

harness_exit
