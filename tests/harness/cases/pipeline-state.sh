#!/usr/bin/env bash
# tests/harness/cases/pipeline-state.sh — State-машина /pipeline: гейты, атомарность, идемпотентность,
# миграция/recovery. Инварианты: I-2, I-6.
#
# Ядро (оставлено): канонический gate MUST-FLAG:0 ∧ NEEDS-INFO:0 ∧ owner-approval как
# механический предикат перед stage-3; die→exit2 при byte-invariance state/audit; идемпотентность
# ack/resume (I-2); legacy-v1 → V4 миграция и unified per-SPEC writer-lock recovery.
# Вырезано (breadth): полный design/implementation/evidence authority (git+templates+receipts),
# TOCTOU/ABA/requeue/birth-polling матрицы, C→H→B publish-graph — отдельные контракты.
#
# SUT-вызовы дорогие (perl-supervisor + WAL на каждую мутацию), поэтому spec-фикстуры
# переиспользуются: reject-кейсы byte-invariant, значит не мешают последующим ассертам.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "pipeline-state (гейты · атомарность · идемпотентность · миграция)"

READER="$ROOT/scripts/lib/pipeline-state-reader-v4.pl"

# Одна изолированная git-worktree на case; strict-команды (check/approve) требуют
# repo-relative specs/NNN-slug из корня, поэтому дальше работаем из cwd=$REPO.
REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email harness@example.invalid
git -C "$REPO" config user.name  harness
cd "$REPO" || { no "cd в тестовый repo не удался"; harness_exit; exit; }
RP="$(pwd -P)"

adv1() { # <rel>: свежий spec → stage-1 running
  local rel="$1"; mkdir -p "$REPO/$rel"
  ps_ init "$rel" fixture feature         >/dev/null 2>&1
  ps_ stage-start "$rel" stage-1-creative >/dev/null 2>&1
}
adv2() { # <rel>: свежий spec → stage-2 running
  local rel="$1"; adv1 "$rel"
  ps_ stage-done  "$rel" stage-1-creative >/dev/null 2>&1
  ps_ stage-start "$rel" stage-2-audit    >/dev/null 2>&1
}
seed_audit() { printf '%s\n' \
  '# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)' \
  '' '| ts (UTC) | event | detail |' '|---|---|---|' > "$1"; }

# Общие фикстуры: G — stage-2 running (gate + units-atomicity); S1 — stage-1 running
# (color/reason-atomicity + resume-idempotence).
G="specs/010-gate";  adv2 "$G"
S1="specs/011-s1";   adv1 "$S1"

# ── ATOMICITY: невалидный вход → die(exit2) + state/audit байт-в-байт + нет .state.md.* temp ──
t "atomic: units-set пустой список → exit2 без мутации" 0 \
  ps_reject_unchanged "$REPO/$G" units-set "$G" ""
t "atomic: невалидный цвет confidence → exit2 без мутации" 0 \
  ps_reject_unchanged "$REPO/$S1" stage-done "$S1" stage-1-creative purple x
t "atomic: yellow без причины → exit2 без мутации" 0 \
  ps_reject_unchanged "$REPO/$S1" stage-done "$S1" stage-1-creative yellow

# ── GATE: канонический предикат MUST-FLAG:0 ∧ NEEDS-INFO:0 ∧ approval перед stage-3 ──
# check перечисляет ВСЕ блокеры; approve падает сперва на canonical gate, затем на Design-Root.
# «gate открыт» доказываем исчезновением блокера 'canonical gate', не подделывая полный вход.
t "gate: свежая stage-2 — check stage-3 BLOCKED" 1 ps_ check "$G" stage-3-dev
t_out "gate: canonical gate среди блокеров" 'canonical gate'
t_out "gate: blocked-when-not-approved (owner-гейт среди блокеров)" 'user-approval != approved'
t "gate: MUST-FLAG 2 записан" 0 ps_ gate "$G" "MUST-FLAG: 2 · SHOULD-FLAG: 1 · NEEDS-INFO: 0"
t "gate: approve при MUST-FLAG>0 → FATAL" 2 ps_ approve "$G" approved
t_out "gate: первопричина отказа — canonical gate" 'canonical gate'
t "gate: NEEDS-INFO 1 записан" 0 ps_ gate "$G" "MUST-FLAG: 0 · SHOULD-FLAG: 0 · NEEDS-INFO: 1"
t "gate: approve при NEEDS-INFO>0 → FATAL" 2 ps_ approve "$G" approved
t "gate: MUST-FLAG 0 · NEEDS-INFO 0 записан" 0 \
  ps_ gate "$G" "MUST-FLAG: 0 · SHOULD-FLAG: 1 · NEEDS-INFO: 0"
t "gate: при 0/0 canonical gate пройден (упор уже на Design-Root)" 2 ps_ approve "$G" approved
t_out "gate: остаточная причина — Design-Root authority" 'Design-Root'
t_out_absent "gate: allowed — canonical gate больше НЕ блокер (гейт открыт)" 'canonical gate'

