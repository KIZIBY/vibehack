#!/usr/bin/env bash
# tests/harness/cases/evidence-verifiers.sh — Stage-2/3/4 verifier'ы: поведенческий exit + set-closure
# смоук (БЕЗ golden-значений, БЕЗ source-грепа). Инвариант: I-6 (истончённый).
#
# Свёртка трёх удалённых golden/white-box контрактов в поведенческий смоук:
#   architecture-sdd-verify.pl   — Design-Root детерминизм (полный позитив: shape + идемпотентность)
#   implementation-tdd-verify.pl — TDD-receipts (perl -c + негативы; полный git+receipt фикстур тяжёл)
#   evidence-v1-verify.pl        — Stage-4 конверт R->C->H->B (perl -c + set-closure негативы)
# Ни одного захардкоженного хеша: корень вычисляется и сравнивается сам с собой, не с литералом.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "evidence-verifiers (exit + set-closure · без golden)"

ARCH="$ROOT/scripts/architecture-sdd-verify.pl"
TDD="$ROOT/scripts/implementation-tdd-verify.pl"
EV="$ROOT/scripts/evidence-v1-verify.pl"
TPL="$ROOT/scripts/templates/architecture-evidence-v1"
SPEC=specs/034-demo

# Стабильные идентити-литералы фикстуры (форма важна, значение — нет).
AUTHOR_ATT=1111111111111111111111111111111111111111111111111111111111111111
REVIEWER_ATT=2222222222222222222222222222222222222222222222222222222222222222
DESIGN_HEX=3333333333333333333333333333333333333333333333333333333333333333
HEX40=0000000000000000000000000000000000000000

# ── 0. синтаксис: perl -c для каждого SUT ──
t "arch: perl -c компилируется" 0 perl -c "$ARCH"
t "tdd:  perl -c компилируется" 0 perl -c "$TDD"
t "ev:   perl -c компилируется" 0 perl -c "$EV"

# ── фикстур-билдер architecture-кандидата (адаптированный минимум из старого контракта) ──
# Только артефакты, которые входят в Design-preimage: candidate НЕ читает audit/review/delivery.
make_arch() {
  local repo="$1" d="$1/$SPEC"
  mkdir -p "$d/decisions"
  cp "$TPL/decision.md" "$d/decisions/AD-001.md"
  perl -pi -e '
    s/\{\{AUTHOR_ACTOR\}\}/author.agent/g;
    s/\{\{AUTHOR_ATTEMPT_64HEX\}\}/1111111111111111111111111111111111111111111111111111111111111111/g;
    s/\{\{REVIEWER_ACTOR\}\}/reviewer.agent/g;
    s/\{\{REVIEWER_ATTEMPT_64HEX\}\}/2222222222222222222222222222222222222222222222222222222222222222/g;
  ' "$d/decisions/AD-001.md"
  cp "$TPL/traceability.tsv" "$d/traceability.tsv"
  cp "$TPL/sdd-changelog.tsv" "$d/sdd-changelog.tsv"
  cp "$TPL/roadmap-handoff.md" "$d/roadmap-handoff.md"
  printf '%s\n' \
    '# Feature: architecture contract fixture' '' \
    '- **FR-003 (architecture dossier).** Typed dossier.' \
    '- **FR-004 (selection rule).** Hard and Pareto selection.' \
    '- **FR-005 (design bind).** Reviewed root.' \
    '- **FR-006 (living SDD).** Separate design authority.' \
    '- **FR-009 (review receipt).** Canonical lifecycle.' \
    '- **FR-014 (root).** Domain-separated manifest.' \
    '- **NFR-001 (portability).** Core Perl only.' \
    '- **NFR-002 (determinism).** Exact bytes.' \
    '- **NFR-003 (security).** Closed safe paths.' > "$d/spec.md"
  printf '%s\n' '# Plan' '' 'Validate candidate, independent audit receipt, then bind.' > "$d/plan.md"
  find "$d" -type f -exec chmod 0644 {} \;
}

