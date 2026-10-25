# telemetry.md — телеметрия агентов: что логируется, откуда метрики, как вести

Цель — честно показать, как команда работает с AI: каждое действие агента пишется в сырой лог, метрики
считаются из реальных данных (хуки Claude Code, транскрипты, git), а не из памяти и не из прозы.
Код: `scripts/telemetry.py` (CLI `bash scripts/telemetry.sh`), hooks `.claude/hooks/telemetry.sh` (все события)
и `.claude/hooks/telemetry-prompt.sh` (UserPromptSubmit, ведёт задачи),
рендер `scripts/lib/telemetry_html.py`, тест `tests/harness/cases/telemetry.sh` (fast-гейт `check.sh`).

## Что и куда пишется

- **Hook на все события** (`.claude/settings.json`, `async` — сессию не тормозит, exit 0 всегда):
  SessionStart/End, UserPromptSubmit, Pre/PostToolUse, PostToolUseFailure, PermissionRequest/Denied,
  Notification, SubagentStart/Stop, Stop/StopFailure, Pre/PostCompact. Одна JSONL-строка на событие.
- **Каталог:** `<основной checkout>/.harness/telemetry/` (общий для всех worktree), в git не попадает:
  в сыром логе промпты и пути машины. Переопределение — `HARNESS_TELEMETRY_DIR`.
- **Редакция до записи:** секрет-паттерны `scripts/secret-patterns.sh` + `Bearer …` + `password=…`
  и т.п. → `[REDACTED]`; строки длиннее 4000 симв. — head+tail.
- **Агрегаты** (`report --json|--html`) не содержат путей машины и текста промптов — их можно показывать.
- Отключить на время: `HARNESS_TELEMETRY=0`.

## Кто ведёт задачи — агент, по подсказке хука

Человеку ничего набирать не нужно. `telemetry-prompt.sh` (синхронный UserPromptSubmit) на каждый промпт:

- **нет активной задачи** и промпт — постановка (не «ок»/«да») → открывает `T<n>` и через
  `additionalContext` просит агента до начала работы дать прогноз и короткий заголовок
  (`task estimate T<n> <мин> --title "…"`) и закрыть задачу по завершении (`task done T<n>`);
  заголовок не берётся из промпта — в агрегатах нет текста промптов;
- **активна задача** и пришла новая просьба → напоминает закрыть её, если это другая работа
  (`task done … && task start auto --estimate …`);
- **исправление курса** («нет, не так», «я про…») → просит агента классифицировать сбой по MAST
  (`log mast code=FM-x.y`); правило, закрывшее сбой, — `log rule … closes=FM-x.y` после одобрения владельца.

Подсказка — исполняемый путь конвенции (I-17), а не надежда на внимание агента.

## Команды

```bash
bash scripts/telemetry.sh log milestone name=start            # открыть окно отчёта (старт хакатона)
bash scripts/telemetry.sh task start T3 --title "экспорт" --estimate 30 [--human-estimate 120]
bash scripts/telemetry.sh task estimate T3 25 --title "экспорт"   # прогноз для авто-задачи
bash scripts/telemetry.sh task start auto --estimate 20 --title "…" # следующий свободный номер
bash scripts/telemetry.sh task review T3 | task done T3 | task block T3 | task status T3 todo
bash scripts/telemetry.sh log mast code=FM-2.2 note="не уточнил, про какой репо речь"
bash scripts/telemetry.sh log rule ref=docs/pipeline-rules.md#… closes=FM-2.2
bash scripts/telemetry.sh log eval name=rag score=0.82         # RAG / LLM-судья; agent-eval пишется сам
bash scripts/telemetry.sh log intervention reason=… | log bug source=human | log manual-edit files=…
bash scripts/telemetry.sh status                               # одна строка «где мы»
bash scripts/telemetry.sh report [--since ISO] [--json | --html docs/telemetry-dashboard.html]
```

`task start` ставит указатель текущей задачи для worktree: все события хуков после него помечаются
этой задачей. Окно отчёта по умолчанию — от последнего `milestone name=start`, иначе от первого события.

