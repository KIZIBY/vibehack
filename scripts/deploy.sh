#!/usr/bin/env bash
# deploy.sh — production deploy for the single-VM SQLite installation (T095).
# Required env: DEPLOY_HOST (public IP), TLS_EMAIL (ACME account email), DEPLOY_ENV_FILE.
set -Eeuo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP_NAME:-ai-judge}"
BASE="${DEPLOY_BASE:-/opt/$APP}"
STATE="${DEPLOY_STATE:-/var/lib/$APP}"
ENV_FILE="${DEPLOY_ENV_FILE:-/etc/$APP/$APP.env}"
HOST="${DEPLOY_HOST:-}"
TLS_EMAIL="${TLS_EMAIL:-}"
RELEASE="$(git -C "$ROOT" rev-parse --short=12 HEAD)"
RELEASE_DIR="$BASE/releases/$RELEASE"

die() { echo "deploy: $*" >&2; exit 1; }
trap 'die "failed at line $LINENO"' ERR

[[ "$(id -u)" == 0 ]] || die "запускайте от root"
[[ -n "$HOST" ]] || die "нужен DEPLOY_HOST с публичным IP"
[[ -n "$TLS_EMAIL" ]] || die "нужен TLS_EMAIL для автоматического продления IP-сертификата"
[[ -f "$ENV_FILE" ]] || die "нет $ENV_FILE; создайте его на сервере (см. docs/guides/OPERATIONS_GUIDE.md)"

command -v apt-get >/dev/null || die "поддерживается Debian/Ubuntu с apt-get"
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq python3 python3-venv nginx certbot python3-certbot-nginx curl rsync nodejs npm
command -v npm >/dev/null || die "не удалось установить Node.js/npm"

CERTBOT_CMD="$(command -v certbot)"
if ! "$CERTBOT_CMD" help all 2>&1 | grep -q -- '--ip-address'; then
  CERTBOT_VENV="$BASE/certbot-venv"
  python3 -m venv "$CERTBOT_VENV"
  "$CERTBOT_VENV/bin/python" -m pip install --quiet --upgrade pip certbot certbot-nginx
  CERTBOT_CMD="$CERTBOT_VENV/bin/certbot"
fi

install -d -m 0750 "$BASE/releases" "$STATE/data" "$(dirname "$ENV_FILE")" /etc/systemd/system
install -d -m 0700 "$STATE"

if [[ -e "$RELEASE_DIR" ]]; then rm -rf -- "$RELEASE_DIR"; fi
mkdir -p "$RELEASE_DIR"
rsync -a --delete --exclude '.git' --exclude '.venv' --exclude 'node_modules' "$ROOT/" "$RELEASE_DIR/"

python3 -m venv "$BASE/venv"
"$BASE/venv/bin/python" -m pip install --quiet --upgrade pip
"$BASE/venv/bin/pip" install --quiet -r "$RELEASE_DIR/backend/requirements.txt"
(cd "$RELEASE_DIR/frontend" && npm ci --silent && npm run build)

install -d -m 0750 "$STATE/backups"
if [[ -f "$STATE/judge.db" ]]; then
  cp --preserve=mode,timestamps "$STATE/judge.db" "$STATE/backups/judge-$(date -u +%Y%m%dT%H%M%SZ).db"
fi

cat > /etc/systemd/system/$APP.service <<EOF
[Unit]
Description=AI Judge backend
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$BASE/current
EnvironmentFile=$ENV_FILE
Environment=JUDGE_DATABASE_URL=sqlite:////$STATE/judge.db
Environment=JUDGE_DATA_DIR=$STATE/data
Environment=JUDGE_VERSION=$RELEASE
Environment=JUDGE_COOKIE_SECURE=true
ExecStart=$BASE/venv/bin/uvicorn app.main:app --app-dir $BASE/current/backend --host 127.0.0.1 --port 8000
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=full
ReadWritePaths=$STATE

[Install]
WantedBy=multi-user.target
EOF

ln -sfn "$RELEASE_DIR" "$BASE/current"
JUDGE_DATABASE_URL="sqlite:////$STATE/judge.db" JUDGE_DATA_DIR="$STATE/data" \
  "$BASE/venv/bin/python" -m alembic -c "$BASE/current/backend/alembic.ini" upgrade head

install -d -m 0755 /var/www/$APP /etc/nginx/sites-available /etc/nginx/sites-enabled
cat > /etc/nginx/sites-available/$APP <<EOF
server {
    listen 80;
    server_name $HOST;
    location /.well-known/acme-challenge/ { root /var/www/$APP; }
    location / { return 301 https://\$host\$request_uri; }
}
EOF
ln -sfn /etc/nginx/sites-available/$APP /etc/nginx/sites-enabled/$APP
rm -f /etc/nginx/sites-enabled/default
nginx -t
systemctl enable --now nginx
systemctl reload nginx

"$CERTBOT_CMD" certonly --webroot -w /var/www/$APP --ip-address "$HOST" \
  --preferred-profile shortlived --email "$TLS_EMAIL" \
  --agree-tos --non-interactive --keep-until-expiring

cat > /etc/nginx/sites-available/$APP <<EOF
server {
    listen 80;
    server_name $HOST;
    location /.well-known/acme-challenge/ { root /var/www/$APP; }
    location / { return 301 https://\$host\$request_uri; }
}
server {
    listen 443 ssl http2;
    server_name $HOST;
    ssl_certificate /etc/letsencrypt/live/$HOST/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$HOST/privkey.pem;
    root $BASE/current/frontend/dist;
    client_max_body_size 50m;
    location /api/ {
        proxy_pass http://127.0.0.1:8000;
        proxy_set_header Host \$host;
        proxy_set_header X-Forwarded-Proto \$scheme;
        proxy_set_header X-Request-ID \$request_id;
        proxy_read_timeout 600s;
        proxy_buffering off;
    }
    location = /health { proxy_pass http://127.0.0.1:8000/health; }
    location / { try_files \$uri \$uri/ /index.html; }
}
EOF

nginx -t
systemctl daemon-reload
systemctl enable --now "$APP"
systemctl restart "$APP"
curl --fail --silent --show-error --max-time 10 https://$HOST/health >/dev/null
curl --fail --silent --show-error --max-time 10 https://$HOST/ >/dev/null

if [[ -x "$ROOT/scripts/ops-log.sh" ]]; then
  "$ROOT/scripts/ops-log.sh" deploy:done "sha=$RELEASE scope=$APP host=$HOST"
fi
echo "deploy: OK $RELEASE https://$HOST"
