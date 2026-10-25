#!/usr/bin/env bash
# install-git-hooks.sh — активирует рантайм-агностик git-хуки репо.
#
# Ставит core.hooksPath=.githooks (репо-local, per-worktree). Идемпотентно; НЕ перетирает
# чужой core.hooksPath (refuse-on-conflict). Прогнать раз на клон/worktree.
# Хуки: .githooks/pre-commit (append-only guard I-2/I-3 + секреты I-7 + TODO I-11).
set -uo pipefail

git rev-parse --show-toplevel >/dev/null 2>&1 || { echo "install-git-hooks: не внутри git-репозитория" >&2; exit 1; }
[ -f .githooks/pre-commit ] || { echo "install-git-hooks: .githooks/pre-commit не найден — запускай из корня репо" >&2; exit 1; }

cur="$(git config --local core.hooksPath 2>/dev/null || true)"
if [ "$cur" = ".githooks" ]; then
  chmod 0755 .githooks/pre-commit 2>/dev/null \
    || { echo "install-git-hooks: не удалось восстановить mode 0755 для pre-commit" >&2; exit 1; }
  [ -x .githooks/pre-commit ] \
    || { echo "install-git-hooks: pre-commit остаётся неисполняемым" >&2; exit 1; }
  echo "install-git-hooks: core.hooksPath уже '.githooks' — no-op config; hook mode=0755"
  exit 0
elif [ -n "$cur" ]; then
  echo "install-git-hooks: core.hooksPath уже задан ('$cur') — НЕ перетираю." >&2
  echo "install-git-hooks:   Смёржи .githooks/pre-commit в свой hooks-путь вручную, либо: git config --local core.hooksPath .githooks" >&2
  exit 1
fi

chmod 0755 .githooks/pre-commit 2>/dev/null \
  || { echo "install-git-hooks: не удалось выставить mode 0755 для pre-commit" >&2; exit 1; }
[ -x .githooks/pre-commit ] \
  || { echo "install-git-hooks: pre-commit остаётся неисполняемым" >&2; exit 1; }
git config --local core.hooksPath .githooks
echo "install-git-hooks: core.hooksPath → .githooks (активировано). Хуки: $(ls .githooks 2>/dev/null | tr '\n' ' ')"
echo "install-git-hooks:   Разовый обход хука при легит-исключении: git commit --no-verify"
