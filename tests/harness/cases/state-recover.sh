#!/usr/bin/env bash
# tests/harness/cases/state-recover.sh — read-only recovery-поверхность State V4
# (pipeline-state-recover-v4.sh): валидная пара распознаётся, но НИКОГДА не выдаётся за
# авторитет (authority=unverified до writer-реконсиляции); одинокий/битый/симлинк-audit —
# отказ exit 2; входы byte-invariant (поверхность реально read-only).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "state-recover (read-only V4 · non-authorizing)"

SUT="$ROOT/scripts/pipeline-state-recover-v4.sh"

t "неверное число аргументов → exit 2" 2 bash "$SUT" status
t "нет state.md → exit 2" 2 bash "$SUT" status "$TMP/nope"

# валидная пара — создаёт канонический writer (pipeline-state init)
S="$TMP/specs/031-demo"
ps_ init "$S" "recovery demo" >/dev/null 2>&1
cp "$S/state.md" "$TMP/state.before"
cp "$S/audit.md" "$TMP/audit.before"

t "validate-state на честной паре → 0" 0 bash "$SUT" validate-state "$S"
t_out "профиль распознан, но authority=unverified" 'profile=v4-current .*authority=unverified'
t "status на честной паре → 0" 0 bash "$SUT" status "$S"
t_out "shape-valid пара всё равно non-authorizing (нужна writer-реконсиляция)" 'writer lock/WAL reconciliation required'

inputs_untouched() { cmp -s "$TMP/state.before" "$S/state.md" && cmp -s "$TMP/audit.before" "$S/audit.md"; }
t "read-only: state.md/audit.md байт-в-байт нетронуты" 0 inputs_untouched

# битый audit → отказ (одинокий/повреждённый журнал никогда не выдаётся за usable pair)
printf 'мусорная строка вне грамматики\n' >>"$S/audit.md"
t "повреждённый audit.md → exit 2" 2 bash "$SUT" validate-state "$S"
t_out "диагностика malformed" 'malformed'
cp "$TMP/audit.before" "$S/audit.md"

# симлинк вместо audit → отказ (descriptor-валидация)
mv "$S/audit.md" "$S/audit.real"
ln -s audit.real "$S/audit.md"
t "audit.md-симлинк → exit 2" 2 bash "$SUT" validate-state "$S"
rm "$S/audit.md"; mv "$S/audit.real" "$S/audit.md"
t "после восстановления пара снова валидна → 0" 0 bash "$SUT" validate-state "$S"

harness_exit
