#!/bin/bash
# check.sh — единая точка проверок проекта: её запускают агенты и люди перед коммитом и публикацией
# (scripts/agent-publish-main.sh в PR-режиме вызывает её сам на перенесённых коммитах).
#
# Usage: bash scripts/check.sh
# Exit:  0 = все проверки зелёные · ≠0 = первая упавшая проверка (её код возврата).
#
# Состав:
#   1. self-test сьют харнесса (`bash tests/harness/run-tests.sh --tier fast`) — если каталог
#      tests/harness/ есть. Проект, скопировавший харнесс без self-tests, получает одну строку SKIP.
#   2. Проверки проекта — блок «ПРОВЕРКИ ПРОЕКТА» ниже: lint / типы / unit-тесты из
#      PROJECT.md §3 «Команды». Пока блок пуст, check.sh честно говорит об этом (NOTE), а не
#      изображает зелёные тесты продукта.
#
# Это bash-wrapper (shebang /bin/bash), поэтому он годится и как RED/GREEN-команда формального
# /pipeline (контракт исполнения — PROJECT.md §3).
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || { echo "check: FATAL: корень репозитория недоступен" >&2; exit 2; }

step() { printf 'check: ── %s ──\n' "$1"; }

# ── 1. self-test сьют харнесса ────────────────────────────────────────────────────────────────
if [ -f tests/harness/run-tests.sh ]; then
  step "self-test харнесса (tests/harness, tier fast)"
  bash tests/harness/run-tests.sh --tier fast || {
    rc=$?
    echo "check: FAIL — self-test харнесса красный (exit $rc)" >&2
    exit "$rc"
  }
else
  echo "check: SKIP self-test харнесса — каталога tests/harness/ нет"
fi

# ── 2. ПРОВЕРКИ ПРОЕКТА ───────────────────────────────────────────────────────────────────────
# Впиши сюда команды из PROJECT.md §3 «Команды» (линт, проверка типов, unit-тесты) и поставь
# PROJECT_CHECKS=1. Каждая команда должна завершаться ненулевым кодом при провале, например:
#
#   step "lint";       npm run lint                || exit $?
#   step "unit-тесты"; bash scripts/test-unit.sh   || exit $?
#
PROJECT_CHECKS=0
# --- начало блока проекта ---

# --- конец блока проекта ---
if [ "$PROJECT_CHECKS" -eq 0 ]; then
  echo "check: NOTE проверки проекта не настроены — заполни блок «ПРОВЕРКИ ПРОЕКТА» в scripts/check.sh (PROJECT.md §3)"
fi

echo "check: OK"
exit 0
