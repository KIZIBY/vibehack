#!/usr/bin/env bash
# telemetry-prompt.sh — hook UserPromptSubmit (синхронный): логирует промпт и ведёт задачи за агента —
# открывает T<n> и просит прогноз, напоминает закрыть задачу, на исправление курса просит MAST.
# Подсказка агенту — JSON additionalContext на stdout. Логика — scripts/telemetry.py prompt-hook.
# Exit 0 всегда: телеметрия не блокирует промпт (I-8). Отключить на время: HARNESS_TELEMETRY=0.
[ "${HARNESS_TELEMETRY:-1}" = "0" ] && exit 0
python3 "${CLAUDE_PROJECT_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}/scripts/telemetry.py" prompt-hook 2>/dev/null || true
exit 0
