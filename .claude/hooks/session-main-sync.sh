#!/bin/bash
# session-main-sync.sh — SessionStart-хук: актуализация origin/main.
# Устаревшая локальная копия main означает, что агент начнёт работу поверх старой картины
# репозитория. Хук делает fetch и сообщает агенту/пользователю об отставании от origin/main.
# Сбой (нет сети, нет origin) — только предупреждение, сессию не блокирует.

DIR="${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
cd "$DIR" 2>/dev/null || exit 0

if ! git fetch origin --quiet 2>/dev/null; then
  echo "session-main-sync: не удалось выполнить git fetch origin (нет сети или remote 'origin'). Сделай fetch вручную перед правками."
  exit 0
fi

BEHIND=$(git rev-list --count HEAD..origin/main 2>/dev/null)
if [ -n "$BEHIND" ] && [ "$BEHIND" != "0" ]; then
  echo "session-main-sync: текущая ветка отстаёт от origin/main на $BEHIND коммит(ов). Правило: работа начинается с актуализации main (git fetch + rebase на origin/main)."
fi
exit 0
