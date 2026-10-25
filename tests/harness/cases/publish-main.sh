#!/usr/bin/env bash
# tests/harness/cases/publish-main.sh — прямая публикация и exact-режим. Инварианты: I-8, I-10.
#
# Поведенческий контракт scripts/agent-publish-main.sh (режимы «main» и «exact»; PR-режим — в
# publish-pr.sh): verify-after-push (ls-remote подтверждает, что remote ref реально сдвинулся на
# pushed OID), ровно ОДНО publish:done на непустую публикацию и НИ ОДНОГО deploy:* (деплой пишет
# только деплой-скрипт проекта — DORA не удваивается), publish:noop при remote==HEAD, graceful
# degradation телеметрии (I-8: сбой ops-log не меняет исход публикации), detached HEAD без явного
# режима — отказ, и exact-OID режим (immutable literal-OID push без rebase/autocommit; mismatch →
# отказ без push).
# Герметично: рабочее репо + bare remote под $TMP, только file://-remotes, без реальной сети.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "agent-publish-main (verify-after-push · publish-event · noop · detached · exact-OID)"

SUT="$ROOT/scripts/agent-publish-main.sh"
export AGENT_PUBLISH_BACKOFF_BASE=0   # без backoff-sleep между retry-итерациями
unset AGENT_PUBLISH_MODE

# Рабочее репо + bare remote под $TMP, seeded одним коммитом, запушенным в refs/heads/main.
# Локальная ветка = main: на целевой ветке режим по умолчанию — прямая публикация.
setup_repo() { # $1 work-repo, $2 bare-remote
  local repo="$1" bare="$2"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email t@t
  git -C "$repo" config user.name t
  git -C "$repo" commit -q --allow-empty -m c1
  git init -q --bare "$bare"
  git -C "$repo" remote add origin "file://$bare"
  git -C "$repo" push -q origin HEAD:main
}
remote_oid() { git --git-dir="$1" rev-parse refs/heads/main 2>/dev/null; }

# ── 1/3. VERIFY-AFTER-PUSH + ровно одно publish:done + NOOP ─────────────────────────────────
N="$TMP/normal"; NB="$TMP/normal-remote.git"
setup_repo "$N" "$NB"
N_REMOTE_BEFORE="$(remote_oid "$NB")"                 # = c1
git -C "$N" commit -q --allow-empty -m c2
N_HEAD="$(git -C "$N" rev-parse HEAD)"                # непустая публикация: remote должен сдвинуться

pub_n() { ( cd "$N" && bash "$SUT" origin main ); }
n_ref_moved() { local now; now="$(remote_oid "$NB")"; [ "$now" = "$N_HEAD" ] && [ "$now" != "$N_REMOTE_BEFORE" ]; }
# journal_rows <file> <event> — число строк таблицы журнала с этим событием (шапка не считается)
journal_rows() { grep -c "^| [^|]* | $2 |" "$1"; }
n_one_publish() {
  [ "$(journal_rows "$N/docs/ops-journal.md" publish:done)" -eq 1 ] \
  && [ "$(journal_rows "$N/docs/ops-journal.md" publish:failed)" -eq 0 ]
}
n_no_deploy()         { ! grep -q '^| [^|]* | deploy:' "$N/docs/ops-journal.md"; }
n_noop_logged()       { [ "$(journal_rows "$N/docs/ops-journal.md" publish:noop)" -ge 1 ]; }
n_publish_still_one() { [ "$(journal_rows "$N/docs/ops-journal.md" publish:done)" -eq 1 ]; }

t "verify-after-push: обычная публикация → exit 0" 0 pub_n
t_out "verify-after-push: ls-remote подтверждает pushed OID" "verified remote origin/main=$N_HEAD"
t "verify-after-push: remote ref реально сдвинулся на HEAD" 0 n_ref_moved
t "publish-event: непустая публикация пишет ровно одно publish:done (и ни одного failed)" 0 n_one_publish
t "publish-event: публикация НЕ пишет deploy:* (DORA не удваивается)" 0 n_no_deploy

t "noop: publish при remote==HEAD → exit 0" 0 pub_n
t_out "noop: диагностика 'remote already matches HEAD'" "remote already matches HEAD"
t "noop: записан publish:noop" 0 n_noop_logged
t "noop: НЕ раздувает DF — publish:done по-прежнему один" 0 n_publish_still_one

