#!/usr/bin/env bash
# tests/harness/cases/ship-guard.sh — scripts/ship-guard.sh <RED_SHA>: тест не правят после RED.
# Контракты: «файлы теста» = добавленные/изменённые в коммите RED_SHA; exit 0 + «OK», если ни один
# не отличается от RED_SHA (коммиты после, staged и unstaged учитываются); exit 1 + «ship-guard:» и
# путь каждого изменённого/удалённого файла; exit 2 — нет аргумента или sha не резолвится;
# правки кода продукта (других файлов) после RED не мешают (exit 0).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "ship-guard (тест не правят после RED)"

SG="$ROOT/scripts/ship-guard.sh"
guard() { (cd "$1" && bash "$SG" "$2"); }
guard0() { (cd "$1" && bash "$SG"); }

# mk_case <dir> — репо: код src/app.sh, затем RED-коммит с двумя файлами теста; RED = его sha.
mk_case() {
  mk_repo "$1"
  mk_commit "$1" src/app.sh 'echo v1' "feat: base" >/dev/null
  mkdir -p "$1/tests"
  printf 'assert a\n' >"$1/tests/a_test.sh"
  printf 'assert b\n' >"$1/tests/b_test.sh"
  git -C "$1" add -A && git -C "$1" commit -qm "test: RED"
  RED="$(git -C "$1" rev-parse HEAD)"
}

# ── exit 2: аргументы
mk_case "$TMP/r0"
t "без аргумента → exit 2" 2 guard0 "$TMP/r0"
t "несуществующий sha → exit 2" 2 guard "$TMP/r0" deadbeefdeadbeefdeadbeefdeadbeefdeadbeef

# ── код меняют и коммитят, тесты не трогали → OK
mk_case "$TMP/r1"
printf 'echo v2\n' >"$TMP/r1/src/app.sh"
git -C "$TMP/r1" add -A && git -C "$TMP/r1" commit -qm "feat: impl"
t "код изменён и закоммичен → exit 0" 0 guard "$TMP/r1" "$RED"
t_out "печатает OK" 'OK'
printf 'echo v3\n' >"$TMP/r1/src/app.sh"
t "код изменён unstaged → exit 0" 0 guard "$TMP/r1" "$RED"

# ── тест изменён unstaged
mk_case "$TMP/r2"
printf 'assert a-weakened\n' >"$TMP/r2/tests/a_test.sh"
t "тест изменён unstaged → exit 1" 1 guard "$TMP/r2" "$RED"
t_out "вывод: ship-guard: и путь файла" 'ship-guard:'
# ── тест изменён и staged
mk_case "$TMP/r3"
printf 'assert b-weakened\n' >"$TMP/r3/tests/b_test.sh"
git -C "$TMP/r3" add -A
t "тест изменён staged → exit 1" 1 guard "$TMP/r3" "$RED"
# ── тест изменён и закоммичен после RED
mk_case "$TMP/r4"
printf 'assert a-weakened\n' >"$TMP/r4/tests/a_test.sh"
git -C "$TMP/r4" add -A && git -C "$TMP/r4" commit -qm "fix: tweak test"
t "тест изменён и закоммичен после RED → exit 1" 1 guard "$TMP/r4" "$RED"
t_out "вывод: путь изменённого файла" 'tests/a_test\.sh'
# ── тест удалён
mk_case "$TMP/r5"
rm "$TMP/r5/tests/b_test.sh"
t "тест удалён → exit 1" 1 guard "$TMP/r5" "$RED"
t_out "вывод: путь удалённого файла" 'tests/b_test\.sh'

harness_exit