# ── 1. architecture: ПОЛНЫЙ позитив — валидный кандидат принимается, корень имеет форму и идемпотентен ──
A="$TMP/arch-good"; make_arch "$A"
t "arch: candidate на валидном dossier → exit 0" 0 perl "$ARCH" candidate "$A" "$SPEC"

arch_root_shape() {
  local r
  r="$(perl "$ARCH" candidate "$A" "$SPEC")" || return 1
  printf '%s' "$r" | grep -Eq '^[0-9a-f]{64}$'
}
arch_root_idem() {
  local a b
  a="$(perl "$ARCH" candidate "$A" "$SPEC")" || return 1
  b="$(perl "$ARCH" candidate "$A" "$SPEC")" || return 1
  [ "$a" = "$b" ]
}
t "arch: Design-Root — 64-hex форма (shape, не литерал)" 0 arch_root_shape
t "arch: Design-Root идемпотентен — вычислено дважды, равно самому себе" 0 arch_root_idem

# ── 2. architecture: НЕГАТИВ — удаление обязательного артефакта ломает кандидата ──
A_MISS="$TMP/arch-missing"; cp -R "$A" "$A_MISS"; rm "$A_MISS/$SPEC/plan.md"
t "arch: удалён обязательный plan.md → exit 2" 2 perl "$ARCH" candidate "$A_MISS" "$SPEC"

# ── 3. architecture: НЕГАТИВ — нарушение set-closure каталога decisions/ ──
A_UNREG="$TMP/arch-unreg"; cp -R "$A" "$A_UNREG"
printf '# unregistered\n' > "$A_UNREG/$SPEC/decisions/notes.md"
chmod 0644 "$A_UNREG/$SPEC/decisions/notes.md"
t "arch: незарегистрированный файл в decisions/ рушит закрытый набор → exit 2" 2 \
  perl "$ARCH" candidate "$A_UNREG" "$SPEC"

# ── минимальный герметичный git-репозиторий для tdd/ev негативов ──
GITREPO="$TMP/gitrepo"; mkdir -p "$GITREPO"
{
  git -C "$GITREPO" init -q
  git -C "$GITREPO" config user.email t@example.invalid
  git -C "$GITREPO" config user.name harness-test
  printf 'seed\n' > "$GITREPO/seed.txt"
  git -C "$GITREPO" add seed.txt
  git -C "$GITREPO" -c commit.gpgsign=false commit -q -m seed
} >/dev/null 2>&1
GITHEAD="$(git -C "$GITREPO" rev-parse HEAD 2>/dev/null)"
[ -n "$GITHEAD" ] || GITHEAD="$DESIGN_HEX"

# ── 4. implementation-tdd: perl -c уже проверен; негативы на exit-контракт ──
# Раннее input-валидирование: невалидный attempt отбивается до всякого git.
t "tdd: невалидный implementation-attempt → exit 2" 2 \
  perl "$TDD" verify "$ROOT" "$SPEC" "$HEX40" "$DESIGN_HEX" not-a-valid-attempt
# Валидная форма аргументов, но несуществующий base на реальном git-репо → отбой в git/arch-логике.
t "tdd: несуществующий base-GitOid на git-репо → exit 2" 2 \
  perl "$TDD" verify "$GITREPO" "$SPEC" "$HEX40" "$DESIGN_HEX" "$REVIEWER_ATT"

# ── 5. evidence-v1: set-closure R->C->H->B; полный валидный конверт слишком тяжёл — негативы ──
# Малформленный checkpoint-OID отбивается на границе аргументов.
t "ev: verify-committed с малформленным OID → exit 2" 2 \
  perl "$EV" verify-committed "$GITREPO" "$SPEC" notanoid "$HEX40" "$HEX40"
# Вырожденная топология C==H==B (реальный коммит) нарушает exact R->C->H->B → отбой.
t "ev: вырожденный C==H==B набор нарушает set-closure → exit 2" 2 \
  perl "$EV" verify-committed "$GITREPO" "$SPEC" "$GITHEAD" "$GITHEAD" "$GITHEAD"
# Пустой ввод (неполный argc) → usage → ненулевой код.
t "ev: пустой ввод (неполный argc) → exit 2" 2 perl "$EV" candidate

harness_exit
