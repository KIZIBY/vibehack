#!/usr/bin/env bash
# Context budget + tokens/resolved-ticket regression guard.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "context-budget · token efficiency"

SUT="$ROOT/scripts/context-budget.pl"
LEDGER="$TMP/token-efficiency.jsonl"

cb() { /usr/bin/perl "$SUT" --ledger "$LEDGER" "$@"; }

# Context broker thresholds are deterministic and telemetry honesty is explicit.
t "budget: 29% remains NORMAL" 0 cb budget --limit 100000 --used 29000 --telemetry exact
t_out "budget: NORMAL state" '^state=NORMAL$'
t "budget: 30% creates CHECKPOINT" 0 cb budget --limit 100000 --used 30000 --telemetry exact
t_out "budget: CHECKPOINT state" '^state=CHECKPOINT$'
t "budget: 50% creates FREEZE" 0 cb budget --limit 100000 --used 50000 --telemetry estimated
t_out "budget: telemetry remains honest" '^telemetry=ESTIMATED$'
t_out "budget: FREEZE state" '^state=FREEZE$'
t "budget: 75% creates HANDOFF" 0 cb budget --limit 100000 --used 75000 --telemetry exact
t_out "budget: HANDOFF state" '^state=HANDOFF$'
t "budget: enforce blocks at HANDOFF" 4 cb budget --limit 100000 --used 75000 --telemetry exact --enforce
t "budget: malformed counters fail closed" 2 cb budget --limit 10x --used 2 --telemetry exact

parse_usage() { printf '%s\n' "$1" | cb parse-usage --runtime "$2" --model fallback; }
t "usage parser: Claude terminal usage is normalized" 0 parse_usage \
  '{"type":"result","model":"sonnet","usage":{"input_tokens":100,"cache_read_input_tokens":40,"cache_creation_input_tokens":10,"output_tokens":20}}' claude
t_out "usage parser: Claude cache counters are added once to input total" '^input=150$'
t_out "usage parser: Claude cached diagnostic is explicit" '^cached_input=50$'
t_out "usage parser: Claude output is preserved" '^output=20$'
t "usage parser: Codex terminal usage is normalized" 0 parse_usage \
  '{"type":"turn.completed","model":"gpt","usage":{"input_tokens":200,"cached_input_tokens":150,"output_tokens":30}}' codex
t_out "usage parser: Codex cached input remains a subset" '^input=200$'
t_out "usage parser: Codex cache is not double-counted" '^cached_input=150$'

t "usage parser: unsupported runtime fails closed" 2 parse_usage \
  '{"type":"result","model":"m","usage":{"input_tokens":1,"output_tokens":1}}' other-runtime

# Ревизия харнесса по умолчанию = git HEAD (короткий SHA); HARNESS_REVISION — явный override.
REV_REPO="$TMP/rev-repo"
mkdir -p "$REV_REPO" && git -C "$REV_REPO" init -q -b main \
  && git -C "$REV_REPO" -c user.email=t@example.invalid -c user.name=t -c commit.gpgsign=false \
       commit -q --allow-empty -m init
