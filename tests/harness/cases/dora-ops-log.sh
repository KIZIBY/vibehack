#!/usr/bin/env bash
# tests/harness/cases/dora-ops-log.sh — ops-log append + DORA-агрегация. Инвариант: I-8.
#
# Поведенческий контракт двух SUT над ОДНИМ герметичным репо в $TMP (реальный docs/ops-journal.md
# репозитория не трогается никогда):
#   scripts/ops-log.sh      — append-only писатель docs/ops-journal.md (ровно +1 строка, прошлое
#                             не переписывается — I-8);
#   scripts/dora-metrics.sh — DORA/автономия из git log + ops-journal; правило подсчёта деплоев
#                             (deploy:* → иначе publish:done, publish:pr никогда); fast-path
#                             --usage-agg (v=1) и корректность при отравленном `git` впереди PATH.
# Проверяются СТРУКТУРНЫЕ ключи/значения, а не косметика строк.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "dora-metrics · ops-log (append · агрегация · --usage-agg · poisoned-git)"

# ── герметичный репозиторий: 2 коммита (1 человеческий + 1 агентный Co-Authored-By → автономия 50%) ──
OL="$TMP/ops-repo"; mkdir -p "$OL"; git -C "$OL" init -q
git -C "$OL" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "человеческий коммит"
git -C "$OL" -c user.email=t@t -c user.name=t commit -q --allow-empty \
  -m "$(printf 'агентная работа\n\nCo-Authored-By: Test Agent <t@t>')"
J="$OL/docs/ops-journal.md"

# ops_log — писатель работает из корня своего репо (subshell не двигает cwd теста).
ops_log() { ( cd "$OL" && bash "$ROOT/scripts/ops-log.sh" "$@" ); }

# ol_seed — заливает поток DORA-событий; на КАЖДОМ append проверяет инвариант I-8:
# файл прирос РОВНО на одну строку, а весь прежний префикс байт-в-байт неизменен (append-only).
# Побочно — сеет данные для агрегации: 1 deploy:done + 1 deploy:failed (CFR) + incident-пара (MTTR).
ol_seed() {
  local ev det before
  for pair in "deploy:done|s1" "deploy:failed|s2 rc=1" "incident:open|p1-demo boom" "incident:resolved|p1-demo"; do
    ev="${pair%%|*}"; det="${pair#*|}"
    before="$(wc -l < "$J")"
    cp "$J" "$TMP/ol.snap"
    ops_log "$ev" "$det" >/dev/null 2>&1 || return 1
    [ "$(wc -l < "$J")" -eq "$((before + 1))" ] || return 1
    head -n "$before" "$J" | cmp -s - "$TMP/ol.snap" || return 1
  done
}

# dora_run — text-режим над seeded git+journal. Источники только локальные (сети/gh нет by design).
dora_run() { TMPDIR="$TMP" bash "$ROOT/scripts/dora-metrics.sh" "$@"; }

# ── ops-log: append-only журнал (I-8) ──
t "ops-log: первое событие создаёт append-only журнал (exit 0)" 0 ops_log deploy:start s1
t "ops-log: событие записано строкой | event | detail |" 0 grep -qF "| deploy:start | s1 |" "$J"
t "ops-log: поток DORA-событий — каждый append ровно +1 строка, прежние не переписаны (I-8)" 0 ol_seed

# ── dora-metrics: агрегация над seeded данными (структурные ключи + поведенческие значения) ──
t "dora: агрегация над seeded git+ops-journal → exit 0" 0 dora_run "$OL" --days 30
t_out "dora: структурный ключ метрики deployment frequency" 'deployment frequency'
t_out "dora: структурный ключ метрики mttr" 'mttr'
t_out "dora: автономия посчитана 50% (1 агентный из 2 коммитов)" '50% .1 из 2'
t_out "dora: CFR = 1 fail из 2 попыток деплоя" '1 fail из 2 попыток'
t_out "dora: источник частоты — deploy:*" 'источник: deploy:done'
t "dora: неизвестный флаг → exit 2" 2 dora_run "$OL" --tickets-file x

