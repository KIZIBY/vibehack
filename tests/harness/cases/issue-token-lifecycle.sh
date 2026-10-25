#!/usr/bin/env bash
# tests/harness/cases/issue-token-lifecycle.sh — ticket backend lifecycle → exact token ledger bridge.
# Backend по правилу харнесса (env ISSUE_BACKEND → PROJECT.md → none; неизвестное → exit 2);
# GitHub-identity только из origin; none → spec-identity для usage и typed BLOCKED для close/sync.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "issue-token-lifecycle · verified resolution"

SUT="$ROOT/scripts/issue-token-lifecycle.pl"
LEDGER="$TMP/token-efficiency.jsonl"
mkdir -p "$TMP/bin" "$TMP/state"
ln -s "$FIX/fake-issue-gh.sh" "$TMP/bin/gh"
export FAKE_ISSUE_STATE_DIR="$TMP/state"

# Репозиторий-цель с canonical GitHub-origin (сеть не нужна: gh — двойник на PATH).
REPO="$TMP/repo"
git -C "$TMP" init -q repo
git -C "$REPO" remote add origin https://github.com/acme/repo.git

life() { # [ENV=…] через env перед вызовом; cwd = REPO
  (cd "$REPO" && env -u GH_REPO PATH="$TMP/bin:/usr/bin:/bin" /usr/bin/perl "$SUT" --ledger "$LEDGER" "$@")
}
gh_life() { (cd "$REPO" && env -u GH_REPO PATH="$TMP/bin:/usr/bin:/bin" ISSUE_BACKEND=github \
  /usr/bin/perl "$SUT" --ledger "$LEDGER" "$@"); }

ingest_github() {
  printf '%s\n' '{"type":"turn.completed","model":"gpt","usage":{"input_tokens":90,"cached_input_tokens":50,"output_tokens":10}}' |
    gh_life ingest-jsonl --ticket 42 --attempt gh-a1 \
      --class bug --runtime codex --model fallback --harness h1 --at 2026-08-07T05:00:00Z
}

t "usage: raw GitHub key is namespaced and exact JSONL is ingested" 0 ingest_github
t "usage: raw ticket ID is absent from private ledger" 1 grep -q 'github:acme/repo#42' "$LEDGER"
t "github: close + terminal verify records resolution" 0 gh_life close \
  --ticket 42 --comment '[developer] shipped' --harness h1
t_out "github: verified outcome is explicit" '^metric=resolved$'
t "github: backend mutation was invoked" 0 test -s "$TMP/state/gh-close.log"
t "github: repository comes from origin" 0 grep -q -- '--repo acme/repo' "$TMP/state/gh-close.log"
t "github: retry is idempotent" 0 gh_life sync --repo acme/repo --ticket '#42' --harness h1

report() { /usr/bin/perl "$ROOT/scripts/context-budget.pl" --ledger "$LEDGER" report --min-sample 1; }
t "github: resolved ticket appears in efficiency report" 0 report
t_out "github: ticket cost includes exact attempt" '^latest_avg_tokens=100$'

FAKE_GH_STATE=OPEN t "github: non-terminal verify blocks metric" 4 gh_life close \
  --ticket 43 --comment '[developer] premature' --harness h1
FAKE_GH_VIEW_RC=5 t "github: failed verify is a typed blocker" 4 gh_life sync \
  --ticket 43 --harness h1
t_out_absent "github: backend errors never expose captured secrets" 'FAKELIFECYCLESECRET'

# ── репозиторий: только origin; --repo / GH_REPO могут лишь повторять ──
t "github: --repo другой репозиторий → exit 2" 2 gh_life sync --repo evil/other --ticket 42 --harness h1
gh_pin() { (cd "$REPO" && PATH="$TMP/bin:/usr/bin:/bin" ISSUE_BACKEND=github GH_REPO="$1" \
  /usr/bin/perl "$SUT" --ledger "$LEDGER" sync --ticket 42 --harness h1); }
t "github: GH_REPO ≠ origin → exit 2" 2 gh_pin evil/other
t "github: GH_REPO = github.com/<origin> → exit 0" 0 gh_pin github.com/acme/repo
NONGH="$TMP/nongh"
git -C "$TMP" init -q nongh
git -C "$NONGH" remote add origin https://example.invalid/acme/repo.git
nongh() { (cd "$NONGH" && PATH="$TMP/bin:/usr/bin:/bin" ISSUE_BACKEND=github \
  /usr/bin/perl "$SUT" --ledger "$LEDGER" sync --ticket 42 --harness h1); }
t "github: не-GitHub origin → exit 2 до любого вызова gh" 2 nongh

# ── правило ISSUE_BACKEND ──
t "config: unknown env backend is rejected before any mutation" 2 \
  sh -c 'cd "$1" && ISSUE_BACKEND=jira PATH="$2" /usr/bin/perl "$3" --ledger "$4" sync --ticket 1 --harness h1' \
  _ "$REPO" "$TMP/bin:/usr/bin:/bin" "$SUT" "$LEDGER"
t "config: removed tracker backend is rejected" 2 \
  sh -c 'cd "$1" && ISSUE_BACKEND=tracker PATH="$2" /usr/bin/perl "$3" --ledger "$4" sync --ticket 1 --harness h1' \
  _ "$REPO" "$TMP/bin:/usr/bin:/bin" "$SUT" "$LEDGER"
t "config: no env and no PROJECT.md → none → close is a typed BLOCKED" 4 \
  life sync --ticket 42 --harness h1
t_out "config: none blocker is typed" 'BLOCKED: issue-backend-none'
printf '# PROJECT.md\n\n```\nISSUE_BACKEND=github\n```\n' >"$REPO/PROJECT.md"
t "config: PROJECT.md selects GitHub without CLI coordinates" 0 \
  life sync --ticket 42 --harness h1
t "config: explicit --backend cannot override PROJECT.md" 2 \
  life sync --backend none --ticket 42 --harness h1
t "config: env ISSUE_BACKEND wins over PROJECT.md" 4 \
  sh -c 'cd "$1" && ISSUE_BACKEND=none PATH="$2" /usr/bin/perl "$3" --ledger "$4" sync --ticket 42 --harness h1' \
  _ "$REPO" "$TMP/bin:/usr/bin:/bin" "$SUT" "$LEDGER"
printf '# PROJECT.md\n\nISSUE_BACKEND=gihub\n' >"$REPO/PROJECT.md"
t "config: invalid PROJECT.md declaration fails closed" 2 life sync --ticket 42 --harness h1
rm -f "$REPO/PROJECT.md"

# ── none: usage по спеке ──
ingest_none() {
  printf '%s\n' '{"type":"turn.completed","model":"gpt","usage":{"input_tokens":5,"output_tokens":5}}' |
    life ingest-jsonl --ticket specs/001-demo --attempt none-a1 \
      --class feature --runtime codex --model fallback --harness h1 --at 2026-08-07T07:00:00Z
}
t "none: usage принимает spec-идентичность (specs/NNN-slug)" 0 ingest_none
t "none: сырой spec-id не попадает в ledger" 1 grep -q 'spec:001-demo' "$LEDGER"
t "none: не-spec ticket отвергается" 2 sh -c 'printf "{}\n" | (cd "$1" && env -u ISSUE_BACKEND PATH="$2" /usr/bin/perl "$3" --ledger "$4" ingest-jsonl --ticket 42 --attempt x --class bug --runtime codex --model m --harness h1)' \
  _ "$REPO" "$TMP/bin:/usr/bin:/bin" "$SUT" "$LEDGER"

harness_exit
