#!/usr/bin/env bash
# tests/harness/run-tests.sh — тонкий оркестратор self-test сьюта харнесса.
#
# Модель: один поведенческий case-файл на домен (tests/harness/cases/*.sh), каждый самодостаточен
# (source tests/harness/lib/harness.sh, свой mktemp, свои счётчики). Оркестратор выбирает case'ы по
# уровню (tiers.tsv), гоняет их (full — с ограниченным параллелизмом, каждый герметичен), затем
# СКЛЕИВАет их вывод СЕКЦИОННО-УПОРЯДОЧЕННО в stdout (потоковый парсер JUnit требует, чтобы блок
# каждой секции шёл непрерывно), считает ok/FAIL и печатает финальный `ИТОГ:` (без магического
# baseline — гейт = все case'ы exit 0 И проходят min-asserts-floor).
#
# Usage: bash tests/harness/run-tests.sh [--tier fast|full | fast|full] [--list] [CASE …]
#   --tier fast   — только быстрый dev-слой (жёсткий потолок 180s); то же — позиционное `fast`
#   --tier full   — полный слой (по умолчанию; потолок 1800s, 0 = выкл); то же — позиционное `full`
#   --list        — напечатать манифест уровней и выйти
#   CASE …        — прогнать только перечисленные case-файлы (по basename без .sh)
#   Пер-case потолок: 4-я колонка tiers.tsv (сек; «-»/пусто → RT_CASE_HARD_CAP, default 300;
#   0 → выкл); превышение → строка `FAIL  case-timeout…` в секции кейса → красный гейт.
# Exit: 0 = всё зелёное · 1 = есть FAIL / floor-violation · 2 = ошибка аргументов · 124 = таймаут
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
CASES_DIR="$ROOT/tests/harness/cases"
TIERS="$ROOT/tests/harness/tiers.tsv"

TIER="full"
DO_LIST=0
SELECT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="${2:-}"; shift 2 ;;
    --tier=*) TIER="${1#*=}"; shift ;;
    --list) DO_LIST=1; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    -*) printf 'неизвестный флаг: %s\n' "$1" >&2; exit 2 ;;
    fast|full) TIER="$1"; shift ;;   # позиционный алиас --tier (case-файлов с такими именами нет)
    *) SELECT="$SELECT $1"; shift ;;
  esac
done
case "$TIER" in fast|full) ;; *) printf 'неизвестный tier: %s (fast|full)\n' "$TIER" >&2; exit 2 ;; esac

[ -f "$TIERS" ] || { printf 'нет манифеста: %s\n' "$TIERS" >&2; exit 2; }

# manifest → строки "<case> <tier> <floor> [cap]" (комментарии/пустое отброшены)
manifest() { grep -vE '^\s*(#|$)' "$TIERS"; }

if [ "$DO_LIST" -eq 1 ]; then
  printf '%-24s %-6s %-12s %s\n' "CASE" "TIER" "MIN-ASSERTS" "CAP"
  manifest | while read -r cf tr fl bd _extra; do printf '%-24s %-6s %-12s %s\n' "$cf" "$tr" "$fl" "${bd:--}"; done
  exit 0
fi

# Выбор case'ов: явный список > tier-фильтр. fast = только fast; full = fast+full.
SELECTED=""       # "<case>:<floor>:<cap>" через пробел, в порядке манифеста
while read -r cf tr fl bd _extra; do
  [ -n "$cf" ] || continue
  if [ -n "$SELECT" ]; then
    case " $SELECT " in *" ${cf%.sh} "*|*" $cf "*) ;; *) continue ;; esac
  else
    if [ "$TIER" = fast ] && [ "$tr" != fast ]; then continue; fi
  fi
  SELECTED="$SELECTED ${cf}:${fl:-1}:${bd:--}"
done <<EOF
$(manifest)
EOF

