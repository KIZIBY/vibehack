#!/bin/bash
# test-e2e.sh — браузерные e2e-тесты Playwright по критическим маршрутам PROJECT.md §8 (tests/e2e/).
# Зависимости e2e ставит scripts/setup.sh в tests/e2e/ (отдельный package.json).
# Exit: 0 = зелёный или e2e ещё нет (SKIP) · 2 = зависимости не установлены · иначе код Playwright
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"
if ! ls tests/e2e/playwright.config.* >/dev/null 2>&1; then
  echo "SKIP e2e: tests/e2e/playwright.config.* нет (сценарий — задача T090)"
  exit 0
fi
if [ ! -d tests/e2e/node_modules ]; then
  echo "test-e2e: зависимости tests/e2e не установлены — выполни: bash scripts/setup.sh" >&2
  exit 2
fi
cd tests/e2e && npx --no-install playwright test