## Метрики и источники

| Метрика | Источник | Авто? |
|---|---|---|
| Токены по моделям и ролям | транскрипты Claude Code (`message.usage`, дедуп по `message.id`); роль = `agentType` субагента | да |
| Стоимость по моделям | токены × прайс `PRICES` (кэш-запись ×1.25/×2, fast ×2) — API-эквивалент, на подписке это оценка | да |
| Активное время | `turn_duration` в транскрипте; по задаче — в её окне | да |
| Строки кода от AI | `structuredPatch` Edit/Write (инструменты) + git numstat по трейлеру `Co-Authored-By` | да |
| Коммиты и PR | git log (AI = трейлер) · `gh pr create` в хуках · `publish:pr` в `docs/ops-journal.md` | да |
| Принятые / отклонённые правки | PostToolUse правок (принято) · отказ/PermissionDenied (отклонено) · `userModified` | да |
| Задачи по статусам | hook открывает `T<n>` сам; агент закрывает (`task done`) по подсказке | да (агент) |
| Круги ревью, % с первого раза | SubagentStop ревьюера (`code-reviewer`, `hard-critic`: APPROVE/BLOCK) · `ReportFindings` /code-review | да |
| Баги до мержа | находки ревьюера (P0–P2, BLOCK ≥1) + красные прогоны тестов + `log bug` | да + вручную |
| Вмешательства человека | промпты после постановки задачи (классификация: исправление/одобрение/вопрос/…), прерывания, запросы разрешений, ответы на вопросы агента, ручные коммиты в окне задачи | да |
| Прогноз и факт (METR) | прогноз агента до начала работы (`task estimate`, просит hook) vs время start→done и активное время | да (агент) |
| Ошибки MAST и закрытые правилом | `log mast` + `log rule closes=`; авто-кандидаты: FM-1.3 (3 одинаковых вызова подряд), FM-1.1 (исправление курса), FM-3.2 (задача закрыта без тестов) | кандидаты авто; подтверждает агент по подсказке хука |
| Рост плейбука | пункты `- **…**` в `docs/pipeline-rules.md` по истории git + `log rule` | да |
| Тесты: красные → зелёные | Bash-команды по `HARNESS_TELEMETRY_TEST_RE` (check.sh, pytest, jest, go test, …): exit-код + счётчики passed/failed | да |
| Эвал-скор по итерациям | `agent-eval.sh` (из `last-run.json`) + `log eval` | да + вручную |
| Доля задач, закрытых AI без ручной правки | готовые задачи без `manual-edit` и без человеческих коммитов в окне задачи | да |

Таксономия MAST (Cemri et al., 2025) — 14 режимов в 3 категориях: FC1 спецификация и дизайн
(FM-1.1…1.5), FC2 рассогласование агентов (FM-2.1…2.6), FC3 верификация и завершение (FM-3.1…3.3);
полный список — `MAST` в `scripts/telemetry.py`.

## Сбои и правила в git

`log mast` дописывает строку в `docs/failures.md` (append-only, `merge=union`): код MAST, категория,
задача, заметка — ошибки видит вся команда, а не только локальный лог. `log rule … closes=FM-x.y`
дописывает строку «закрыт правилом». После `log mast` агент предлагает владельцу одно правило (ACE).
Повторяющиеся Bash-команды (≥3 раз) отчёт выводит как «Кандидаты в скрипты» — рутину оформляют в
`scripts/` или скилл (Live-SWE-agent, Darwin Gödel Machine).

## Ограничения (честно)

- Правки через Bash (`sed -i`, heredoc) в «строки AI · инструменты» не попадают — их видит git-счётчик.
- Классификация вмешательств — эвристика по тексту; спорные случаи дописывай `log intervention`.
  Системные уведомления (`<task-notification>`, `<system-reminder>`) — не человек и не считаются.
- Указатель задачи — на worktree: две параллельные задачи в одном checkout смешаются (используй worktree
  или `HARNESS_TASK=<id>`).
- Хуки видят только сессии Claude Code с этим `.claude/settings.json`; Codex/Cursor — только через git.