[ -n "$SELECTED" ] || { printf 'нет case'\''ов для запуска (tier=%s select=%s)\n' "$TIER" "$SELECT" >&2; exit 2; }

RUNDIR="$(mktemp -d "${TMPDIR:-/tmp}/harness-suite.XXXXXX")"
SUITE_T0="$(perl -e 'use Time::HiRes qw(time); printf "%.3f", time')"

# ── жёсткий потолок wall-clock (I-13) ──
# fast → 180s, full → 1800s (запас на медленный fork macOS); явный RT_SUITE_HARD_CAP
# переопределяет; <=0 → выкл (authoritative).
if [ -z "${RT_SUITE_HARD_CAP+x}" ]; then
  case "$TIER" in fast) RT_SUITE_HARD_CAP=180 ;; *) RT_SUITE_HARD_CAP=1800 ;; esac
fi
RT_SECTION_BUDGET="${RT_SECTION_BUDGET:-90}"
RT_CASE_HARD_CAP="${RT_CASE_HARD_CAP:-300}"
RT_PARALLEL="${RT_PARALLEL:-4}"
[ "$TIER" = fast ] && RT_PARALLEL=1
RT_MAIN_PID=$$
RT_WATCHDOG=""
cleanup() { [ -n "$RT_WATCHDOG" ] && kill "$RT_WATCHDOG" 2>/dev/null; rm -rf "$RUNDIR"; return 0; }
if [ "$RT_SUITE_HARD_CAP" -gt 0 ] 2>/dev/null; then
  trap 'echo "SUITE_TIMEOUT: жёсткий потолок '"$RT_SUITE_HARD_CAP"'s превышен — прогон прерван; гоняй по одному case (bash tests/harness/run-tests.sh <CASE>) или подними RT_SUITE_HARD_CAP осознанно" >&2; jobs -p | xargs kill 2>/dev/null; cleanup; exit 124' TERM
  # Единственный процесс-таймер = сам perl (kill $RT_WATCHDOG попадает в него, а не в обёртку);
  # fd отвязаны от stdout-пайпа, иначе потоковый JUnit-парсер не увидит EOF до срабатывания cap.
  perl -e 'select(undef,undef,undef,$ARGV[0]); kill("TERM",$ARGV[1])' \
    "$RT_SUITE_HARD_CAP" "$RT_MAIN_PID" </dev/null >/dev/null 2>&1 &
  RT_WATCHDOG=$!
  disown "$RT_WATCHDOG" 2>/dev/null || true
fi
trap 'cleanup' EXIT

# ── прогон case'ов (герметичны → параллельно; вывод буферизуется в файл) ──
# Кейс стартует лидером своей process-group (perl setpgrp) под собственным perl-watchdog'ом
# (тот же приём, что suite-cap: timeout(1) в базовой macOS отсутствует). По превышении cap
# группа получает TERM→KILL (добивает подвисших детей кейса), в вывод дописывается обычная
# строка `FAIL  case-timeout…` (JUnit-видимая) и rc=124 — гейт краснеет без спец-веток.
run_case() { # <case-file> <cap-seconds>
  local cf="$1" cap="$2" t0 t1 pid wd rc=0
  t0="$(perl -e 'use Time::HiRes qw(time); printf "%.3f", time')"
  RT_SUITE_HARD_CAP=0 perl -e 'setpgrp(0,0); exec @ARGV' bash "$CASES_DIR/$cf" \
    >"$RUNDIR/$cf.out" 2>&1 &
  pid=$!
  wd=""
  if [ "$cap" -gt 0 ] 2>/dev/null; then
    perl -e '
      select(undef, undef, undef, $ARGV[0]);
      open my $m, ">", $ARGV[2]; close $m;
      kill "TERM", -$ARGV[1];
      select(undef, undef, undef, 2);
      kill "KILL", -$ARGV[1];
    ' "$cap" "$pid" "$RUNDIR/$cf.timedout" </dev/null >/dev/null 2>&1 &
    wd=$!
  fi
  # suite-watchdog шлёт TERM обёртке run_case — форвардим его в process-group кейса
  trap 'kill -TERM -- "-$pid" 2>/dev/null' TERM
  wait "$pid" || rc=$?
  [ -n "$wd" ] && { kill "$wd" 2>/dev/null; wait "$wd" 2>/dev/null; }
  if [ -f "$RUNDIR/$cf.timedout" ]; then
    printf 'FAIL  case-timeout: %s превысил жёсткий потолок %ss — подними cap в tiers.tsv осознанно или чини кейс\n' \
      "${cf%.sh}" "$cap" >>"$RUNDIR/$cf.out"
    rc=124
  fi
  echo "$rc" >"$RUNDIR/$cf.rc"
  t1="$(perl -e 'use Time::HiRes qw(time); printf "%.3f", time')"
  perl -e 'printf "%.2f", $ARGV[1]-$ARGV[0]' "$t0" "$t1" >"$RUNDIR/$cf.dur"
}