# ── IDEMPOTENCE (I-2): повторный stage-start (resume) = NO-OP без дублей ──
# S1 всё ещё pristine stage-1 running: reject-кейсы выше byte-invariant.
cp "$REPO/$S1/state.md" "$TMP/s1.state"; cp "$REPO/$S1/audit.md" "$TMP/s1.audit"
t "resume: повторный stage-start = no-op (exit0)" 0 ps_ stage-start "$S1" stage-1-creative
s1_noop() { cmp -s "$TMP/s1.state" "$REPO/$S1/state.md" && cmp -s "$TMP/s1.audit" "$REPO/$S1/audit.md" \
  && [ "$(grep -c 'stage-1-creative:start' "$REPO/$S1/audit.md")" -eq 1 ]; }
t "resume: state/audit неизменны, start-событие не задублировано" 0 s1_noop

# ── IDEMPOTENCE (I-2): повторный ack снятого non-green гейта = NO-OP ──
IA="specs/012-ack"; adv1 "$IA"
ps_ stage-done "$IA" stage-1-creative yellow "тест мигал 1/3" >/dev/null 2>&1
t "ack: снятие non-green confidence-гейта (exit0)" 0 ps_ ack "$IA" stage-1-creative owner
cp "$REPO/$IA/state.md" "$TMP/ia.state"; cp "$REPO/$IA/audit.md" "$TMP/ia.audit"
t "ack: повторный ack = no-op (exit0)" 0 ps_ ack "$IA" stage-1-creative owner
t_out "ack: повтор назван no-op" 'no-op'
ia_noop() { cmp -s "$TMP/ia.state" "$REPO/$IA/state.md" && cmp -s "$TMP/ia.audit" "$REPO/$IA/audit.md" \
  && [ "$(grep -c ' · ack: ' "$REPO/$IA/state.md")" -eq 1 ]; }
t "ack: state/audit неизменны, ровно один ack-маркер" 0 ia_noop

# ── MIGRATION (I-2): legacy-v1 fixture inspect-only, mutation fail-closed, explicit V4 миграция ──
ML="specs/060-legacy"; mkdir -p "$REPO/$ML"
cp "$FIX/pipeline-state-legacy-v1.md" "$REPO/$ML/state.md"
seed_audit "$REPO/$ML/audit.md"
mig_reads_legacy() { [ "$(perl "$READER" "$REPO/$ML/state.md")" = legacy ]; }
mig_reads_v4()     { [ "$(perl "$READER" "$REPO/$ML/state.md")" = v4-current ]; }
t "migration: reader классифицирует fixture как legacy" 0 mig_reads_legacy
t "migration: legacy state inspectable (validate-state OK)" 0 ps_ validate-state "$ML"
t "migration: mutation до migrate → fail-closed exit2" 2 ps_ stage-start "$ML" stage-1-creative
t_out "migration: typed migration-required" 'migration-required'
t "migration: explicit migrate-v4 → OK" 0 ps_ migrate-v4 "$ML"
t "migration: после migrate reader = v4-current" 0 mig_reads_v4

# ── RECOVERY (unified per-SPEC writer lock): dead-owner residue реклеймится, live-owner блокирует ──
LK="specs/070-lock"; mkdir -p "$REPO/$LK"
ps_ init "$LK" fixture feature >/dev/null 2>&1
LR="$REPO/.git/agent-harness-pipeline-locks"; mkdir -p "$LR"; chmod 0700 "$LR"
lock_key() { printf '%s\0%s' 'pipeline-state-pair-v1' "git:$RP:$1" \
  | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)'; }
LOCKDIR="$LR/$(lock_key "$LK").lock"
mk_owner() { # <pid> <nonce-int>: конструирует lock-residue с mode-корректным owner
  mkdir -p "$LOCKDIR"; chmod 0700 "$LOCKDIR"
  printf 'pid=%s\nstarted=%s\nbirth=unavailable\nnonce=%064d\n' "$1" "$(date +%s)" "$2" > "$LOCKDIR/owner"
  chmod 0600 "$LOCKDIR/owner"
}
mk_owner 999999 1
t "lock: dead-owner residue реклеймится (event OK)" 0 ps_ event "$LK" tool:reclaimed
lk_reclaimed() { [ "$(grep -c 'tool:reclaimed' "$REPO/$LK/audit.md")" -eq 1 ] && [ ! -e "$LOCKDIR" ]; }
t "lock: reclaim — одно событие, stale lock снят" 0 lk_reclaimed
mk_owner "$$" 2
cp "$REPO/$LK/audit.md" "$TMP/lk.audit"
t "lock: живой owner блокирует mutation → exit2" 2 ps_ event "$LK" tool:must-not-appear
lk_blocked() { ! grep -q 'tool:must-not-appear' "$REPO/$LK/audit.md" \
  && [ -d "$LOCKDIR" ] && cmp -s "$TMP/lk.audit" "$REPO/$LK/audit.md"; }
t "lock: live-owner — событие не записано, lock цел, audit неизменен" 0 lk_blocked

harness_exit
