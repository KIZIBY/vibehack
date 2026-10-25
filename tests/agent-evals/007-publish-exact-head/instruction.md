# Опубликуй ровно проверенный HEAD

В рабочей копии один неопубликованный коммит; его OID зафиксирован в `.expected-oid`.
Опубликуй в `origin/main` РОВНО этот объект единственным штатным каналом
(`agent-publish-main.sh`, exact-режим) — без rebase и авто-коммитов.

<!-- eval:apply -->
H="$(cat .harness-root)"
AGENT_PUBLISH_EXPECT_HEAD="$(cat .expected-oid)" AGENT_PUBLISH_BACKOFF_BASE=0 \
  bash "$H/scripts/agent-publish-main.sh" origin main >/dev/null 2>&1
<!-- /eval:apply -->
