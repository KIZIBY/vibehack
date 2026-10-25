#!/usr/bin/env bash
# tests/harness/cases/spec-plan-lint.sh — spec-lint + plan-lint exit-контракты. Инварианты: I-17, I-6.
#
# Поведенческий контракт двух детерминированных сенсоров этапов требований/плана:
#   spec-lint.sh  — 0 OK (warn допустимы) · 1 нет REQUIRED-секции / пустой Auth&Access /
#                   >3 маркеров NEEDS CLARIFICATION · 2 spec.md не найден
#   plan-lint.sh  — 0 OK · 1 нет REQUIRED-секции / осиротевшее FR/NFR · 2 файлы не найдены
# Проверяем ТОЛЬКО коды возврата (+ по одному структурному t_out на сенсор, подтверждающему,
# что сработало нужное правило) — не прозу сообщений. Осиротевшую пару и missing-file строим
# герметично под $TMP; валидные фикстуры берём из $FIX.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "spec-lint · plan-lint (exit-контракты)"

SPEC_LINT="$ROOT/scripts/spec-lint.sh"
PLAN_LINT="$ROOT/scripts/plan-lint.sh"

# ── герметичные фикстуры под $TMP ──
# empty/ — каталог без spec.md/plan.md: оба сенсора обязаны вернуть 2 (файлы не найдены).
mkdir -p "$TMP/empty"

# good-pair/ — валидная пара spec+plan (plan-lint читает SPEC_DIR целиком).
mkdir -p "$TMP/good-pair"
cp "$FIX/good-spec.md" "$TMP/good-pair/spec.md"
cp "$FIX/good-plan.md" "$TMP/good-pair/plan.md"

# orphan/ — spec декларирует FR-001, а plan (со всеми REQUIRED-секциями) его не адресует и
# tasks.md нет: единственная причина провала — осиротевшее требование (traceability), не секция.
mkdir -p "$TMP/orphan"
cat > "$TMP/orphan/spec.md" <<'SPEC'
# Feature: Orphan

## Functional Requirements
FR-001: Нечто важное, не упомянутое в плане.
SPEC
cat > "$TMP/orphan/plan.md" <<'PLAN'
# Implementation Plan: Orphan

## Technical Approach
Подход без единого упоминания требования.

## Implementation Steps
1. Один шаг.

## Known Risks
- Один риск.
PLAN

# ── spec-lint: exit-контракты ──
t "spec-lint: валидная спека → 0"                 0 bash "$SPEC_LINT" "$FIX/good-spec.md"
t "spec-lint: нет REQUIRED / пустой Auth / >3 NC → 1" 1 bash "$SPEC_LINT" "$FIX/bad-spec.md"
t "spec-lint: spec.md не найден → 2"              2 bash "$SPEC_LINT" "$TMP/empty"

# vague-nfr: все REQUIRED-секции на месте (exit 0), но NFR-секция без чисел → сработала
# heuristic-warn квантификации (warn не меняет код) — подтверждаем структурным t_out.
t "spec-lint: NFR без чисел — warn, не гейт → 0"  0 bash "$SPEC_LINT" "$FIX/vague-nfr-spec.md"
t_out "spec-lint: сработало правило NFR-квантификации" 'warn.*NFR-секция без единого числа'

# ── plan-lint: exit-контракты ──
t "plan-lint: валидная пара spec+plan → 0"        0 bash "$PLAN_LINT" "$TMP/good-pair"
t "plan-lint: осиротевшее FR (нет следа в плане) → 1" 1 bash "$PLAN_LINT" "$TMP/orphan"
t_out "plan-lint: сработало правило traceability (FR-001)" 'осиротевшие требования.*FR-001'
t "plan-lint: файлы не найдены → 2"               2 bash "$PLAN_LINT" "$TMP/empty"

harness_exit
