#!/bin/bash
# deploy.sh — выкатывает Hermes Agent с обвесом ai-judge: тянет образ, сливает config.yaml,
# кладёт SOUL.md и пересоздаёт контейнер (плагин и навык подключены томами из этого каталога).
#
# Usage: bash hermes/deploy.sh
# Env:   HERMES_DATA_DIR — данные Hermes на хосте (по умолчанию ~/.hermes)
#        HERMES_VERSION  — тег образа (по умолчанию — из docker-compose.yml)
# Exit:  0 = контейнер поднят · 1 = нет ~/.hermes/.env (сначала мастер setup) · иное — ошибка docker
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
export HERMES_DATA_DIR="${HERMES_DATA_DIR:-$HOME/.hermes}"
cd "$HERE"

docker compose pull
# Каталог данных принадлежит uid hermes (10000) — проверяем и пишем изнутри контейнера.
in_container() { docker compose run --rm --no-deps -v "$HERE:/overlay:ro" --entrypoint "$1" hermes "${@:2}"; }

if ! in_container test -f /opt/data/.env; then
  echo "deploy: нет $HERMES_DATA_DIR/.env — сначала мастер настройки (ключи провайдера, мессенджер):" >&2
  echo "deploy:   mkdir -p $HERMES_DATA_DIR && cd $HERE && docker compose run --rm hermes setup" >&2
  exit 1
fi

in_container python3 /overlay/scripts/apply_overlay.py /overlay/config /opt/data
docker compose up -d --force-recreate --remove-orphans
docker compose ps
echo "deploy: логи — cd $HERE && docker compose logs -f"
