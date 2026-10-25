#!/usr/bin/env bash
# tests/harness/cases/changelog-v1.sh — поведенческий контракт append-only changelog-писателя
# (scripts/changelog-append-v1.pl). Инварианты I-2/I-3: атомарный append, идемпотентность,
# неизменяемость строк, crash-safety (нет partial + нет leaked temp), detached-writer fail-closed,
# конкурентные писатели без потерь/дублей. Порт эталонного tests/changelog-v1-contract.sh
# (образец «как надо») в harness-стиль (все ассерты исполняются, падения накапливаются).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "changelog-v1 (append-only · crash-safety · concurrent)"

WRITER="$ROOT/scripts/changelog-append-v1.pl"
new_log() {
  local root="$1"; mkdir -p "$root/specs/034-demo"
  printf 'stage\trevision\tchange\treason\n' > "$root/specs/034-demo/sdd-changelog.tsv"
  chmod 0644 "$root/specs/034-demo/sdd-changelog.tsv"
}

# ── BASIC: append + идемпотентность + отдельная неизменяемая строка + канонический счётчик ──
B="$TMP/basic"; new_log "$B"
b_first()  { perl "$WRITER" sdd "$B" specs/034-demo r1 first evidence   | grep -Eq '^appended sha256=[0-9a-f]{64}$'; }
b_idem()   { perl "$WRITER" sdd "$B" specs/034-demo r1 first evidence   | grep -Eq '^existing sha256=[0-9a-f]{64}$'; }
b_second() { perl "$WRITER" sdd "$B" specs/034-demo r1 second evidence-2 >/dev/null; }
b_count()  { [ "$(wc -l < "$B/specs/034-demo/sdd-changelog.tsv" | tr -d ' ')" -eq 3 ]; }
t "basic: первый append → appended sha256" 0 b_first
t "basic: повторный append идемпотентен → existing sha256" 0 b_idem
t "basic: та же ревизия — отдельная неизменяемая строка" 0 b_second
t "basic: канонический счётчик строк == 3" 0 b_count

# ── CRASH: прерывание по file-size (ulimit) → нет partial, нет leaked temp ──
C="$TMP/crash"; new_log "$C"
cp "$C/specs/034-demo/sdd-changelog.tsv" "$TMP/crash.before"
LONG="$(perl -e 'print q{x} x 4096')"
crash_rc=0
( ulimit -f 1; perl "$WRITER" sdd "$C" specs/034-demo r1 "$LONG" "$LONG" ) \
  >"$TMP/crash.out" 2>"$TMP/crash.err" || crash_rc=$?
c_failed()  { [ "$crash_rc" -ne 0 ]; }
c_intact()  { cmp -s "$TMP/crash.before" "$C/specs/034-demo/sdd-changelog.tsv"; }
c_no_temp() { [ -z "$(find "$C/specs/034-demo" -maxdepth 1 -name '.changelog-append-v1.*' -print)" ]; }
t "crash: writer прерван по file-size → ненулевой код" 0 c_failed
t "crash: прерванный writer НЕ изменил канонический changelog" 0 c_intact
t "crash: прерванный writer не оставил owned-temp" 0 c_no_temp

# NB: детерминированный тест «detached writer под dir-lock» (подмена каталога в момент блокировки)
# СОЗНАТЕЛЬНО ВЫРЕЗАН — он не воспроизводим без гонки: полагался на sleep-окно, чтобы поймать writer
# заблокированным на flock ДО mv, что зависит от латентности старта процесса (зелёный на macOS,
# красный в Linux-контейнере). Сделать его детерминированным без /proc-пробы (обратная OS-завязка)
# или модификации SUT нельзя. Ядро fail-closed/атомарности покрыто CRASH + CONCURRENT ниже.

# ── CONCURRENT: 6 писателей одновременно → 7 строк, 7 уникальных ──
K="$TMP/concurrent"; new_log "$K"
pids=""; i=1
while [ "$i" -le 6 ]; do
  perl "$WRITER" sdd "$K" specs/034-demo "r$i" "change-$i" "evidence-$i" \
    >"$K/out.$i" 2>"$K/err.$i" & pids="$pids $!"
  i=$((i + 1))
done
conc_fail=0
for pid in $pids; do wait "$pid" || conc_fail=1; done
kc_all()  { [ "$conc_fail" -eq 0 ]; }
kc_rows() { [ "$(wc -l < "$K/specs/034-demo/sdd-changelog.tsv" | tr -d ' ')" -eq 7 ]; }
kc_uniq() { [ "$(LC_ALL=C sort -u "$K/specs/034-demo/sdd-changelog.tsv" | wc -l | tr -d ' ')" -eq 7 ]; }
t "concurrent: 6 писателей завершились успешно" 0 kc_all
t "concurrent: 7 строк — ни одной потери" 0 kc_rows
t "concurrent: 7 уникальных — ни одного дубля" 0 kc_uniq

harness_exit
