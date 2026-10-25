# Implementation Plan: Экспорт отчётов

## Technical Approach
Экспорт реализуем в report-service (FR-001); замер latency по NFR-001 на стейдже.

## Implementation Steps
1. Endpoint экспорта PDF (FR-001)
2. Нагрузочный замер p95 экспорта (NFR-001)

## Units of Work
- export-endpoint — report-service — depends-on: нет — check: `bash scripts/check.sh`

## Known Risks
- Большие отчёты (>100 стр) — стриминг.
