#!/usr/bin/env bash
# tests/harness/lib/fixtures.sh — фабрика git-фикстур и структурные ассерты (opt-in; source ПОСЛЕ harness.sh).
#
# Паттерн «один fixture-репозиторий на ветку
# поведения» — кейс строит под $TMP ровно то git-состояние, которое проверяет одну ветку
# логики SUT. Git-конфиг ТОЛЬКО per-repo (никаких --global), пути нормализуются через
# pwd -P (macOS: mktemp отдаёт /var/…, инструменты — /private/var/…).
#
# API:
#   mk_repo <dir>                    — git init -qb main + identity + gpgsign off
#   mk_bare <dir>                    — bare-репозиторий (герметичный origin)
#   mk_commit <dir> <rel> <content> [msg] — файл + add + commit (родители создаются)
#   phys <path>                      — физический путь (symlink-нормализация, pwd -P)
#   wait_for <secs> <cmd…>           — bounded-поллинг (шаг 0.2с); ЕДИНСТВЕННЫЙ
#                                      санкционированный способ ждать async-состояние
#   assert_file_contains <имя> <file> <ERE>   — в файле есть паттерн
#   assert_file_absent   <имя> <file> <ERE>   — файла нет ИЛИ паттерна в нём нет
#   assert_path_absent   <имя> <path>         — путь не существует
#   assert_branch        <имя> <dir> <branch> — текущая ветка репо
#   assert_json <имя> <file> <py-expr>        — JSON парсится и py-выражение (видит `data`)
#                                               истинно; инлайновый python3, без внешних либ
#   assert_xml_wellformed <имя> <file>        — XML парсится стандартным ElementTree
#
# Зависимости: harness.sh ($TMP, ok/no), git, python3.

mk_repo() { # <dir>
  mkdir -p "$1" \
    && git -C "$1" init -q -b main \
    && git -C "$1" config user.email test@example.invalid \
    && git -C "$1" config user.name "Harness Test" \
    && git -C "$1" config commit.gpgsign false
}

mk_bare() { # <dir>
  mkdir -p "$1" && git -C "$1" init -q --bare -b main
}

mk_commit() { # <dir> <relpath> <content> [msg]
  local d="$1" rel="$2" content="$3" msg="${4:-fixture: $2}"
  mkdir -p "$d/$(dirname "$rel")" \
    && printf '%s\n' "$content" >"$d/$rel" \
    && git -C "$d" add -- "$rel" \
    && git -C "$d" commit -qm "$msg"
}

phys() { # <path> — физический путь без symlink'ов
  (cd "$1" 2>/dev/null && pwd -P)
}

wait_for() { # <секунды> <cmd…> — bounded-поллинг; последний прогон решает
  local secs="${1%.*}"; shift
  local ticks=$((secs * 5)) i=0
  while [ "$i" -lt "$ticks" ]; do
    "$@" >/dev/null 2>&1 && return 0
    perl -e 'select(undef, undef, undef, 0.2)'
    i=$((i + 1))
  done
  "$@" >/dev/null 2>&1
}

assert_file_contains() { # <имя> <file> <ERE>
  if grep -qE -- "$3" "$2" 2>/dev/null; then ok "$1"; else no "$1" "нет /$3/ в $2"; fi
}

assert_file_absent() { # <имя> <file> <ERE> — файла нет или паттерн не встречается
  if [ ! -f "$2" ] || ! grep -qE -- "$3" "$2"; then ok "$1"; else no "$1" "найден запрещённый /$3/ в $2"; fi
}

assert_path_absent() { # <имя> <path>
  if [ ! -e "$2" ]; then ok "$1"; else no "$1" "путь существует: $2"; fi
}

assert_branch() { # <имя> <dir> <branch>
  local b; b="$(git -C "$2" branch --show-current 2>/dev/null)"
  if [ "$b" = "$3" ]; then ok "$1"; else no "$1" "ветка '$b' ≠ '$3'"; fi
}

assert_json() { # <имя> <file> <py-expr; видит распарсенный `data`>
  if AJ_FILE="$2" AJ_EXPR="$3" python3 - <<'PY' >/dev/null 2>&1
import json, os, sys
with open(os.environ["AJ_FILE"], encoding="utf-8") as fh:
    data = json.load(fh)
sys.exit(0 if eval(os.environ["AJ_EXPR"], {"data": data}) else 1)
PY
  then ok "$1"; else no "$1" "json-ассерт не прошёл: $3 ($2)"; fi
}

assert_xml_wellformed() { # <имя> <file>
  if python3 -c 'import sys, xml.etree.ElementTree as ET; ET.parse(sys.argv[1])' "$2" >/dev/null 2>&1
  then ok "$1"; else no "$1" "XML не парсится: $2"; fi
}
