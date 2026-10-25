#!/usr/bin/env bash
# ship-guard.sh — /ship, шаг 3: тест, написанный отдельным агентом до кода (RED-коммит), исполнитель
# не правит. Исполняемый путь конвенции (I-17) вместо «ревьюер посмотрит».
#
# «Файлы теста» = файлы, добавленные или изменённые в коммите RED_SHA. Каждый сверяется с RED_SHA
# с учётом коммитов после него, staged и unstaged правок; удаление — тоже изменение. Код продукта
# (все прочие файлы) не проверяется. Не видит правок вне RED-коммита (хелперы раннера, новый файл
# теста) — это зона ревью; поэтому в RED-коммит кладут только тесты.
#
# Usage: bash scripts/ship-guard.sh <RED_SHA>     (из корня git-репозитория)
# Exit:  0 = файлы теста не тронуты · 1 = файл теста изменён/удалён (пути в выводе)
#        2 = нет аргумента, sha не коммит или в коммите нет добавленных/изменённых файлов
set -uo pipefail

RED="${1:-}"
[ -n "$RED" ] || { echo "ship-guard: usage: bash scripts/ship-guard.sh <RED_SHA>" >&2; exit 2; }
git rev-parse -q --verify "$RED^{commit}" >/dev/null 2>&1 \
  || { echo "ship-guard: '$RED' не резолвится в коммит" >&2; exit 2; }

files=()
while IFS= read -r -d '' f; do files+=("$f"); done \
  < <(git diff-tree --no-commit-id --root -r -z --name-only --diff-filter=AM "$RED")
[ "${#files[@]}" -gt 0 ] || { echo "ship-guard: в $RED нет добавленных/изменённых файлов" >&2; exit 2; }

# рабочее дерево (коммиты после + unstaged + удаление) ∪ индекс (staged, даже если дерево откатили);
# пути буквальные (не glob), сбой git — exit 2, а не ложный OK (fail-closed)
wt="$(git --literal-pathspecs diff -z --name-only "$RED" -- "${files[@]}" | tr '\0' '\n')" \
  || { echo "ship-guard: git diff упал — проверить нельзя" >&2; exit 2; }
ix="$(git --literal-pathspecs diff -z --name-only --cached "$RED" -- "${files[@]}" | tr '\0' '\n')" \
  || { echo "ship-guard: git diff --cached упал — проверить нельзя" >&2; exit 2; }
changed="$(printf '%s\n%s\n' "$wt" "$ix" | sed '/^$/d' | sort -u)"

if [ -z "$changed" ]; then
  echo "ship-guard: OK — файлы теста не тронуты с RED ${RED:0:8} (${#files[@]} шт.)"
  exit 0
fi
while IFS= read -r f; do
  echo "ship-guard: файл теста изменён после RED ${RED:0:8}: $f"
done <<< "$changed"
exit 1