# ── detached HEAD без явного режима → отказ без push; AGENT_PUBLISH_MODE=main — публикует ─────
git -C "$N" checkout -q --detach
git -C "$N" commit -q --allow-empty -m c3
N_DETACHED="$(git -C "$N" rev-parse HEAD)"
t "detached HEAD без AGENT_PUBLISH_MODE → отказ (exit 1)" 1 pub_n
t_out "detached: отказ объясняет выбор режима" 'AGENT_PUBLISH_MODE=main'
t "detached: remote не тронут" 1 test "$(remote_oid "$NB")" = "$N_DETACHED"
pub_n_main() { ( cd "$N" && AGENT_PUBLISH_MODE=main bash "$SUT" origin main ); }
t "AGENT_PUBLISH_MODE=main на detached HEAD → прямая публикация, exit 0" 0 pub_n_main
t "AGENT_PUBLISH_MODE=main: remote = HEAD" 0 test "$(remote_oid "$NB")" = "$N_DETACHED"
bad_mode() { ( cd "$N" && AGENT_PUBLISH_MODE=yolo bash "$SUT" origin main ); }
t "неизвестный AGENT_PUBLISH_MODE → exit 1" 1 bad_mode
git -C "$N" checkout -q -B main

# ── 2. GRACEFUL DEGRADATION (I-8): сбой телеметрии не меняет исход публикации ─────────────────
# ops-log.sh пишет в $ROOT/docs/ops-journal.md; делаем docs обычным файлом → mkdir/append падает.
# Вызов идёт с `|| true`, поэтому push+verify отрабатывают, а publish завершается кодом 0.
D="$TMP/degrade"; DB="$TMP/degrade-remote.git"
setup_repo "$D" "$DB"
D_REMOTE_BEFORE="$(remote_oid "$DB")"                 # = c1
git -C "$D" commit -q --allow-empty -m c2
D_HEAD="$(git -C "$D" rev-parse HEAD)"
printf 'break-ops-log\n' > "$D/docs"                  # docs — файл, не каталог: ops-log падает

pub_d() { ( cd "$D" && bash "$SUT" origin main ); }
d_ref_moved()  { local now; now="$(remote_oid "$DB")"; [ "$now" = "$D_HEAD" ] && [ "$now" != "$D_REMOTE_BEFORE" ]; }
d_no_journal() { [ ! -e "$D/docs/ops-journal.md" ]; }

t "degrade (I-8): публикация успешна несмотря на сломанный ops-log → exit 0" 0 pub_d
t "degrade (I-8): основной исход не тронут — remote сдвинулся на HEAD" 0 d_ref_moved
t "degrade (I-8): телеметрия действительно не записалась (журнал отсутствует)" 0 d_no_journal

# ── 3. EXACT-OID режим: immutable literal push; mismatch → отказ без push ─────────────────────
E="$TMP/exact"; EB="$TMP/exact-remote.git"
setup_repo "$E" "$EB"
E_REMOTE_BEFORE="$(remote_oid "$EB")"                 # = c1
printf 'two\n' > "$E/f.txt"; git -C "$E" add f.txt; git -C "$E" commit -qm two
E_HEAD="$(git -C "$E" rev-parse HEAD)"

pub_e()       { ( cd "$E" && AGENT_PUBLISH_EXPECT_HEAD="$E_HEAD" bash "$SUT" origin main ); }
pub_e_short() { ( cd "$E" && AGENT_PUBLISH_EXPECT_HEAD="${E_HEAD%????????}" bash "$SUT" origin main ); }
e_ref_at_expected() { local now; now="$(remote_oid "$EB")"; [ "$now" = "$E_HEAD" ] && [ "$now" != "$E_REMOTE_BEFORE" ]; }

t "exact: literal-OID публикация → exit 0" 0 pub_e
t_out "exact: single immutable literal-OID refspec" "pushing exact $E_HEAD:refs/heads/main"
t_out_absent "exact: single attempt — ни rebase/retry/дивергенции" "retry [0-9]|rebase|дивергенция"
t "exact: remote сдвинулся ровно на expected OID" 0 e_ref_at_expected

# HEAD уходит вперёд от закреплённого expected → mismatch должен быть отвергнут БЕЗ push.
git -C "$E" commit -q --allow-empty -m drift
E_DRIFT="$(git -C "$E" rev-parse HEAD)"
e_ref_unchanged() { local now; now="$(remote_oid "$EB")"; [ "$now" = "$E_HEAD" ] && [ "$now" != "$E_DRIFT" ]; }

t "exact: HEAD разошёлся с expected OID → отказ (exit 3)" 3 pub_e
t "exact: mismatch не двигает remote (push не выполнялся)" 0 e_ref_unchanged
t "exact: сокращённый (не 40/64-hex) OID отвергается (exit 3)" 3 pub_e_short

harness_exit
