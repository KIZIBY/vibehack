# Implementation Plan: AI-судья

Спека: `spec.md` · данные: `data-model.md` · контракты: `contracts/` · исследование: `research.md` ·
задачи: `tasks.md` · дизайн-док: `docs/design-doc.md`. Решения владельца — `spec.md` → Clarifications.

## Technical Approach

### Technical Context
- Стек и структура (`PROJECT.md §2`): backend `backend/` — Python 3.12 + FastAPI, SQLite → Postgres,
  Alembic; intake `intake/` — Python-пакет, запускается подпроцессом; агенты `hermes/` — Hermes Agent
  v0.22.5 (плагин `ai-judge`, навыки ролей); frontend `frontend/` — React + Vite + Tailwind; материалы —
  общий том `JUDGE_DATA_DIR`, он же `/opt/data/workspaces` в контейнере Hermes.
- Команды проверки (`PROJECT.md §3`): `scripts/lint.sh`, `scripts/test-unit.sh [backend|intake|hermes|frontend|all]`,
  `scripts/test-integration.sh`, `scripts/test-e2e.sh`, общая проверка — `scripts/check.sh`. Скрипты создаёт T010.
- Окружения (`PROJECT.md §4`): local (UI :5173, API :8000); staging нет; production — VPS за TLS (URL
  заполнит владелец при T095).
- Модель: OpenAI через Hermes по подписке (`hermes model`), агенты параллельно; запасной путь — ключ API.

### Architecture Decisions
1. **Четыре зоны с замороженными контрактами** (A backend, B intake, C агенты, D frontend), каждая
   тестируется без остальных благодаря дублёрам: `FakeAgentGateway`, готовые описи, CLI intake,
   `run_role.sh`, MSW. Это условие параллельной работы четырёх сессий (устав I-15). — FR-001…FR-031
2. **Оркестрирует backend, не агент-диспетчер**: детерминированные повторы, таймауты и частичный
   результат; `delegate_task` — только внутри роли. — FR-014, FR-024, NFR-005
3. **Запуск ролей через `POST /v1/runs`**, результат — файлы, которые роль создаёт инструментами
   плагина и которые backend повторно проверяет по схеме (`research.md` R1, R2). — FR-020, NFR-008, NFR-009
4. **Итог считает одна функция** `compute_score`, backend подключает её тонким загрузчиком (R8, устав
   I-4). — FR-021, FR-025
5. **Intake — отдельный процесс с лимитами**: парсеры форматов — самая рискованная поверхность (R7).
   — FR-012, FR-013, NFR-011
6. **Код участников не исполняется**; инструменты ролей ограничены, способ — по результату T001 (R3). —
   FR-015, FR-022, NFR-010
7. **Сравнение работ между собой — вычисление в intake**, роль `critic-uniqueness` интерпретирует
   результат (R9). — FR-018
8. **Общий демо-аккаунт, сессия в cookie** (решение владельца, отклонение от AUTH_GUIDE §1,
   зафиксировано в спеке). — Authentication & Access
9. **Срок хранения материалов 7 дней, очистка фоновой задачей** (R10, устав I-1/I-2). — FR-031, NFR-013
10. **Прогресс через SSE**, состояние восстанавливается GET (R11). — FR-014

## Components Affected

| Module/Service | Changes | New Files | Migrations |
|---|---|---|---|
| `backend/` | API, оркестратор, подсчёт, журнал, очистка | `backend/app/**`, `tests/backend/**` | 0001 (T012) |
| `intake/` | распаковка, извлечение, опись, сравнение работ | `intake/**`, `tests/intake/**` | нет |
| `hermes/` | инструменты отчётов, журнал, защита ролей, 7 навыков, конфиг | `hermes/plugins/ai-judge/*`, `hermes/skills/ai-judge-*/`, `hermes/evals/` | нет |
| `frontend/` | оболочка, чат, рубрика, решения, прогресс, таблица, журнал | `frontend/**` | нет |
| `scripts/`, корень | команды `PROJECT.md §3`, проверки, окружение | `scripts/{setup,build,lint,test-*,dev,migrate,deploy,rollback}.sh`, `.env.example` | нет |
| `tests/` | контракты, фикстуры, e2e | `tests/contracts/`, `tests/fixtures/**`, `tests/e2e/` | нет |

## Implementation Steps

