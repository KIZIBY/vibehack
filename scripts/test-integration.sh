#!/bin/bash
# test-integration.sh — интеграционные тесты: backend + intake + fake-шлюз агентов (tests/integration/).
# Exit: 0 = зелёный или тестов нет (SKIP) · 1 = красный · 2 = нет pytest при наличии тестов
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"
run_pytest integration tests/integration
