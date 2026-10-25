#!/usr/bin/env bash
# rollback.sh — switch production to the previous release and verify it (T095).
set -Eeuo pipefail
APP="${APP_NAME:-ai-judge}"
BASE="${DEPLOY_BASE:-/opt/$APP}"
HOST="${DEPLOY_HOST:-}"
CURRENT="$(readlink -f "$BASE/current" 2>/dev/null || true)"
die() { echo "rollback: $*" >&2; exit 1; }
[[ "$(id -u)" == 0 ]] || die "запускайте от root"
[[ -n "$HOST" ]] || die "нужен DEPLOY_HOST"
[[ -n "$CURRENT" ]] || die "current release не найден"
mapfile -t releases < <(find "$BASE/releases" -mindepth 1 -maxdepth 1 -type d -printf '%T@ %p\n' | sort -nr | awk '{print $2}')
previous=""
for release in "${releases[@]}"; do
  [[ "$release" != "$CURRENT" ]] && { previous="$release"; break; }
done
[[ -n "$previous" ]] || die "предыдущий release не найден"
ln -sfn "$previous" "$BASE/current"
systemctl restart "$APP"
curl --fail --silent --show-error --max-time 10 --resolve "$HOST:443:127.0.0.1" "https://$HOST/health" >/dev/null
curl --fail --silent --show-error --max-time 10 --resolve "$HOST:443:127.0.0.1" "https://$HOST/" >/dev/null
if [[ -x "$(dirname "$0")/ops-log.sh" ]]; then
  "$(dirname "$0")/ops-log.sh" deploy:done "rollback=$previous scope=$APP host=$HOST"
fi
echo "rollback: OK $(basename "$previous")"
