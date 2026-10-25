#!/bin/bash
# bash-guard.sh — PreToolUse-хук на Bash: deny ТОЛЬКО высокоточных паттернов, у которых нет
# легитимного применения в нашем процессе (парсинг shell хрупок — агрессивный разбор осознанно
# НЕ делаем, false positives разрушают доверие к guard'у):
#   1) git commit --no-verify           — обходит pre-commit-гарды (append-only/секреты)
#   2) git push --force без --force-with-lease — затирает чужую работу
#   3) прямой git push в main           — вход в main только через PR или scripts/agent-publish-main.sh
# Блок = exit 2 + причина в stderr (конвенция Claude hooks). Сбой парсинга → тихий пропуск
# (guard вспомогательный; решающий слой — pre-commit и проверки publish-скрипта).

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | perl -MJSON::PP -0777 -e '
  my $d = eval { decode_json(<STDIN>) } or exit 0;
  print $d->{tool_input}{command} // "";
' 2>/dev/null)
[ -n "$CMD" ] || exit 0

block() { echo "BLOCKED (bash-guard): $1" >&2; exit 2; }

if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+commit[^|;&]*--no-verify'; then
  block "git commit --no-verify обходит pre-commit-гарды (append-only/секреты). Почини причину блока, а не гард."
fi

if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[^|;&]*[[:space:]]--force([[:space:]]|$)' \
   && ! printf '%s' "$CMD" | grep -q -- '--force-with-lease'; then
  block "git push --force без --force-with-lease затирает чужую работу. Используй --force-with-lease."
fi

if printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[^|;&]*[[:space:]](refs/heads/)?main([[:space:]]|$)' \
   || printf '%s' "$CMD" | grep -qE 'git[[:space:]]+push[^|;&]*:(refs/heads/)?main([[:space:]]|$)'; then
  block "прямой push в main запрещён: вход в main — только через PR или bash scripts/agent-publish-main.sh (проверки + verify-after-push)."
fi

exit 0
