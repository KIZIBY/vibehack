#!/usr/bin/env bash
# tests/harness/cases/review-cross.sh — scripts/review-cross.sh <BASE_SHA>: ревью другим вендором (Codex).
# Контракты: diff = `git diff <BASE>` (коммиты после + рабочее дерево) + неотслеживаемые файлы; ревьюер
# `${HARNESS_REVIEW_CMD:-codex} exec -s read-only --skip-git-repo-check --output-schema <схема> -o <ответ> -`
# (промпт+diff на stdin) пишет JSON {"verdict":APPROVE|BLOCK,"findings":[{priority,text}]}; скрипт печатает
# «Вердикт: <V>» и строки «- <priority> <text>»; exit 0 = APPROVE, 1 = BLOCK, 2 = нет аргумента / sha не
# коммит / ревьюера нет или он упал / ответ не валидный JSON (печатает «review-cross:» и причину).
# После валидного вердикта — `telemetry.sh log review verdict= findings= bugs=(P0+P1) reviewer=codex`;
# при exit 2 событие НЕ пишется. `log review verdict=MAYBE` → exit 2. Отчёт: события review = круги
# (review.rounds_total), bugs.by_review = число P0+P1.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "review-cross (ревью другим вендором)"

export HARNESS_TELEMETRY_DIR="$TMP/tel"
RC="$ROOT/scripts/review-cross.sh"
TL="$ROOT/scripts/telemetry.sh"

# Фейковый ревьюер: режим — FAKE_MODE=approve|block|badjson|fail|capture|approve-p1.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/fake-reviewer" <<'FAKE'
#!/usr/bin/env bash
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "-o" ]; then out="$2"; shift; fi
  shift
done
input="$(cat)"
case "${FAKE_MODE:-approve}" in
  fail) exit 3 ;;
  badjson) printf 'not json {' >"$out" ;;
  block)
    if printf '%s' "$input" | grep -q 'MARKER_42'; then
      printf '%s' '{"verdict":"BLOCK","findings":[{"priority":"P1","text":"serious bug"},{"priority":"P2","text":"nit"}]}' >"$out"
    else
      printf '%s' '{"verdict":"APPROVE","findings":[]}' >"$out"
    fi ;;
  capture)
    printf '%s' "$input" >"$CAPTURE"
    printf '%s' '{"verdict":"APPROVE","findings":[]}' >"$out" ;;
  envcap)
    env >"$CAPTURE"
    printf '%s' '{"verdict":"APPROVE","findings":[]}' >"$out" ;;
  approve-p1) printf '%s' '{"verdict":"APPROVE","findings":[{"priority":"P1","text":"bug"}]}' >"$out" ;;
  *) printf '%s' '{"verdict":"APPROVE","findings":[]}' >"$out" ;;
esac
FAKE
chmod +x "$TMP/bin/fake-reviewer"

R="$TMP/repo"
mk_repo "$R"
mk_commit "$R" src/app.sh 'echo v1' "feat: base" >/dev/null
BASE="$(git -C "$R" rev-parse HEAD)"
mk_commit "$R" src/app.sh 'echo MARKER_42' "feat: change" >/dev/null

rc() { (cd "$R" && HARNESS_REVIEW_CMD="$TMP/bin/fake-reviewer" FAKE_MODE="$1" bash "$RC" "${@:2}"); }

# ── exit 2: аргументы и окружение
t "без аргумента → exit 2" 2 bash -c "cd '$R' && HARNESS_REVIEW_CMD='$TMP/bin/fake-reviewer' bash '$RC'"
t "несуществующий sha → exit 2" 2 rc approve deadbeefdeadbeefdeadbeefdeadbeefdeadbeef
t "ревьюер-команды нет → exit 2" 2 bash -c "cd '$R' && HARNESS_REVIEW_CMD='$TMP/bin/nope' bash '$RC' '$BASE'"

# ── вердикты
t "approve → exit 0" 0 rc approve "$BASE"
t_out "печатает Вердикт: APPROVE" 'Вердикт: APPROVE'
t "block → exit 1" 1 rc block "$BASE"
t_out "печатает Вердикт: BLOCK" 'Вердикт: BLOCK'
t_out "находка P1 строкой «- P1 …»" '^- P1 '

# ── сбои ревьюера
t "невалидный JSON → exit 2" 2 rc badjson "$BASE"
t "ревьюер упал (exit 3) → exit 2" 2 rc fail "$BASE"

