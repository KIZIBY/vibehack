#!/usr/bin/env bash
# spike_live.sh — живой замер спайков T001 (R3/R4) и T003 (R6) на поднятом Hermes. Запускает ЧЕЛОВЕК.
# Нужно: Hermes развёрнут (bash hermes/deploy.sh), вход в OpenAI по подписке выполнен (`hermes model` →
# openai-codex), в окружении HERMES_API_URL и API_SERVER_KEY. Результат — вывод для research.md,
# раздел «Результаты спайков» (чек-лист там же).
# Usage: bash hermes/scripts/spike_live.sh [целевой URL хоста для браузера]
set -uo pipefail
cd "$(dirname "$0")/../.."
: "${HERMES_API_URL:?задай HERMES_API_URL (например http://127.0.0.1:8642)}"
: "${API_SERVER_KEY:?задай API_SERVER_KEY (из hermes/.env)}"
PY=".venv/bin/python"; [ -x "$PY" ] || PY="python3"
echo "== T001: 5 параллельных запусков роли code (R4) и блокировка терминала (R3) =="
"$PY" hermes/scripts/spike_hermes.py --gateway-url "$HERMES_API_URL" --api-key "$API_SERVER_KEY" --concurrency 5
echo
echo "== T003: браузер дизайнера (R6) =="
"$PY" hermes/scripts/spike_browser.py --concurrency 3 --target-url "${1:-http://127.0.0.1:5173}"
echo
echo "Память контейнера во время замера снимай отдельно: docker stats --no-stream hermes"
