# backend/ — зона A

REST API и оркестратор оценки (Python + FastAPI). Задачи — `specs/001-ai-judge-platform/tasks.md`
T020–T038, контракт — `specs/001-ai-judge-platform/contracts/openapi.yaml`.
Тесты — `tests/backend/`, запуск: `bash scripts/test-unit.sh backend`.

## Ограничения демо-режима

- Запускать **одним воркером** (`uvicorn app.main:app`, без `--workers`): отзыв сессий при выходе и лимит
  попыток входа хранятся в памяти процесса. После перезапуска отозванная cookie снова действует до конца
  срока (12 ч); смена `JUDGE_SESSION_SECRET` отзывает все сессии. Для нескольких воркеров нужно общее
  хранилище (B-015).
- Роуты с записью в БД подключают сессию как `SessionDep` из `app.db` (commit до отправки ответа), а не
  `Depends(get_session)`.