# ── правило подсчёта поставок: publish-события не удваивают deploy ──
ops_log publish:done "abc123 main" >/dev/null 2>&1
ops_log publish:pr "feature/x" >/dev/null 2>&1
t "dora: deploy:* есть → publish:done НЕ добавляется к деплоям" 0 dora_run "$OL" --days 30
t_out "dora: CFR по-прежнему 1 fail из 2 (publish не посчитан)" '1 fail из 2 попыток'

PJ="$TMP/pub-repo"; mkdir -p "$PJ"; git -C "$PJ" init -q
git -C "$PJ" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
pub_log() { ( cd "$PJ" && bash "$ROOT/scripts/ops-log.sh" "$@" ) >/dev/null 2>&1; }
pub_log publish:done "s1 main"; pub_log publish:done "s2 main"; pub_log publish:failed "s3 rc=1"
pub_log publish:pr "feature/a"; pub_log publish:pr "feature/b"
t "dora: нет deploy:* → поставка считается по publish:done|failed" 0 dora_run "$PJ" --days 30
t_out "dora: fallback-источник назван" 'источник: publish:done'
t_out "dora: CFR fallback = 1 fail из 3 (publish:pr не считается)" '1 fail из 3 попыток'

# ── --usage-agg: fast-path контракта v=1 (git/gh не в тракте) ──
UA="$TMP/uagg"; mkdir -p "$UA/specs/001-run"
uagg_ts() { perl -e 'my @g=gmtime(time-$ARGV[0]); printf "%04d-%02d-%02dT%02d:%02d:%02dZ",$g[5]+1900,$g[4]+1,$g[3],$g[2],$g[1],$g[0];' "$1"; }
{ printf '| ts (UTC) | event | detail |\n|---|---|---|\n'
  printf '| %s | usage:agent:x | tokens=100 source=cli |\n'  "$(uagg_ts 3600)"
  printf '| %s | usage:agent:x | tokens=1000 source=cli |\n' "$(uagg_ts 7200)"
} > "$UA/specs/001-run/audit.md"
dora_uagg() { TMPDIR="$TMP" bash "$ROOT/scripts/dora-metrics.sh" "$1" --usage-agg; }

t "uagg: --usage-agg над seeded audit.md → exit 0" 0 dora_uagg "$UA"
cp "$TMP/last.out" "$TMP/uagg.clean"
t "uagg: контракт объявляет форму v=1 (стабильный маркер версии, не русская проза)" 0 grep -qx 'v=1' "$TMP/uagg.clean"
t "uagg: stdout ТОЛЬКО key=value — структурная форма контракта v=1" 1 grep -qvE '^[a-z0-9_]+=' "$TMP/uagg.clean"

# ── POISONED-GIT: git-шим впереди PATH печатает мусор и обманул бы наивного потребителя;
#    --usage-agg НЕ консультируется с ambient git → вывод байт-в-байт равен чистому прогону ──
POISON="$TMP/poison-bin"; mkdir -p "$POISON"
printf '#!/bin/sh\necho POISONED-DEADBEEF\nexit 0\n' > "$POISON/git"; chmod +x "$POISON/git"
dora_uagg_poisoned() { PATH="$POISON:$PATH" TMPDIR="$TMP" bash "$ROOT/scripts/dora-metrics.sh" "$1" --usage-agg; }

t "uagg poisoned-git: exit 0 при отравленном git впереди PATH" 0 dora_uagg_poisoned "$UA"
cp "$TMP/last.out" "$TMP/uagg.poisoned"
t "uagg poisoned-git: вывод байт-в-байт равен чистому (git вне тракта fast-path)" 0 cmp -s "$TMP/uagg.clean" "$TMP/uagg.poisoned"
t "uagg poisoned-git: отравленные байты git НЕ просочились в контракт" 1 grep -q 'POISONED' "$TMP/uagg.poisoned"

harness_exit
