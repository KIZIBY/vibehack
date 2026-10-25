#!/usr/bin/env bash
# telemetry.sh — CLI телеметрии агентов: задачи с прогнозом, MAST, правила, эвалы, статус, отчёт.
# Вся логика — scripts/telemetry.py (python3, только stdlib). Метрики и источники —
# docs/telemetry.md. Usage: bash scripts/telemetry.sh task|log|status|report …
exec python3 "$(cd "$(dirname "$0")" && pwd)/telemetry.py" "$@"