# ── телеметрия
t "log review verdict=MAYBE → exit 2" 2 bash "$TL" log review verdict=MAYBE
t "report --json → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --json > '$TMP/r.json'"
assert_json "отчёт: 2 круга ревью (сбои не логируются)" "$TMP/r.json" 'data["review"]["rounds_total"] == 2'
assert_json "отчёт: bugs.by_review = P0+P1 = 1" "$TMP/r.json" 'data["bugs"]["by_review"] == 1'

# ── ужесточение (ревью Codex): P0/P1 ⇒ BLOCK, симлинки, лимит diff, доказательства
N="$TMP/repo2"
mk_repo "$N"
mk_commit "$N" tests/x_test.sh 'echo RED_MARKER' "test: red" >/dev/null
BASE2="$(git -C "$N" rev-parse HEAD)"
mk_commit "$N" src/a.sh 'echo changed_code_line_long_enough_for_limit' "feat: code" >/dev/null
echo SECRET_OUTSIDE >"$TMP/outside.txt"
ln -s "$TMP/outside.txt" "$N/leaklink"
echo EVIDENCE_MARKER >"$TMP/evidence.txt"
nrc() { (cd "$N" && HARNESS_TELEMETRY_DIR="$TMP/tel2" HARNESS_REVIEW_CMD="$TMP/bin/fake-reviewer" CAPTURE="$TMP/cap.txt" FAKE_MODE="$1" bash "$RC" "${@:2}"); }

t "APPROVE с находкой P1 → exit 1 (BLOCK)" 1 nrc approve-p1 "$BASE2"
t_out "APPROVE+P1 печатает Вердикт: BLOCK" 'Вердикт: BLOCK'
t "report (tel2) → exit 0" 0 bash -c "cd '$N' && HARNESS_TELEMETRY_DIR='$TMP/tel2' bash '$TL' report --since 2000-01-01T00:00:00Z --json > '$TMP/r2.json'"
assert_json "отчёт: круг APPROVE+P1 записан как BLOCK" "$TMP/r2.json" 'data["review"]["verdicts"].get("BLOCK") == 1'

t "capture + evidence-файл → exit 0" 0 nrc capture "$BASE2" "$TMP/evidence.txt"
assert_file_absent "симлинк не читается: SECRET_OUTSIDE нет в stdin" "$TMP/cap.txt" 'SECRET_OUTSIDE'
assert_file_contains "имя симлинка в stdin" "$TMP/cap.txt" 'leaklink'
assert_file_contains "stdin: файл из BASE (RED_MARKER)" "$TMP/cap.txt" 'RED_MARKER'
assert_file_contains "stdin: вывод ship-guard" "$TMP/cap.txt" 'ship-guard:'
assert_file_contains "stdin: содержимое evidence-файла" "$TMP/cap.txt" 'EVIDENCE_MARKER'

t "diff больше HARNESS_REVIEW_MAX_BYTES → exit 2" 2 bash -c "cd '$N' && HARNESS_REVIEW_MAX_BYTES=50 HARNESS_TELEMETRY_DIR='$TMP/tel2' HARNESS_REVIEW_CMD='$TMP/bin/fake-reviewer' CAPTURE='$TMP/cap.txt' FAKE_MODE=capture bash '$RC' '$BASE2'"
t_out "отказ по лимиту печатает review-cross:" 'review-cross:'

# ── второй круг ревью Codex: симлинк-доказательства, ship-guard=1 ⇒ BLOCK, сбой телеметрии не глушится молча
X="$TMP/repo3"
mk_repo "$X"
mk_commit "$X" tests/y_test.sh 'echo RED_Y' "test: red" >/dev/null
BASE3="$(git -C "$X" rev-parse HEAD)"
mk_commit "$X" src/b.sh 'echo code_b' "feat: code" >/dev/null
echo SECRET_EVIDENCE >"$TMP/secret-ev.txt"
ln -s "$TMP/secret-ev.txt" "$TMP/ev-link.txt"
xrc() { (cd "$X" && HARNESS_TELEMETRY_DIR="$TMP/tel3" HARNESS_REVIEW_CMD="$TMP/bin/fake-reviewer" CAPTURE="$TMP/cap3.txt" FAKE_MODE="$1" bash "$RC" "${@:2}"); }

