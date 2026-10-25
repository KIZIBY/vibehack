#!/usr/bin/env bash
# ship-worktree.sh — /ship параллельно: 2–4 исполнителя, каждый в своём git worktree. Исследование CMU
# (Effective Strategies for Asynchronous SE Agents): параллель даёт +15–25 п.п., worktree лучше мягкой
# изоляции, 8 агентов хуже 4. Лимит держит скрипт, а не память агента (I-17).
#
# Usage: bash scripts/ship-worktree.sh new <slug>   ветка ship/<slug> от HEAD + worktree рядом с основным
#                                                   checkout: <родитель>/<имя-checkout>-<slug>;
#                                                   путь — последней строкой вывода
#        bash scripts/ship-worktree.sh list         дополнительные worktree и счётчик N/<лимит>
# ENV:   SHIP_MAX_WORKTREES — лимит дополнительных worktree (по умолчанию 4)
# Exit:  0 = готово · 1 = лимит исчерпан или slug занят · 2 = неверные аргументы / не git-репозиторий
set -uo pipefail

die() { echo "ship-worktree: $2" >&2; exit "$1"; }

MAX="${SHIP_MAX_WORKTREES:-4}"
case "$MAX" in ''|*[!0-9]*) die 2 "SHIP_MAX_WORKTREES должен быть числом, получено '$MAX'" ;; esac
[ "$MAX" -ge 1 ] && [ "$MAX" -le 4 ] \
  || die 2 "SHIP_MAX_WORKTREES — от 1 до 4 (устав 2.0.0, I-15), получено $MAX"
git rev-parse --git-dir >/dev/null 2>&1 || die 2 "не git-репозиторий"

# первая запись `git worktree list` — основной checkout, остальные — дополнительные worktree;
# сбой git — отказ, а не «0 worktree» с созданием в текущем каталоге (fail-closed)
worktrees() { git worktree list --porcelain | awk '/^worktree /{print substr($0, 10)}'; }
WL="$(worktrees)" || die 2 "git worktree list упал"
MAIN="$(printf '%s\n' "$WL" | head -n 1)"
[ -n "$MAIN" ] && [ -d "$MAIN" ] || die 2 "не удалось определить основной checkout"
extra() { printf '%s\n' "$WL" | tail -n +2 | sed '/^$/d'; }

case "${1:-}" in
  list)
    n=0
    while IFS= read -r w; do
      n=$((n + 1))
      echo "$w  $(git -C "$w" branch --show-current 2>/dev/null || echo '?')"
    done < <(extra)
    echo "worktree: $n/$MAX"
    ;;
  new)
    slug="${2:-}"
    [ -n "$slug" ] || die 2 "usage: bash scripts/ship-worktree.sh new <slug>"
    case "$slug" in *[!A-Za-z0-9._-]*) die 2 "slug — только [A-Za-z0-9._-], получено '$slug'" ;; esac
    # лок на «проверить лимит → создать»: два одновременных new не пройдут оба при N = лимит − 1
    LOCK="$(git rev-parse --path-format=absolute --git-common-dir)/ship-worktree.lock"
    mkdir "$LOCK" 2>/dev/null || die 1 "занят: идёт другой ship-worktree new (лок $LOCK) — повтори позже"
    trap 'rmdir "$LOCK" 2>/dev/null' EXIT
    WL="$(worktrees)" || die 2 "git worktree list упал"
    n="$(extra | grep -c .)"
    [ "$n" -lt "$MAX" ] \
      || die 1 "лимит параллельных worktree исчерпан ($n/$MAX) — заверши один (git worktree remove …) или работай последовательно"
    dest="$(dirname "$MAIN")/$(basename "$MAIN")-$slug"
    ! git show-ref --verify --quiet "refs/heads/ship/$slug" || die 1 "ветка ship/$slug уже есть"
    [ ! -e "$dest" ] || die 1 "каталог $dest уже есть"
    git worktree add -q -b "ship/$slug" "$dest" HEAD >/dev/null 2>&1 || die 1 "git worktree add не удался"
    echo "ship-worktree: ship/$slug готов — cd в путь ниже и там /ship \"…\""
    echo "$dest"
    ;;
  *) die 2 "usage: bash scripts/ship-worktree.sh new <slug> | list" ;;
esac
