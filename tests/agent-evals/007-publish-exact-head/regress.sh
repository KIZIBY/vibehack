#!/usr/bin/env bash
# PASS→PASS страж: повторная публикация — чистый no-op (remote==HEAD, ref недвижим).
set -uo pipefail
H="$(cat .harness-root)"
before="$(git --git-dir=.origin.git rev-parse refs/heads/main)"
AGENT_PUBLISH_EXPECT_HEAD="$(cat .expected-oid)" AGENT_PUBLISH_BACKOFF_BASE=0 \
  bash "$H/scripts/agent-publish-main.sh" origin main >/dev/null 2>&1 || exit 1
[ "$(git --git-dir=.origin.git rev-parse refs/heads/main)" = "$before" ] || exit 1
exit 0