1. **Contracts** — `contracts/*` уже написаны и валидны; T011 замораживает их тестом.
2. **Data** — миграция 0001 по `data-model.md` с триггерами запрета UPDATE/DELETE журнала (T012).
3. **Domain/services** — зона A (T022–T029, T032–T034, T036–T038), зона B (T040–T050), зона C (T060–T068).
4. **Interfaces/handlers** — REST и SSE зоны A (T021, T023–T025, T027, T030, T034, T035), CLI intake (T040),
   инструменты плагина и хуки (T060–T062).
5. **UI** — зона D (T080–T089).
6. **Tests & e2e** — RED→GREEN на каждую задачу; сквозной сценарий T090, браузерная приёмка T093,
   измерения T091–T092, устойчивость T094.

Порядок: спайки (T001–T003) → фундамент (T010–T014, одна сессия) → четыре зоны параллельно → сборка
(T090–T097). Подробности запуска сессий — `tasks.md`.

## Units of Work

- unit-foundation (T010–T014): каркас, команды, контракты-тест, миграция, фикстуры. Границы: корень,
  `scripts/`, `tests/contracts`, `tests/fixtures`, `backend/migrations`. Зависимостей нет. Сходимость:
  `bash scripts/check.sh`.
- unit-backend (T020–T038): `backend/**`, `tests/backend/**`. Зависит от unit-foundation. Сходимость:
  `bash scripts/test-unit.sh backend`.
- unit-intake (T040–T052): `intake/**`, `tests/intake/**`, `tests/fixtures/submissions/**`. Зависит от
  unit-foundation. Сходимость: `bash scripts/test-unit.sh intake`.
- unit-agents (T060–T072): `hermes/**`. Зависит от unit-foundation (схемы, фикстуры) и спайка T001.
  Сходимость: `bash scripts/test-unit.sh hermes`.
- unit-frontend (T080–T089): `frontend/**`. Зависит от unit-foundation (OpenAPI). Сходимость:
  `bash scripts/test-unit.sh frontend`.
- unit-integration (T090–T097): `tests/e2e/`, `scripts/deploy.sh`, `docs/`. Зависит от всех зон.
  Сходимость: `bash scripts/test-e2e.sh` и `bash scripts/check.sh`.

## Files to Create/Modify

- Создаются: `backend/app/**`, `backend/migrations/**`, `intake/**`, `frontend/**`,
  `hermes/plugins/ai-judge/{reports,journal,guard}.py`, `hermes/skills/ai-judge-{rubric,sorter,code,business,design,critic-uniqueness,critic-honesty}/SKILL.md`,
  `hermes/evals/**`, `hermes/scripts/run_role.sh`, `scripts/{setup,build,lint,test-unit,test-integration,test-e2e,dev,migrate,deploy,rollback}.sh`,
  `tests/{contracts,fixtures,backend,intake,e2e}/**`, `.env.example`, `docs/demo.md`.
- Меняются: `scripts/check.sh` (блок проекта), `hermes/docker-compose.yml`, `hermes/config/{config.yaml,SOUL.md}`,
  `hermes/plugins/ai-judge/{__init__,schemas,tools}.py`, `hermes/deploy.sh`, `hermes/README.md`,
  `docs/guides/OPERATIONS_GUIDE.md`, `PROJECT.md` (URL production).

## Contract Changes

Новые поверхности, первая версия (`schema_version: "1"`, `/api/v1`): REST и SSE (`contracts/openapi.yaml`),
`inventory`, `similarity`, `agent-report`, `journal-event`, протокол запуска роли (`contracts/agent-run.md`).
Обратная совместимость: поверхностей прошлых версий нет; `judge_score` и `compute_score` остаются без
изменений (устав I-6). Любая правка после T011 — по `contracts/README.md`.

## Data Migrations

Одна миграция 0001 (создание всех таблиц) с обратной `down` (T012). Данных для переноса нет. Бэкап БД
перед миграцией на VPS — шаг `scripts/deploy.sh` (T095). Срок хранения материалов удаляет файлы, но
не записи (устав I-2).

## Requirement Coverage

