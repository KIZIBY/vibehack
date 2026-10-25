#!/usr/bin/env bash
# tests/harness/cases/ship-worktree.sh — scripts/ship-worktree.sh new <slug> | list (2–4 исполнителя).
# Контракты: new создаёт ветку ship/<slug> и worktree <родитель>/<имя-checkout>-<slug>, печатает путь
# последней строкой, exit 0; лимит SHIP_MAX_WORKTREES (по умолчанию 4) дополнительных worktree →
# exit 1 + «ship-worktree:» и «лимит», ничего не создаётся; плохой slug/нет аргументов/неизвестная
# подкоманда → exit 2; повторный slug → exit 1; list печатает worktree и счётчик N/лимит.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "ship-worktree (2–4 исполнителя)"

SW="$ROOT/scripts/ship-worktree.sh"
MAIN="$TMP/w/main"
mk_repo "$MAIN"
mk_commit "$MAIN" src/app.sh 'echo v1' "feat: base" >/dev/null
MAIN="$(phys "$MAIN")"

wt() { (cd "$MAIN" && SHIP_MAX_WORKTREES=2 bash "$SW" "$@"); }
wt_def() { (cd "$MAIN" && env -u SHIP_MAX_WORKTREES bash "$SW" "$@"); }
wt_sub() { mkdir -p "$MAIN/src/deep"; (cd "$MAIN/src/deep" && env -u SHIP_MAX_WORKTREES bash "$SW" "$@"); }
last_is() { [ "$ALPHA_LAST" = "$1" ]; }

# ── exit 2: аргументы
t "без аргументов → exit 2" 2 wt
t "неизвестная подкоманда → exit 2" 2 wt frobnicate
t "slug с недопустимым символом → exit 2" 2 wt new 'a/b'

# ── успешное создание
t "new alpha → exit 0" 0 wt new alpha
ALPHA_LAST="$(tail -n 1 "$TMP/last.out")"
t "последняя строка — путь worktree" 0 last_is "$(phys "$TMP/w")/main-alpha"
t "каталог worktree существует" 0 test -d "$TMP/w/main-alpha"
assert_branch "в worktree текущая ветка ship/alpha" "$TMP/w/main-alpha" "ship/alpha"
t "ветка ship/alpha есть в основном репо" 0 git -C "$MAIN" show-ref --verify --quiet refs/heads/ship/alpha

# ── повтор
t "повторный new alpha → exit 1" 1 wt new alpha
t_out "повтор: ship-worktree:" 'ship-worktree:'

# ── лимит (SHIP_MAX_WORKTREES=2)
t "new beta → exit 0" 0 wt new beta
t "new gamma сверх лимита → exit 1" 1 wt new gamma
t_out "отказ: ship-worktree:" 'ship-worktree:'
t_out "отказ: слово «лимит»" 'лимит'
assert_path_absent "при отказе каталог не создан" "$TMP/w/main-gamma"
t "при отказе ветка ship/gamma не создана" 1 git -C "$MAIN" show-ref --verify --quiet refs/heads/ship/gamma

# ── list
t "list → exit 0" 0 wt list
t_out "list: счётчик 2/2" '2/2'
t_out "list: строка alpha" 'alpha'
t_out "list: строка beta" 'beta'
t "list с лимитом по умолчанию → exit 0" 0 wt_def list
t_out "list: счётчик 2/4" '2/4'

# ── вызов из подкаталога репо
t "new delta из подкаталога → exit 0" 0 wt_sub new delta
t "worktree delta создан рядом с основным" 0 test -d "$TMP/w/main-delta"

# ── потолок лимита (4) и лок от гонки — отдельный основной репо
M2="$TMP/w2/main"
mk_repo "$M2"
mk_commit "$M2" src/app.sh 'echo v1' "feat: base" >/dev/null
M2="$(phys "$M2")"
w2() { (cd "$M2" && env -u SHIP_MAX_WORKTREES bash "$SW" "$@"); }
w2_max() { local m="$1"; shift; (cd "$M2" && SHIP_MAX_WORKTREES="$m" bash "$SW" "$@"); }
LOCK="$(git -C "$M2" rev-parse --path-format=absolute --git-common-dir)/ship-worktree.lock"

t "SHIP_MAX_WORKTREES=8 (выше потолка 4) → exit 2" 2 w2_max 8 new cap
t_out "потолок: ship-worktree:" 'ship-worktree:'
t_out "потолок: упомянуто число 4" '(^|[^0-9A-Za-z])4([^0-9A-Za-z]|$)'
assert_path_absent "потолок: каталог не создан" "$TMP/w2/main-cap"
t "потолок: ветка ship/cap не создана" 1 git -C "$M2" show-ref --verify --quiet refs/heads/ship/cap
t "SHIP_MAX_WORKTREES=4 (в пределах) → new ok, exit 0" 0 w2_max 4 new within

mkdir "$LOCK"
t "лок занят → new exit 1" 1 w2 new locked
t_out "лок занят: ship-worktree:" 'ship-worktree:'
t_out "лок занят: слово «занят»" 'занят'
assert_path_absent "лок занят: каталог не создан" "$TMP/w2/main-locked"
t "лок занят: ветка ship/locked не создана" 1 git -C "$M2" show-ref --verify --quiet refs/heads/ship/locked
t "лок занят: list → exit 0" 0 w2 list
rmdir "$LOCK"
t "лок снят → new exit 0" 0 w2 new unlocked
assert_path_absent "после успешного new лока не остаётся" "$LOCK"

harness_exit
