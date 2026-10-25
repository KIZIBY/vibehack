#!/usr/bin/env bash
# tests/harness/lib/stubs.sh — PATH-injected CLI-стабы (opt-in; source ПОСЛЕ harness.sh).
#
# Паттерн: фейковый CLI пишет свой argv в лог, и кейс ассертит, КАК SUT вызывает внешний
# инструмент, не исполняя его по-настоящему (git push, gh — ноль реальных side-effect'ов и ноль сети).
# Все стабы живут в $TMP/stubs (добавляется ПЕРВЫМ в PATH при source); записи — только в $TMP.
#
# API:
#   stub_bin <name> [--log FILE] [--body 'shell…']  — создать стаб; без body → exit 0.
#       Формат строки лога: `<name> <arg1> <arg2> …` (каждый argv в угловых скобках).
#   stub_guard <name> <allowed-ERE>  — fail-loud стаб: argv-строка не матчится → stderr+exit 97
#       (ловит неожиданные подкоманды: любая нецелевая работа SUT с CLI роняет тест).
#   stub_called <log> <ERE>          — ассерт-хелпер: в argv-логе есть строка по паттерну
#   stub_not_called <log> [ERE]      — лога нет/пустой, либо нет строки по паттерну
#   hermetic_env [VAR=val…] <cmd…>   — env -i с минимальным PATH (стабы первыми) и
#       HOME/XDG внутри $TMP: доказательство, что SUT не зависит от ambient-окружения.
#
# Зависимости: только harness.sh ($TMP, ok/no). Никакой ОС-специфики.

STUBS_DIR="$TMP/stubs"
mkdir -p "$STUBS_DIR"
case ":$PATH:" in *":$STUBS_DIR:"*) ;; *) export PATH="$STUBS_DIR:$PATH" ;; esac

# stub_bin <name> [--log FILE] [--body 'shell…']
stub_bin() {
  local name="$1"; shift
  local log="$STUBS_DIR/$name.argv" body="exit 0"
  while [ $# -gt 0 ]; do
    case "$1" in
      --log)  log="$2"; shift 2 ;;
      --body) body="$2"; shift 2 ;;
      *) echo "stub_bin: неизвестный аргумент: $1" >&2; return 2 ;;
    esac
  done
  {
    printf '#!/usr/bin/env bash\n'
    printf 'STUB_LOG=%q\n' "$log"
    # одна строка лога на вызов: имя + каждый argv в <>
    printf '{ printf %%s "%s"; for a in "$@"; do printf " <%%s>" "$a"; done; printf "\\n"; } >>"$STUB_LOG"\n' "$name"
    printf '%s\n' "$body"
  } >"$STUBS_DIR/$name"
  chmod 0755 "$STUBS_DIR/$name"
}

# stub_guard <name> <allowed-ERE> — argv-строка вне паттерна → громкий провал (exit 97)
stub_guard() {
  local name="$1" allowed="$2"
  stub_bin "$name" --body '
allowed_re='"$(printf '%q' "$allowed")"'
if ! printf "%s" "$*" | grep -Eq -- "$allowed_re"; then
  echo "stub_guard('"$name"'): неожиданный вызов: $*" >&2
  exit 97
fi
exit 0'
}

# stub_called <log> <ERE> — вернёт 0, если в логе есть строка по паттерну (для t/ok)
stub_called() { [ -f "$1" ] && grep -Eq -- "$2" "$1"; }

# stub_not_called <log> [ERE] — лог отсутствует/пуст, либо паттерн не встречается
stub_not_called() {
  [ -f "$1" ] || return 0
  if [ $# -ge 2 ]; then ! grep -Eq -- "$2" "$1"; else ! grep -q . "$1"; fi
}

# hermetic_env [VAR=val…] <cmd…> — чистое окружение: только стабы + системные bin,
# HOME/XDG в $TMP. Ведущие VAR=val пробрасываются как env-присваивания (это делает env).
hermetic_env() {
  mkdir -p "$TMP/home/.config" "$TMP/home/.cache"
  env -i \
    PATH="$STUBS_DIR:/usr/bin:/bin:/usr/sbin:/sbin" \
    HOME="$TMP/home" \
    XDG_CONFIG_HOME="$TMP/home/.config" \
    XDG_CACHE_HOME="$TMP/home/.cache" \
    "$@"
}