- FR-001: T023 T080 T083
- FR-002: T024 T080 T084
- FR-003: T023 T083
- FR-004: T025 T043 T084
- FR-005: T027 T085
- FR-006: T027 T063 T085
- FR-007: T027 T085
- FR-008: T037 T050 T089
- FR-009: T038
- FR-010: T023 T083
- FR-011: T030 T086
- FR-012: T040 T042 T043 T046 T048 T063
- FR-013: T045 T048 T086
- FR-014: T032 T035 T087
- FR-015: T044 T064
- FR-016: T065
- FR-017: T032 T066
- FR-018: T044 T049 T067
- FR-019: T068
- FR-020: T028 T060
- FR-021: T029
- FR-022: T028 T062 T072
- FR-023: T028
- FR-024: T032 T087
- FR-025: T029 T088
- FR-026: T029 T088
- FR-027: T034 T089
- FR-028: T036 T089
- FR-029: T033 T061 T089
- FR-030: T033
- FR-031: T036 T089
- NFR-001: T032 T052 T092 — p95 одной работы ≤ 10 мин — журнал прогонов на демо-наборе (T092)
- NFR-002: T032 T092 — 20 работ ≤ 30 мин — журнал прогонов (T092)
- NFR-003: T025 T092 — загрузка ≤ 2 с, таблица 200×15 ≤ 2 с — замер в браузере (T092)
- NFR-004: T092 — 200 работ, 30 критериев — сгенерированный набор (T092)
- NFR-005: T026 T032 T094 — внедрённый сбой роли не роняет оценку — тест оркестратора (T032) и chaos (T094)
- NFR-006: T071 T091 — разброс ≤ 1 пункта в ≥ 80% критериев по 3 прогонам — стенд (T071), прогон (T091)
- NFR-007: T071 T091 — Спирмен ≥ 0,6 и топ-3 — стенд на золотом наборе (T091)
- NFR-008: T020 T033 T061 — 100% вызовов в журнале — сверка числа вызовов и записей (T033)
- NFR-009: T033 — токены и стоимость только из `usage`, иначе null — тест журнала (T033)
- NFR-010: T062 T072 T091 — сдвиг ≤ 1 пункта на 5 злых работах — стенд (T072, T091)
- NFR-011: T025 T031 T041 T045 T094 — вредные входы отклонены — тесты T041, T051, chaos (T094)
- NFR-012: T047 T061 T094 — подложенные ключи замаскированы — тесты T047, T094
- NFR-013: T036 T094 — после срока на томе 0 файлов — тест T036, проверка T094

## Known Risks

| Риск | Вероятность / влияние | Что делаем |
|---|---|---|
| Лимиты подписки OpenAI не тянут параллельность | средняя / высокое | Спайк T001; запасной путь — ключ API; `JUDGE_MAX_PARALLEL_SUBMISSIONS` |
| Инструменты роли нельзя ограничить на уровне шлюза | средняя / высокое | Профили или хук (R3); тест «роль `code` не вызывает терминал» блокирует релиз |
| Нет распознавания речи без ключа API | средняя / среднее | Спайк T002; запасной путь — только кадры + `vision_analyze` с пометкой в описи |
| Headless-браузер не работает в образе Hermes | средняя / среднее | Спайк T003; запасной путь — скриншоты из отдельного контейнера Playwright |
| Разброс оценок моделей | высокая / высокое | Якоря шкалы, фиксированные метрики UX, формула итога, замер NFR-006 (T071) |
| Ложные срабатывания плагиата | средняя / среднее | Флаги без автоштрафа, калибровка порогов на золотом наборе (T091) |
| Конфликты при работе четырёх сессий | средняя / среднее | Замороженные контракты, lease по путям зоны, один merge за раз, зоны не пересекаются по файлам |
| Общий демо-аккаунт слабее обычной модели доступа | средняя / среднее | Пароль только из окружения, ограничение попыток, TLS на VPS; наружу как продукт не выставлять (Out of Scope) |
| Данные участников уходят в OpenAI | подтверждено владельцем | Устав I-1; предупреждение в положении; срок хранения 7 дней |

## Dependencies

- Внешние системы (`PROJECT.md §2`): OpenAI через Hermes; публичный интернет (поиск, хосты команд);
  git-хостинги. Провайдер входа продукта — нет (`PROJECT.md §6`).
- Образ `nousresearch/hermes-agent:v0.22.5` (тег закреплён в `hermes/docker-compose.yml`).
- Бинарные зависимости: `git`, `ffmpeg`, headless-браузер (T003), LibreOffice или аналог для рендера
  слайдов PPTX (выбор — в T043).
