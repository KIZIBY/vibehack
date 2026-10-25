# CLAUDE.md — адаптер Claude Code

Этот файл — **тонкий UX-адаптер**, не источник правил. Authority: `AGENTS.md` (операционный
контракт), устав `docs/constitution.md`, каноны ролей `agents/roles/*.md` и enforcement-скрипты
`scripts/`. Паспорт проекта — `PROJECT.md`. При расхождении этого файла с ними прав не этот файл.

## Что даёт Claude Code в этом репозитории

| Где | Что |
|---|---|
| `.claude/commands/` | `/ship` (лёгкий конвейер по умолчанию: тест от отдельного агента → код → ревью другой моделью → публикация), `/pipeline` (формальный оркестратор четырёх стадий State V4, по явной просьбе), `/pipeline-stage1` … `/pipeline-stage4` (отдельная стадия), `/intake` (хотелка/жалоба одной фразой → feature\|bugfix → тикет или `docs/backlog.md` + спека → `/ship`), `/speckit.specify`, `/speckit.clarify`, `/speckit.plan`, `/speckit.tasks`, `/speckit.implement`, `/speckit.analyze`, `/speckit.checklist`, `/speckit.constitution`, `/speckit.taskstoissues`. |
| `.claude/agents/` | Тонкие стабы ролей (developer, visual-qa, ux-route-qa, workflow-qa, chaos-qa, regression-qa — канон каждой в `agents/roles/`) и специалисты: backend-developer, frontend-developer, db-expert, devops-deployer, ai-engineer, integration-engineer, test-runner, code-reviewer, system-analyst, hard-critic. |
| `.claude/skills/pipeline.md` | Скилл оркестрации `/pipeline`: порядок стадий, гейты, восстановление. |
| `.claude/hooks/bash-guard.sh` | PreToolUse на Bash: блокирует `git commit --no-verify`, `git push --force` без `--force-with-lease` и прямой `git push` в `main` (вход в main — PR или `scripts/agent-publish-main.sh`). |
| `.claude/hooks/session-main-sync.sh` | SessionStart: `git fetch origin` и предупреждение, если текущая ветка отстаёт от `origin/main`. |
| `.claude/hooks/telemetry.sh` | Все события (async): сырой лог действий агентов для метрик — `docs/telemetry.md`. |
| `.claude/hooks/telemetry-prompt.sh` | UserPromptSubmit (sync): открывает задачу, просит у агента прогноз, на исправление курса — MAST. |
| `.claude/settings.json` | Подключение хуков. |

Без Claude Code всё то же доступно через `AGENTS.md` и прямые вызовы скриптов
(`bash scripts/pipeline-state.sh …`); теряется только нативный UX.

## Что как править

| Что | Где | Правило |
|---|---|---|
| Поведение роли | `agents/roles/<id>.md` | источник истины; правится только здесь |
| Стаб роли | `.claude/agents/<id>.md` | тонкий (frontmatter + указатель на канон); копия канона в стабе — регрессия |
| Append-only данные | `docs/ops-journal.md`, `specs/*/audit.md`, `specs/*/*-changelog.tsv`, `agents/memory/` | только дописывать, штатными скриптами; правку прошлого блокирует pre-commit |
| Generated | `docs/pipeline-dashboard.html`, `tests/agent-evals/last-run.json` | руками не править — перегенерировать (`scripts/pipeline-dashboard.sh`, `scripts/agent-eval.sh`) |
| Устав | `docs/constitution.md` | только versioned-поправкой (Часть III): PR + bump версии + запись в журнале |
| Правила процесса | `docs/pipeline-rules.md` | только подтверждённые владельцем записи (дата + источник) |
| Паспорт проекта | `PROJECT.md` | номера/заголовки разделов и строку `ISSUE_BACKEND=` не менять — их читают каноны и скрипты |
| Runtime-команды, хуки | `.claude/commands/`, `.claude/skills/`, `.claude/hooks/` | UX-слой; правило, которое они исполняют, сначала фиксируется в каноне/доктрине/скрипте |

## Проверки перед коммитом

```bash
bash scripts/check.sh            # единая точка: проектные линт/тесты + быстрый self-test харнесса
```

Публикация — `bash scripts/agent-publish-main.sh` (PR-режим на feature-ветке; merge жмёт человек).
Правила — `AGENTS.md` → «Публикация» и `docs/guides/GIT_PUBLISH_RUNBOOK.md`.

## Словарь context-дисциплины (loop engineering)

- **Context rot** — тихая деградация качества по мере заполнения контекстного окна; рабочий бюджет
  считать заметно меньше паспортного размера окна. Лечение: тяжёлая работа в свежеконтекстных
  субагентах, оркестратор худой; пороги и handoff — `perl scripts/context-budget.pl budget`
  (`docs/context-budget-and-token-efficiency.md`).
- **Context poisoning** — неточные/нерелевантные данные в контексте уводят модель с задачи.
  Лечение: наверх от субагента только summary, состояние — в файлах (`state.md`/`audit.md`/память),
  не в разговоре.
- **Fan-out асимметрия** — параллельные субагенты для чтения/поиска; build/test/deploy — строго один
  процесс за раз в пределах worktree; до 4 worktree-исполнителей параллельно (устав 2.0.0, I-15).
- **Одна задача на итерацию** — итерация (pipeline-этап, юнит) делает одну единицу работы,
  фиксирует состояние и завершается; следующая итерация читает файлы, а не «помнит».
- **Вложенные субагенты стадий — синхронно** — фоновые агенты запускает только оркестратор;
  внутри агента верификация (сюита, convergence-check) идёт foreground-вызовом, иначе результат
  теряется непрочитанным.