rm -f "$TMP/cap3.txt"
t "evidence — симлинк → exit 2" 2 xrc capture "$BASE3" "$TMP/ev-link.txt"
t_out "отказ по симлинку печатает review-cross:" 'review-cross:'
assert_file_absent "цель симлинка не ушла ревьюеру (SECRET_EVIDENCE)" "$TMP/cap3.txt" 'SECRET_EVIDENCE'

echo 'echo tampered' >"$X/tests/y_test.sh"
t "тест из RED изменён + ревьюер APPROVE → exit 1" 1 xrc approve "$BASE3"
t_out "ship-guard=1: Вердикт: BLOCK" 'Вердикт: BLOCK'
t_out "ship-guard=1: находка со словом ship-guard" '^- P[0-2] .*ship-guard'
git -C "$X" checkout -q -- tests/y_test.sh

: >"$TMP/tel-file"
t "телеметрия не пишется → вердикт прежний, exit 0" 0 bash -c "cd '$X' && HARNESS_TELEMETRY_DIR='$TMP/tel-file' HARNESS_REVIEW_CMD='$TMP/bin/fake-reviewer' FAKE_MODE=approve bash '$RC' '$BASE3'"
t_out "сбой телеметрии: Вердикт: APPROVE сохранён" 'Вердикт: APPROVE'
t_out "сбой телеметрии: предупреждение «телеметри»" 'телеметри'

# ── третий круг ревью Codex: секреты в материале ревью и в окружении не уходят ревьюеру
S="$TMP/repo4"
mk_repo "$S"
mk_commit "$S" tests/z_test.sh 'echo RED_Z' "test: red" >/dev/null
BASE4="$(git -C "$S" rev-parse HEAD)"
mk_commit "$S" src/c.sh 'echo code_c' "feat: code" >/dev/null
TOK="ghp_""$(printf 'a1B2c3D4e5%.0s' 1 2 3 4)""abcdef"
src() { (cd "$S" && HARNESS_TELEMETRY_DIR="$TMP/tel4" HARNESS_REVIEW_CMD="$TMP/bin/fake-reviewer" CAPTURE="$TMP/cap4.txt" FAKE_MODE="$1" bash "$RC" "$BASE4"); }

printf 'echo %s\n' "$TOK" >"$S/src/leak.sh"
rm -f "$TMP/cap4.txt"
t "секрет в изменённом файле → exit 2" 2 src capture
t_out "отказ по секрету печатает review-cross:" 'review-cross:'
t_out "отказ по секрету называет причину «секрет»" 'секрет'
assert_file_absent "ревьюер не вызван: токена нет в capture" "$TMP/cap4.txt" 'ghp_'
rm -f "$S/src/leak.sh"

printf 'log %s\n' "$TOK" >"$TMP/ev-secret.txt"
rm -f "$TMP/cap4.txt"
t "секрет в evidence-файле → exit 2" 2 bash -c "cd '$S' && HARNESS_TELEMETRY_DIR='$TMP/tel4' HARNESS_REVIEW_CMD='$TMP/bin/fake-reviewer' CAPTURE='$TMP/cap4.txt' FAKE_MODE=capture bash '$RC' '$BASE4' '$TMP/ev-secret.txt'"
t_out "отказ по секрету в evidence называет «секрет»" 'секрет'
assert_file_absent "evidence: токена нет в capture" "$TMP/cap4.txt" 'ghp_'

rm -f "$TMP/cap4.txt"
t "env с секретами + чистый diff → exit 0" 0 bash -c "cd '$S' && MY_SECRET_TOKEN=leak123 SOME_API_KEY=leak456 OPENAI_API_KEY=keepme HARNESS_TELEMETRY_DIR='$TMP/tel4' HARNESS_REVIEW_CMD='$TMP/bin/fake-reviewer' CAPTURE='$TMP/cap4.txt' FAKE_MODE=envcap bash '$RC' '$BASE4'"
assert_file_absent "env ревьюера: MY_SECRET_TOKEN не передан" "$TMP/cap4.txt" 'leak123'
assert_file_absent "env ревьюера: SOME_API_KEY не передан" "$TMP/cap4.txt" 'leak456'
assert_file_contains "env ревьюера: FAKE_MODE проходит" "$TMP/cap4.txt" '^FAKE_MODE=envcap'
assert_file_contains "env ревьюера: OPENAI_API_KEY проходит" "$TMP/cap4.txt" '^OPENAI_API_KEY=keepme'

harness_exit
