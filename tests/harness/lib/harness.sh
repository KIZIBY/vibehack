#!/usr/bin/env bash
# tests/harness/lib/harness.sh — общая тест-библиотека (source из tests/harness/cases/*.sh).
#
# Контракт вывода (машиночитаемый, парсится scripts/ci-test-report.py → JUnit):
#   ── <domain> ──   — заголовок секции (ОДИН на case-файл; печатает section())
#   ok    <name>     — успешный ассерт
#   FAIL  <name> …   — упавший ассерт (+ строки "      | …" с диагностикой)
#
# Каждый case-файл САМОДОСТАТОЧЕН: свой mktemp -d ($TMP), своя git-identity, свои счётчики
# pass/fail на процесс (НЕ глобальный counter — это и разблокирует параллельный прогон и
# убирает завязку на магический baseline). Последняя строка case-файла — `harness_exit`
# (exit 0 iff fail==0). Оркестратор считает ok/FAIL по выводу и агрегирует гейт.
set -uo pipefail

HARNESS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
ROOT="${ROOT:-$HARNESS_ROOT}"
FIX="$ROOT/tests/harness/fixtures"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/harness-case.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0

# section <title> — заголовок секции case-файла (ровно один на файл).
section() { printf '── %s ──\n' "$1"; }

# t <имя> <ожидаемый-exit> <команда…> — гоняет команду (может быть функцией case-файла;
# исполняется в ТЕКУЩЕМ shell, поэтому видит глобальные переменные), сверяет код возврата.
t() {
  local name="$1" want="$2"; shift 2
  local got=0
  "$@" >"$TMP/last.out" 2>&1 || got=$?
  if [ "$got" -eq "$want" ]; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s (exit %s, ожидал %s)\n' "$name" "$got" "$want"
    sed 's/^/      | /' "$TMP/last.out" | head -6
  fi
}

# t_out <имя> <ERE> — проверяет, что вывод ПОСЛЕДНЕЙ t содержит паттерн.
t_out() {
  local name="$1" pat="$2"
  if grep -qE "$pat" "$TMP/last.out"; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s (нет /%s/ в выводе последней команды)\n' "$name" "$pat"
  fi
}

# t_out_absent <имя> <ERE> — raw rejected input НЕ отражается в выводе (redaction-контракт).
t_out_absent() {
  local name="$1" pat="$2"
  if ! grep -qE "$pat" "$TMP/last.out"; then
    pass=$((pass + 1)); printf 'ok    %s\n' "$name"
  else
    fail=$((fail + 1)); printf 'FAIL  %s (найден запрещённый /%s/ в выводе)\n' "$name" "$pat"
  fi
}

# ok/no — ручной ассерт, когда логику проще выразить прямо в case-файле.
ok() { pass=$((pass + 1)); printf 'ok    %s\n' "$1"; }
no() {
  fail=$((fail + 1)); printf 'FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '      | %s\n' "$2"
  return 0
}

# ps_ — обёртка над state-машиной (SUT).
ps_() { bash "$ROOT/scripts/pipeline-state.sh" "$@"; }

# utf8_var_guard <файлы…> — лексический бан: raw $name прямо перед UTF-8 байтом в shell-исходнике.
utf8_var_guard() {
  LC_ALL=C perl -ne '
    if (/\$[A-Za-z_][A-Za-z0-9_]*(?=[\x80-\xFF])/) { print "$ARGV:$.:$_"; $bad=1 }
    close ARGV if eof;
    END { exit($bad ? 1 : 0) }
  ' "$@"
}

# ps_reject_unchanged <dir> <pipeline-state args…> — «правильный контракт негатива»:
# exit2 + byte-invariance state.md/audit.md + отсутствие leftover .state.md.* temp.
ps_reject_unchanged() {
  local d="$1"; shift
  local rc=0
  cp "$d/state.md" "$TMP/ps-state.before"
  cp "$d/audit.md" "$TMP/ps-audit.before"
  ps_ "$@" >/dev/null 2>&1 || rc=$?
  [ "$rc" -eq 2 ] || return 1
  cmp "$TMP/ps-state.before" "$d/state.md" >/dev/null || return 1
  cmp "$TMP/ps-audit.before" "$d/audit.md" >/dev/null || return 1
  ! find "$d" -maxdepth 1 -name '.state.md.*' -print | grep -q .
}

# harness_exit — последняя строка case-файла: exit 0 iff все ассерты зелёные.
harness_exit() { [ "$fail" -eq 0 ]; }