REV_HEAD="$(git -C "$REV_REPO" rev-parse --short=12 HEAD)"
default_rev() {
  (cd "$REV_REPO" && env -u HARNESS_REVISION /usr/bin/perl "$SUT" --ledger "$TMP/rev.jsonl" \
    resolve --ticket github:acme/repo#9 --resolution r9 --at 2026-08-03T10:00:00Z) \
    && grep -q "\"harness\":\"$REV_HEAD\"" "$TMP/rev.jsonl"
}
env_rev() {
  (cd "$REV_REPO" && HARNESS_REVISION=pinned-1 /usr/bin/perl "$SUT" --ledger "$TMP/rev-env.jsonl" \
    resolve --ticket github:acme/repo#9 --resolution r9 --at 2026-08-03T10:00:00Z) \
    && grep -q '"harness":"pinned-1"' "$TMP/rev-env.jsonl"
}
t "harness revision: default is git HEAD short SHA" 0 default_rev
t "harness revision: HARNESS_REVISION env overrides" 0 env_rev

record_usage() {
  cb record-usage --ticket "$1" --attempt "$2" --class "$3" --runtime "$4" --model "$5" \
    --harness "$6" --input "$7" --output "$8" --cached-input "${9:-0}" --at "${10}"
}
resolve_ticket() {
  cb resolve --ticket "$1" --resolution "$2" --harness "$3" --at "$4"
}

# Two comparable cohorts (same class/runtime/model), two tickets each.
record_usage github:acme/repo#1 a1 bug claude sonnet h1 700 300 400 2026-08-01T10:00:00Z
resolve_ticket github:acme/repo#1 r1 h1 2026-08-01T11:00:00Z
record_usage github:acme/repo#2 a2 bug claude sonnet h1 800 200 500 2026-08-01T12:00:00Z
resolve_ticket github:acme/repo#2 r2 h1 2026-08-01T13:00:00Z
record_usage github:acme/repo#3 a3 bug claude sonnet h2 1200 300 900 2026-08-02T10:00:00Z
resolve_ticket github:acme/repo#3 r3 h2 2026-08-02T11:00:00Z
record_usage github:acme/repo#4 a4 bug claude sonnet h2 1100 400 900 2026-08-02T12:00:00Z
resolve_ticket github:acme/repo#4 r4 h2 2026-08-02T13:00:00Z

t "record: ledger is created private" 0 test "$(stat -f '%Lp' "$LEDGER" 2>/dev/null || stat -c '%a' "$LEDGER")" = 600
t "record: raw ticket IDs never persist" 1 grep -q 'github:acme/repo' "$LEDGER"
before="$(wc -l < "$LEDGER" | tr -d ' ')"
t "record: identical attempt is idempotent" 0 record_usage github:acme/repo#1 a1 bug claude sonnet h1 700 300 400 2026-08-01T10:00:00Z
after="$(wc -l < "$LEDGER" | tr -d ' ')"
t "record: idempotent retry does not append" 0 test "$before" = "$after"
t "record: conflicting attempt is rejected" 3 record_usage github:acme/repo#1 a1 bug claude sonnet h1 701 300 400 2026-08-01T10:00:00Z
t "ingest: provider JSONL can append usage without shell parsing" 0 sh -c \
  "printf '%s\\n' '{\"type\":\"turn.completed\",\"model\":\"gpt\",\"usage\":{\"input_tokens\":90,\"cached_input_tokens\":50,\"output_tokens\":10}}' | /usr/bin/perl '$SUT' --ledger '$LEDGER' ingest-jsonl --ticket 'github:acme/repo#6' --attempt a6 --class docs --runtime codex --model fallback --harness h1 --at 2026-08-01T14:00:00Z"

t "report: comparable 50% increase produces RED" 0 cb report --min-sample 2 --threshold-pct 15
t_out "report: top-level RED" '^status=RED$'
t_out "report: averages are tokens per resolved ticket" '^latest_avg_tokens=1500$'
t_out "report: cached input is a subset, not double-counted" '^baseline_avg_tokens=1000$'
t_out "report: delta is explicit" '^delta_pct=50\.00$'
t_out "report: stratified red flag names stable cohort" '^group_status=RED class=bug runtime=claude model=sonnet baseline_n=2 latest_n=2 baseline_avg=1000 latest_avg=1500 delta_pct=50\.00$'
t "check: RED is a machine gate" 4 cb check --min-sample 2 --threshold-pct 15
t "report: default sample floor keeps tiny cohort in WARMUP" 0 cb report
t_out "report: WARMUP before five tickets per cohort" '^status=WARMUP$'

# A different model does not poison the same-model harness regression comparison.
record_usage github:acme/repo#5 a5 feature codex gpt h2 9000 1000 0 2026-08-02T14:00:00Z
resolve_ticket github:acme/repo#5 r5 h2 2026-08-02T15:00:00Z
t "report: mixed task/model cohort remains parseable" 0 cb report --min-sample 2 --threshold-pct 15
t_out "report: comparable cohort still owns the flag" '^red_flags=1$'

harness_exit