running=0
for entry in $SELECTED; do
  cf="${entry%%:*}"; rest="${entry#*:}"; cap="${rest#*:}"
  [ "$cap" = "-" ] && cap="$RT_CASE_HARD_CAP"
  [ -f "$CASES_DIR/$cf" ] || { printf '1\n' >"$RUNDIR/$cf.rc"; printf '── %s ──\nFAIL  case-файл отсутствует: %s\n' "${cf%.sh}" "$cf" >"$RUNDIR/$cf.out"; continue; }
  run_case "$cf" "$cap" &
  running=$((running + 1))
  if [ "$running" -ge "$RT_PARALLEL" ]; then wait; running=0; fi
done
wait

# ── склейка вывода в порядке манифеста + тайминги + floor ──
sum_ok=0
sum_fail=0
gate=0
floor_report=""
for entry in $SELECTED; do
  cf="${entry%%:*}"; rest="${entry#*:}"; floor="${rest%%:*}"
  cat "$RUNDIR/$cf.out"
  c_ok="$(grep -cE '^ok   ' "$RUNDIR/$cf.out" 2>/dev/null || true)"; c_ok="${c_ok:-0}"
  c_fail="$(grep -cE '^FAIL ' "$RUNDIR/$cf.out" 2>/dev/null || true)"; c_fail="${c_fail:-0}"
  c_rc="$(cat "$RUNDIR/$cf.rc" 2>/dev/null || echo 1)"
  c_dur="$(cat "$RUNDIR/$cf.dur" 2>/dev/null || echo 0)"
  sum_ok=$((sum_ok + c_ok))
  sum_fail=$((sum_fail + c_fail))
  printf 'SECTION_TIME %s %ss\n' "${cf%.sh}" "$c_dur"
  perl -e 'exit(($ARGV[0] > $ARGV[1]) ? 0 : 1)' "$c_dur" "$RT_SECTION_BUDGET" 2>/dev/null \
    && printf 'SLOW_CASE %s %ss > %ss\n' "${cf%.sh}" "$c_dur" "$RT_SECTION_BUDGET"
  [ "$c_rc" != 0 ] && gate=1
  if [ $((c_ok + c_fail)) -lt "$floor" ]; then
    gate=1
    floor_report="$floor_report ${cf%.sh}(=$((c_ok + c_fail))<$floor)"
  fi
done

SUITE_T1="$(perl -e 'use Time::HiRes qw(time); printf "%.3f", time')"
if [ -n "$floor_report" ]; then
  printf '── orchestrator ──\n'
  for v in $floor_report; do printf 'FAIL  floor:%s (asserts ниже минимума)\n' "$v"; done
fi
perl -e 'printf "SUITE_TIME %.2fs\n", $ARGV[1]-$ARGV[0]' "$SUITE_T0" "$SUITE_T1"
printf 'ИТОГ: pass=%d fail=%d cases=%s tier=%s\n' "$sum_ok" "$sum_fail" "$(printf '%s' "$SELECTED" | wc -w | tr -d ' ')" "$TIER"

[ "$gate" -eq 0 ] && [ "$sum_fail" -eq 0 ]
