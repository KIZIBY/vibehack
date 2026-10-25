#!/usr/bin/env bash
# tests/harness/cases/localize-gitdir.sh — локализованный gitdir + full-OID guard. Инвариант: I-2.
#
# Поведенческий контракт двух SUT (die→exit1):
#   scripts/agent-localize-gitdir.sh — строит атомарный staged localized gitdir; equal/local-ahead
#     переиспользует; stale/invalid → self-ignored quarantine + refresh; diverged → block.
#   scripts/agent-git.sh — тонкая обёртка git, которая отказывается работать, пока localized gitdir
#     не пройдёт integrity (реальный каталог, не-symlink HEAD, совпадающий common-dir) и OID не будут
#     полными 40/64-hex.
#
# ~10 near-identical localize-фикстур старого монолита (invalid sentinel, symlink-impostor,
# HEAD-symlink, managed-leaf symlink ×2, concurrent torn-copy, rename source/target race,
# normal-repo invalid) СВЁРНУТЫ здесь в один представительный invalid→quarantine кейс + agent-git
# integrity-семейство (валиден / symlink-HEAD / короткий OID / symlink-корень). Publisher/preflight/
# poison-namespace фикстуры сюда НЕ портированы — это контракт другого SUT.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "localize-gitdir · agent-git (integrity · full-OID)"

# ── герметичные фикстуры ──────────────────────────────────────────────────────────────────────
# new_worktree <label> → detached linked worktree + один base-commit; глобали MAIN/WT/ORIG/LOCAL.
# ORIG (registered worktree gitdir) делаем read-only, чтобы форсировать реальную локализацию:
# writable registered gitdir → early-exit "no localization needed" без построения .codex-worktree-git.
new_worktree() {
  MAIN="$TMP/$1-main"; WT="$TMP/$1-wt"
  mkdir -p "$MAIN"; git -C "$MAIN" init -q
  git -C "$MAIN" config user.email t@t; git -C "$MAIN" config user.name t
  printf 'base\n' > "$MAIN/base.txt"; git -C "$MAIN" add base.txt
  git -C "$MAIN" -c core.hooksPath=/dev/null -c commit.gpgsign=false commit -qm base
  git -C "$MAIN" worktree add -q --detach "$WT" HEAD
  ORIG="$(git -C "$WT" rev-parse --absolute-git-dir)"
  LOCAL="$WT/.codex-worktree-git"
}
localize()     { ( cd "$WT" && bash "$ROOT/scripts/agent-localize-gitdir.sh" ); }
agit()         { ( cd "$WT" && bash "$ROOT/scripts/agent-git.sh" "$@" ); }
local_head()   { GIT_DIR="$LOCAL" GIT_WORK_TREE="$WT" git rev-parse HEAD; }
local_resolves() { GIT_DIR="$LOCAL" GIT_WORK_TREE="$WT" git rev-parse --verify 'HEAD^{commit}' >/dev/null 2>&1; }
local_commit() {
  GIT_DIR="$LOCAL" GIT_WORK_TREE="$WT" git \
    -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    commit --allow-empty -qm "$1"
}
registered_commit() {
  git -C "$WT" -c user.email=t@t -c user.name=t -c core.hooksPath=/dev/null -c commit.gpgsign=false \
    commit --allow-empty -qm "$1"
}

# ── LIFECYCLE: clean → equal → local-ahead → diverged на одном worktree ─────────────────────────
new_worktree life; chmod 0555 "$ORIG"

# 1. clean: локализация read-only detached worktree строит наблюдаемый валидный gitdir.
clean_artifact() { [ -d "$LOCAL" ] && [ ! -L "$LOCAL" ] && [ -f "$LOCAL/HEAD" ] && [ ! -L "$LOCAL/HEAD" ]; }
t "clean: localize read-only linked worktree → exit 0" 0 localize
t "clean: построен реальный каталог с regular HEAD (не symlink)" 0 clean_artifact
t "clean: HEAD localized gitdir резолвится в коммит" 0 local_resolves

