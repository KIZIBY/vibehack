# Constitution audit — AI-судья

Дата аудита: 2026-10-25. Вход: `specs/001-ai-judge-platform/spec.md`, `plan.md`,
`tasks.md`, текущий checkout и результат `bash scripts/plan-lint.sh specs/001-ai-judge-platform`.

| Инвариант | Severity | Вердикт | Обоснование |
|---|---|---|---|
| I-1 Data Sovereignty & Deployment Model | MUST | NEEDS-INFO | Периметр задан в уставе, но production deployment ещё не выкатан. |
| I-2 Data is Sacred | MUST | PASS | В спеке есть retention/soft-delete требования; миграции и storage покрыты задачами A. |
| I-3 Audit Immutability | MUST | NEEDS-INFO | Контракты журнала есть, но полный runtime-путь backend/Hermes ещё не собран. |
| I-4 Clean Architecture | MUST | PASS | План разделяет router/service/repository, intake — отдельный процесс, frontend — API. |
| I-5 Tenant/Access Isolation | MUST | PASS | Для общего demo-account устав явно фиксирует N/A; fail-closed остаётся требованием backend. |
| I-6 Frozen Contracts | MUST | PASS | `plan-lint` и contract tests включены в проектные проверки; контракты versioned. |
| I-7 Security by Default | MUST | NEEDS-INFO | Intake guards добавлены, но полный auth/RBAC backend ещё не закрыт. |
| I-8 Graceful Degradation | MUST | NEEDS-INFO | Fallback intake реализован, но отказ Hermes/backend не проверен сквозным тестом. |
| I-9 Observability | MUST | NEEDS-INFO | Структурные логи и request_id запланированы, end-to-end ingest ещё не проверен. |
| I-10 Deploy Safety | MUST | NEEDS-INFO | `scripts/deploy.sh` и rollback отсутствуют; это отдельная T095. |
| I-11 Production-Ready by Default | MUST | FLAG | Локальный `check.sh` остаётся красным на 12 harness-case из-за несовместимости git worktree/context ledger. |
| I-12 Root-Cause Discipline | MUST | PASS | Для intake security-кейсов добавлены воспроизводимые guards/tests; production bug flow задан каноном. |
| I-13 Zero-Trust Verification | MUST | PASS | Все закрытые intake-задачи имеют локальные smoke/compile evidence; полный e2e ещё NEEDS-INFO. |
| I-14 Code Speaks, Not Comments | MUST | PASS | Новые intake-модули имеют исполняемые проверки и не используют комментарии вместо поведения. |
| I-15 Data Integrity Under Concurrency | MUST | NEEDS-INFO | Keyset и optimistic concurrency описаны, но сквозной runtime ещё не завершён. |
| I-16 Requirements Traceability | MUST | PASS | `plan-lint`: 44/44 требований адресованы, overreach = 0. |
| I-17 Convention → Executable Path | MUST | PASS | Проверки подключены через `scripts/check.sh`, `test-unit.sh`, hooks и plan-lint. |

## Evidence

```text
plan-lint: traceability: все 44 требований из spec.md адресованы в плане
plan-lint: coherence: plan-декларации согласованы со spec.md (0 overreach)
plan-lint: OK (specs/001-ai-judge-platform/plan.md)
```

Итог: `MUST-FLAG: 1 · SHOULD-FLAG: 0 · NEEDS-INFO: 8`. T097 не утверждает production
readiness; открытые MUST-пункты переданы в T090/T094/T095 и backend-интеграцию.
