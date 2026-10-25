#!/usr/bin/env bash
# telemetry.sh — hook Claude Code на все события (async): сырой лог действий агентов для метрик.
# Логика — scripts/telemetry.py hook; здесь только мост. Exit 0 всегда: телеметрия не блокирует
# сессию (I-8). Отключить на время: HARNESS_TELEMETRY=0.
[ "${HARNESS_TELEMETRY:-1}" = "0" ] && exit 0
python3 "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/scripts/telemetry.py" hook 2>/dev/null || true
exit 0
