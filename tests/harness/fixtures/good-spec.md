# Feature: Экспорт отчётов

## Overview
Экспорт отчётов в PDF.

## User Stories
- Как аналитик, я хочу экспортировать отчёт.

## Functional Requirements (нумерованный список)
FR-001: Экспорт в PDF.

## Non-Functional Requirements
NFR-001: Экспорт ≤5 сек.

## Authentication & Access (обязательна; docs/guides/AUTH_GUIDE.md §3 — или явное «N/A»)
Вход по модели из PROJECT.md §6; доступ к экспорту — роли analyst/admin.

## Edge Cases
- Пустой отчёт: заглушка.

## Out of Scope
- Экспорт в DOCX.

## Affected Services (список затронутых сервисов/модулей)
- report-service