# 2. equal: повторный запуск переиспользует существующий gitdir идемпотентно.
EQ0="$(local_head)"
t "equal: повторная localize переиспользует gitdir → exit 0" 0 localize
eq_idem() { [ "$(local_head)" = "$EQ0" ]; }
t "equal: переиспользование идемпотентно (local HEAD не сдвинут)" 0 eq_idem

# 3. local-ahead: localized HEAD ушёл вперёд registered → тоже reuse, уникальный коммит сохранён.
local_commit ahead-1; AH="$(local_head)"
t "local-ahead: localize переиспользует ушедший вперёд gitdir → exit 0" 0 localize
ahead_kept() { [ "$(local_head)" = "$AH" ]; }
t "local-ahead: уникальный localized HEAD сохранён" 0 ahead_kept

# 4. diverged: registered продвигается в sibling C0 → истории разошлись → оба SUT блокируют.
chmod 0755 "$ORIG"; registered_commit reg-sibling
t "diverged: localize БЛОКИРУЕТ разошедшийся localized HEAD (die → exit 1)" 1 localize
div_intact() { [ -d "$LOCAL" ] && [ ! -L "$LOCAL" ] && [ "$(local_head)" = "$AH" ]; }
t "diverged: существующий local gitdir сохранён (не удалён/не quarantine)" 0 div_intact

# ── INVALID → QUARANTINE + REFRESH (один представительный кейс за все tamper-варианты) ──────────
new_worktree inval; chmod 0555 "$ORIG"
mkdir -p "$LOCAL"; printf 'do-not-delete\n' > "$LOCAL/sentinel"   # партиал без HEAD = invalid
t "invalid: localize quarantine'ит битый gitdir и строит fresh → exit 0" 0 localize
inv_preserved() {
  local q; q="$(find "$WT/.codex-gitdir-quarantine" -mindepth 1 -maxdepth 1 -type d -name 'local.*' 2>/dev/null | head -1)"
  [ -n "$q" ] && grep -qx do-not-delete "$q/sentinel"
}
inv_fresh() { [ -d "$LOCAL" ] && [ ! -L "$LOCAL" ] && [ -f "$LOCAL/HEAD" ] && local_resolves; }
t "invalid: исходный payload сохранён в quarantine" 0 inv_preserved
t "invalid: refreshed gitdir валиден и используется (битый больше не в ходу)" 0 inv_fresh
chmod 0755 "$ORIG"

# ── AGENT-GIT INTEGRITY: принимает валидный, отказывает на любом подделанном localized gitdir ────
new_worktree agit; chmod 0555 "$ORIG"; localize >/dev/null 2>&1; chmod 0755 "$ORIG"
t "agent-git: принимает валидный localized gitdir → exit 0" 0 agit status

# HEAD подменён symlink'ом → integrity refuse (non-symlink HEAD).
mv "$LOCAL/HEAD" "$LOCAL/HEAD.real"; ln -s HEAD.real "$LOCAL/HEAD"
t "agent-git: отказ при HEAD-symlink → exit 1" 1 agit status
rm -f "$LOCAL/HEAD"; mv "$LOCAL/HEAD.real" "$LOCAL/HEAD"

# HEAD = короткий/неканонический OID (не полный 40/64-hex) → refuse.
cp "$LOCAL/HEAD" "$TMP/head.bak"; printf 'deadbeef\n' > "$LOCAL/HEAD"
t "agent-git: отказ при коротком/неканоническом HEAD OID → exit 1" 1 agit status
cp "$TMP/head.bak" "$LOCAL/HEAD"

# Корень gitdir — symlink, а не реальный каталог → refuse (real dir).
rm -rf "$LOCAL"; ln -s "$ORIG" "$LOCAL"
t "agent-git: отказ при symlink-корне gitdir → exit 1" 1 agit status
chmod 0755 "$ORIG"

harness_exit
