#!/usr/bin/env bash
# tests/harness/cases/receipts.sh — receipt-цепочка Stage-3/4: receipt-v1.pl полный
# позитив (start→finish→verify-finished, герметично и без git), tdd-receipt-v1.pl и
# performance-process-v1.pl — reject/tamper-матрицы exit-контракта.
# ОСОЗНАННЫЙ SCOPE (заранее одобренный fallback): полный позитив tdd-run/perf-run требует
# base-коммита с byte-identical trusted-producer скриптами + полного Stage-3/4 спека
# (минуты, не секунды) — он живёт в реальном пайплайне; здесь фиксируем exit-словарь,
# tamper-детект и грамматики, которые и защищают цепочку от подделки.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "receipts (receipt-v1 позитив · tdd/perf reject-матрицы)"

RCP="$ROOT/scripts/receipt-v1.pl"
TDD="$ROOT/scripts/tdd-receipt-v1.pl"
PERF="$ROOT/scripts/performance-process-v1.pl"

ATT="$(printf 'a%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40 41 42 43 44 45 46 47 48 49 50 51 52 53 54 55 56 57 58 59 60 61 62 63 64)"
SUBJ="${ATT//a/b}"
H40="$(printf '0%.0s' 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25 26 27 28 29 30 31 32 33 34 35 36 37 38 39 40)"

# ── receipt-v1: полный позитив (без git, чистые файлы) ──
# phys(): verify-контракт требует несимлинковых компонент пути, а macOS mktemp отдаёт
# /var/… (симлинк на /private/var) — нормализуем корень до физического
D="$(phys "$TMP")/repo"; S="specs/034-demo"
mkdir -p "$D/$S/reviews"
printf '# критикал-ревью\nвердикт: годно\n' >"$D/$S/reviews/critical-code-review.md"
audit_header() { printf '# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n'; }

start_flow() {
  local sd fd
  audit_header >"$D/$S/audit.md"   # start-detail читает журнал (generation) — он нужен ДО вызова
  sd="$(perl "$RCP" start-detail "$D" "$S" critical-code "$ATT" rev.agent "$SUBJ")" || return 1
  printf '| 2026-07-30T00:00:00Z | review-start:critical-code | %s |\n' "$sd" >>"$D/$S/audit.md"
  fd="$(perl "$RCP" finish-detail "$D" "$S" critical-code "$ATT" "$S/reviews/critical-code-review.md")" || return 1
  printf '| 2026-07-30T00:00:01Z | review-finish:critical-code | %s |\n' "$fd" >>"$D/$S/audit.md"
}
t "receipt-v1: start-detail + finish-detail строят каноничный журнал" 0 start_flow
t "receipt-v1: verify-finished на честной цепочке → 0" 0 \
  perl "$RCP" verify-finished "$D" "$S" critical-code "$ATT"
t_out "verify-finished печатает sha256 артефакта и auditsha256 (пин снапшота)" 'auditsha256='

# tamper артефакта: один байт → digest mismatch, exit 2
cp "$D/$S/reviews/critical-code-review.md" "$TMP/artifact.orig"
printf 'X' >>"$D/$S/reviews/critical-code-review.md"
t "receipt-v1: порча байта артефакта → tamper-детект (exit 2)" 2 \
  perl "$RCP" verify-finished "$D" "$S" critical-code "$ATT"
t_out "диагностика: digest mismatch" 'digest mismatch'
cp "$TMP/artifact.orig" "$D/$S/reviews/critical-code-review.md"
t "receipt-v1: после восстановления артефакта снова 0" 0 \
  perl "$RCP" verify-finished "$D" "$S" critical-code "$ATT"

# tamper журнала → не каноничен, exit 2
printf 'мусорная строка\n' >>"$D/$S/audit.md"
t "receipt-v1: порча audit.md → exit 2 (журнал не каноничен)" 2 \
  perl "$RCP" verify-finished "$D" "$S" critical-code "$ATT"

t "receipt-v1: без аргументов → usage (exit 2)" 2 perl "$RCP"
t "receipt-v1: невалидная роль → exit 2" 2 \
  perl "$RCP" start-detail "$D" "$S" wrong-role "$ATT" rev.agent "$SUBJ"

# ── tdd-receipt-v1: exit-словарь и tamper (позитив цепочки — вне scope, см. шапку) ──
G="$TMP/gitrepo"; mk_repo "$G"; mk_commit "$G" f.txt x
mkdir -p "$G/specs/034-demo"
audit_header >"$G/specs/034-demo/audit.md"
t "tdd: без команды → usage (exit 2)" 2 perl "$TDD"
t "tdd: run с битым argc → exit 2" 2 perl "$TDD" run x
t "tdd: verify-chain без implementation-start → exit 2 (нет фантомных цепочек)" 2 \
  perl "$TDD" verify-chain "$G" specs/034-demo "$ATT"
t_out "диагностика: implementation-start absent" 'implementation-start absent'
printf 'мусор\n' >>"$G/specs/034-demo/audit.md"
t "tdd: verify-chain на битом журнале → exit 2" 2 \
  perl "$TDD" verify-chain "$G" specs/034-demo "$ATT"
t_out "диагностика: row is not canonical" 'not canonical'
t "tdd: verify-producer с битой грамматикой attempt → exit 2" 2 \
  perl "$TDD" verify-producer "$G" specs/034-demo "$H40" not-hex

# ── performance-process-v1: exit-словарь (позитив требует Stage-4 checkpoint — вне scope) ──
audit_header >"$G/specs/034-demo/audit.md"
t "perf: без аргументов → usage (exit 2)" 2 perl "$PERF"
t "perf: run с битым argc → exit 2" 2 perl "$PERF" run
t "perf: run при HEAD≠C → exit 2 (кандидат обязан быть exact checkpoint)" 2 \
  perl "$PERF" run "$G" specs/034-demo "$ATT" specs/034-demo/reviews/performance-review.md "$H40"
t_out "диагностика: must equal exact HEAD checkpoint" 'exact HEAD checkpoint'
t "perf: битая грамматика attempt → exit 2" 2 \
  perl "$PERF" run "$G" specs/034-demo not-hex specs/034-demo/reviews/performance-review.md "$H40"

harness_exit
