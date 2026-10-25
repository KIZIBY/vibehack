#!/usr/bin/env bash
# tests/harness/cases/eval-runner.sh — сам runner agent-eval.sh: открытие задач,
# скоринг resolved ⟺ baseline FAIL ∧ final PASS ∧ regress OK, статусы
# baseline-already-green / invalid-no-verify / not-resolved, JSON-отчёт и last-run.json,
# инвариант-гейт ВСЕГДА переопределён (AGENT_EVAL_GATE_CMD) — кейс не рекурсирует в
# run-tests.sh; каталоги задач байт-в-байт не мутируются (I-2).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "eval-runner (скоринг · статусы · gate-override · I-2)"

SUT="$ROOT/scripts/agent-eval.sh"

t "несуществующий каталог задач → exit 2" 2 env AGENT_EVAL_GATE_CMD=true bash "$SUT" "$TMP/no-tasks"
t "неизвестный флаг → exit 2" 2 env AGENT_EVAL_GATE_CMD=true bash "$SUT" --bogus
t "нецелое --k → exit 2" 2 env AGENT_EVAL_GATE_CMD=true bash "$SUT" "$TMP" --k x

# ── синтетический корпус: 4 задачи с разными исходами ──
TD="$TMP/evals"
mkdir -p "$TD/001-apply" "$TD/002-green" "$TD/003-noverify" "$TD/004-regress"
printf 'do it\n<!-- eval:apply -->\ntouch solved\n<!-- /eval:apply -->\n' >"$TD/001-apply/instruction.md"
printf '#!/bin/sh\n[ -f solved ]\n' >"$TD/001-apply/verify.sh"
printf 'noop\n<!-- eval:apply -->\ntrue\n<!-- /eval:apply -->\n' >"$TD/002-green/instruction.md"
printf '#!/bin/sh\nexit 0\n' >"$TD/002-green/verify.sh"
printf 'нет судьи\n' >"$TD/003-noverify/instruction.md"
printf 'go\n<!-- eval:apply -->\ntouch solved\n<!-- /eval:apply -->\n' >"$TD/004-regress/instruction.md"
printf '#!/bin/sh\n[ -f solved ]\n' >"$TD/004-regress/verify.sh"
printf '#!/bin/sh\nexit 1\n' >"$TD/004-regress/regress.sh"

fp_dir() { find "$1" -type f | LC_ALL=C sort | xargs -I{} sh -c 'printf "%s "; cksum <"{}"' {} | cksum; }
FP_BEFORE="$(fp_dir "$TD/001-apply") $(fp_dir "$TD/004-regress")"

t "прогон корпуса (gate=true) → exit 0" 0 \
  env AGENT_EVAL_GATE_CMD=true bash "$SUT" "$TD" --k 1 --out "$TMP/report.json"
assert_json "schema=agent-eval/1, total=3 валидных" "$TMP/report.json" \
  'data["schema"]=="agent-eval/1" and data["total"]>=3'
assert_json "001-apply resolved (baseline FAIL → apply → PASS)" "$TMP/report.json" \
  'any(t["slug"]=="001-apply" and t["resolved"] for t in data["tasks"])'
assert_json "002-green = baseline-already-green (НЕ засчитан)" "$TMP/report.json" \
  'any(t["slug"]=="002-green" and not t["resolved"] and any(r["status"]=="baseline-already-green" for r in t["runs"]) for t in data["tasks"])'
assert_json "004-regress не resolved (regress-провал ловится)" "$TMP/report.json" \
  'any(t["slug"]=="004-regress" and not t["resolved"] for t in data["tasks"])'
assert_json "инвариант-гейт отражён как pass" "$TMP/report.json" 'data["invariant_gate"]=="pass"'

t "last-run.json написан в каталог корпуса" 0 test -f "$TD/last-run.json"
assert_json "last-run.json несёт pct_resolved" "$TD/last-run.json" '"pct_resolved" in data'

fp_unchanged() { [ "$(fp_dir "$TD/001-apply") $(fp_dir "$TD/004-regress")" = "$FP_BEFORE" ]; }
t "каталоги задач байт-в-байт не мутированы (I-2)" 0 fp_unchanged

# ── ветки гейта ──
t "--no-gate → exit 0" 0 env AGENT_EVAL_GATE_CMD=true bash "$SUT" "$TD" --k 1 --no-gate --out "$TMP/r2.json"
assert_json "invariant_gate=skipped-flag" "$TMP/r2.json" 'data["invariant_gate"]=="skipped-flag"'
t "гейт=false → прогон завершён (exit 0), gate=fail честно" 0 \
  env AGENT_EVAL_GATE_CMD=false bash "$SUT" "$TD" --k 1 --out "$TMP/r3.json"
assert_json "invariant_gate=fail" "$TMP/r3.json" 'data["invariant_gate"]=="fail"'

harness_exit
