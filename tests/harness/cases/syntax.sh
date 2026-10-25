#!/usr/bin/env bash
# tests/harness/cases/syntax.sh — исполнимость каждого поставляемого исходника: bash -n парсит
# любой shell-файл, perl -c парсит любой .pl, и ни один shell-исходник не содержит raw
# $var вплотную к UTF-8 байту (лексический бан, который иначе тихо ломает локализованные
# строки). Инвариант: I-17 (executable convention — всё парсится).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "syntax (bash -n · perl -c · utf8 var-guard)"

# Относительный путь для человекочитаемых имён ассертов.
rel() { printf '%s' "${1#"$ROOT"/}"; }

# shell-исходник: расширение .sh ЛИБО shebang содержит sh.
is_shell() {
  case "$1" in *.sh) return 0 ;; esac
  head -1 "$1" 2>/dev/null | grep -q 'sh'
}

# Кандидаты по каналам поставки: scripts (+вложенные), git-хуки, Claude-хуки, self-test сьют,
# eval-корпус.
shell_candidates() {
  {
    find "$ROOT/scripts" -name '*.sh'
    find "$ROOT/.githooks" -type f
    find "$ROOT/.claude/hooks" -maxdepth 1 -name '*.sh'
    find "$ROOT/tests/harness" -maxdepth 1 -name '*.sh'
    find "$ROOT/tests/harness/lib" -maxdepth 1 -name '*.sh'
    find "$ROOT/tests/harness/cases" -maxdepth 1 -name '*.sh'
    find "$ROOT/tests/harness/fixtures" -maxdepth 1 -name '*.sh'
    find "$ROOT/tests/agent-evals" -mindepth 2 -maxdepth 2 -name '*.sh'
  } 2>/dev/null | LC_ALL=C sort -u
}
perl_candidates() {
  {
    find "$ROOT/scripts" -name '*.pl'
  } 2>/dev/null | LC_ALL=C sort -u
}

# ── 1. bash -n парсит каждый shell-исходник ──
SH=()
while IFS= read -r f; do
  is_shell "$f" || continue
  SH+=("$f")
  t "bash -n $(rel "$f")" 0 bash -n "$f"
done < <(shell_candidates)

# ── 2. perl -c парсит каждый perl-исходник ──
while IFS= read -r f; do
  t "perl -c $(rel "$f")" 0 perl -c "$f"
done < <(perl_candidates)

# ── 3. ни один shell-исходник не ломает локализацию: нет raw $var вплотную к UTF-8 ──
t "нет raw \$var вплотную к UTF-8 байту в shell-исходниках" 0 utf8_var_guard "${SH[@]}"

harness_exit
