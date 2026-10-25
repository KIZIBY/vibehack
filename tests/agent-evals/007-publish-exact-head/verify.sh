#!/usr/bin/env bash
# Скрытый судья: origin/main стоит РОВНО на ожидаемом OID.
set -uo pipefail
exp="$(cat .expected-oid 2>/dev/null)" || exit 1
[ -n "$exp" ] || exit 1
[ "$(git --git-dir=.origin.git rev-parse refs/heads/main 2>/dev/null)" = "$exp" ] || exit 1
exit 0
