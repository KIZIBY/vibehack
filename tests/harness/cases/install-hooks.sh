#!/usr/bin/env bash
# tests/harness/cases/install-hooks.sh — активатор git-хуков. Инвариант: I-17.
#
# Поведенческий контракт scripts/install-git-hooks.sh: активация
# core.hooksPath=.githooks (репо-local), идемпотентность повторного запуска и
# refuse-on-conflict — чужой core.hooksPath не перетирается. Всё герметично:
# каждый ассерт против свежего `git init` под $TMP; реальный .git/config не трогаем
# и не читаем — SUT работает только со scope --local целевого репо.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "install-git-hooks (активация · идемпотентность · refuse-on-conflict)"

SUT="$ROOT/scripts/install-git-hooks.sh"

# mkrepo <dir> — минимальный герметичный репо: свой .git + стаб .githooks/pre-commit.
mkrepo() {
  local d="$1"; mkdir -p "$d/.githooks"
  git -C "$d" init -q
  printf '#!/usr/bin/env bash\nexit 0\n' > "$d/.githooks/pre-commit"
  chmod 0644 "$d/.githooks/pre-commit"
}
# run_installer <dir> — SUT с cwd=репо (он резолвит .githooks относительно корня).
run_installer() { ( cd "$1" && bash "$SUT" ); }
# hookspath/path_is — наблюдаемый инвариант: local core.hooksPath целевого репо.
hookspath() { git -C "$1" config --local --get core.hooksPath 2>/dev/null; }
path_is()   { [ "$(hookspath "$1")" = "$2" ]; }

# ── ACTIVATE: свежий репо без core.hooksPath → активация в .githooks ──
A="$TMP/fresh"; mkrepo "$A"
a_unset() { [ -z "$(hookspath "$A")" ]; }
t "activate: до запуска core.hooksPath не задан" 0 a_unset
t "activate: installer в свежем репо → exit 0" 0 run_installer "$A"
t "activate: core.hooksPath == .githooks" 0 path_is "$A" .githooks

# ── IDEMPOTENT: повторный запуск → снова exit 0, значение не меняется ──
t "idempotent: второй запуск → exit 0 (no-op config)" 0 run_installer "$A"
t "idempotent: core.hooksPath остаётся .githooks" 0 path_is "$A" .githooks

# ── REFUSE-ON-CONFLICT: чужой core.hooksPath не перетирается ──
B="$TMP/conflict"; mkrepo "$B"
git -C "$B" config --local core.hooksPath .my-hooks
t "conflict: installer при чужом core.hooksPath → exit 1" 1 run_installer "$B"
t_out "conflict: печатает отказ" "НЕ перетираю"
t "conflict: чужой core.hooksPath НЕ перетёрт (.my-hooks)" 0 path_is "$B" .my-hooks

harness_exit
