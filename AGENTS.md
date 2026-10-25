# AGENTS.md — операционный контракт агентов проекта

> Контракт [agents.md](https://agents.md) для любого агента (Claude Code, Codex, Cursor и др.) и для
> человека. Здесь только неочевидные правила, подробности — по ссылкам. Паспорт — `PROJECT.md`,
> команда агентов — `agents/README.md`, Claude Code — `CLAUDE.md`. При конфликте прав устав
> `docs/constitution.md`.

## Проект

Начни с `PROJECT.md`: стек §2, команды §3, окружения §4, тестовые пользователи §5, трекер §7, UI §8.
`ЗАПОЛНИ` — спроси владельца, не угадывай; `-` — осознанно не применимо.

## Setup и проверки

- Сборка, тесты, запуск, деплой — только командами из `PROJECT.md §3`.
- Перед каждым коммитом — `bash scripts/check.sh`; красный `check.sh` = коммита нет.
- Один раз на клон — `bash scripts/install-git-hooks.sh` (pre-commit: секреты, append-only журналы).

## Правила контента

- Append-only, только штатными скриптами: `docs/ops-journal.md`, `specs/*/audit.md` и changelog'и
  спеки, `agents/memory/`. Pre-commit блокирует правку прошлых строк.
- Generated-файлы руками не правятся — только генератором (`docs/*-dashboard.html`,
  `tests/agent-evals/last-run.json`).
- Поведение роли правится только в каноне `agents/roles/*.md`; стабы `.claude/agents/*.md` тонкие.
- Устав — только versioned-поправкой; `docs/pipeline-rules.md` — только записи, подтверждённые
  владельцем (дата + источник). Строку `ISSUE_BACKEND=` в `PROJECT.md` читают скрипты — формат не менять.

## Публикация

- `bash scripts/agent-publish-main.sh`: на ветке — PR (merge жмёт человек), на `main` или с
  `AGENT_PUBLISH_MODE=main` — прямо в main. Подробно — `docs/guides/GIT_PUBLISH_RUNBOOK.md`.
- Нельзя: ручной `git push … main`, `git commit --no-verify`, `git push --force` без `--force-with-lease`.
- Коммиты `feat|fix|docs|chore(scope): …`; коммит агента — с трейлером `Co-Authored-By` (по нему
  считается автономия); дозаписи `docs/ops-journal.md` — отдельным коммитом.

## Секреты и приватность

- Секреты — только env/secret-store. Ни секретов, ни путей машины (`/Users/…`, `/home/…`), ни
  персональных данных, ни приватных адресов — в коде, журналах, тикетах, памяти и отчётах; в репо —
  только имена переменных (`PROJECT.md §5/§6`). Периметр данных продукта — инвариант I-1 устава.

## Как вести работу

- **По умолчанию — `/ship`** (`.claude/commands/ship.md`): задача и прогноз → тест первым от
  отдельного агента → код до GREEN без правки теста (`scripts/ship-guard.sh`) → ревью другой моделью →
  `check.sh` → публикация. Без slash-команд — те же шаги по `ship.md`. Формальный `/pipeline`
  (State V4) — только для регулируемых работ или по явной просьбе владельца.
- «Тест прошёл» без вывода раннера — не доказательство.
- Решение про безопасность, данные, совместимость, конкурентность: ограничения, варианты, выбор и
  откат — в спеке или описании PR.
- UI: в `/ship` на задачу — скриншот и консоль в браузере; перед релизом/демо и в `/pipeline` — две
  независимые проверки (`visual-qa` + `ux-route-qa`), один агент не подписывает другого; без видимого
  браузера — `CAPABILITY-BLOCKED`, а не PASS.
- Баги — `docs/bug-handling-process.md`: первопричина до фикса, весь класс бага, guard от регрессии.
- Тяжёлое чтение — в субагентах; состояние — в файлах, не в разговоре; сборка и тесты — по одному
  процессу на worktree, до 4 worktree параллельно (`scripts/ship-worktree.sh`), публикация — по одной.
- Конец хода — не конец цели: продолжай сам или закончи явно — `DONE` с доказательством,
  `WAIT_OWNER` (нужно решение владельца) или `BLOCKED`.

## Задачи и трекер

- Бэкенд: `ISSUE_BACKEND` из env, иначе из `PROJECT.md §7`, иначе `none`; неизвестный — отказ.
  `none` — работа в `specs/` и `docs/backlog.md`; `github` — Issues через `gh`, репозиторий из `origin`.
- Протокол — `agents/README.md` → «Режим задач (ISSUE MODE)». Хотелка одной фразой — `/intake`.

## Измеримость

- Телеметрия — `docs/telemetry.md`: hook пишет каждое действие, открывает задачу и просит у агента
  прогноз; агент закрывает задачу (`task done`) и классифицирует сбой (`log mast`). Дашборд —
  `bash scripts/telemetry.sh report --html docs/telemetry-dashboard.html`.
- Правку правил и скриптов, влияющую на агентов, проверяй `bash scripts/agent-eval.sh` до и после.
- Токены — только из реальных данных с `source=`; нет данных — так и пиши.

## Глубже

`docs/constitution.md` · `docs/pipeline-rules.md` · `agents/README.md` · `docs/bug-handling-process.md` ·
`docs/guides/` (публикация, NFR, auth, эксплуатация, память) · `docs/context-budget-and-token-efficiency.md` ·
`docs/state-v4-recovery.md` · `CLAUDE.md`.
