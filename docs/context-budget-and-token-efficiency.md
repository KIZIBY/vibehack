# Context Budget и tokens per resolved ticket

`scripts/context-budget.pl` — переносимый Perl-core без `jq`/Python. Он решает две связанные задачи:

1. не даёт длинной агентской сессии тихо съесть всё контекстное окно;
2. измеряет фактические токены на закрытую задачу и сигнализирует, когда новая ревизия харнесса
   стала статистически дороже предыдущей.

## Контекстный broker

```bash
perl scripts/context-budget.pl budget --limit 200000 --used 60000 --telemetry exact
```

Пороги:

| Доля использованного окна | Состояние | Действие |
|---|---|---|
| `<30%` | `NORMAL` | продолжать |
| `30–49%` | `CHECKPOINT` | сохранить краткое состояние и ссылки на артефакты |
| `50–74%` | `FREEZE` | не расширять scope/fan-out, подготовить handoff |
| `75–99%` | `HANDOFF` | перейти в свежую сессию из durable checkpoint |
| `≥100%` | `EXHAUSTED` | выполнение без нового контекста запрещено |

`--telemetry exact|estimated` обязателен: оценка никогда не выдаётся за провайдерский счётчик.
`--enforce` возвращает exit `4` при `HANDOFF/EXHAUSTED` и подходит для оркестратора, который
решает, продолжать ли сессию.

## Что считается tokens/ticket

- В стоимость задачи входят все записанные попытки до её закрытия, включая неуспешные.
- `total_tokens = input_tokens + output_tokens`.
- `cached_input_tokens` хранится как диагностическое подмножество и второй раз не суммируется.
- Поддерживаемые рантаймы parser'а: `claude` и `codex`. Для Claude parser нормализует раздельные
  `input + cache_read + cache_creation`; для Codex `cached_input_tokens` уже является частью
  `input_tokens`. Иной `--runtime` в `parse-usage`/`ingest-jsonl` → exit `2` (fail closed).
- Сырой ID задачи не сохраняется: ledger содержит только SHA-256 namespaced ID
  (`github:<owner>/<repo>#<n>` или `spec:<NNN-slug>`).
- Задача относится к ревизии харнесса, на которой зафиксировано закрытие. Предыдущие попытки
  остаются в её полной стоимости — оптимизация не может спрятать уже сожжённые токены.

## Запись usage

Рекомендуемый вход — lifecycle-мост `scripts/issue-token-lifecycle.pl` (`docs/issue-token-lifecycle.md`):
он сам выбирает backend задач (env `ISSUE_BACKEND` → `PROJECT.md` → `none`) и строит namespaced ID,
не заставляя агента дублировать `owner/repo`:

```bash
# ISSUE_BACKEND=github — номер issue; репозиторий берётся из origin
perl scripts/issue-token-lifecycle.pl ingest-jsonl \
  --ticket 123 --attempt run-123-a1 --class bug \
  --runtime codex --model unknown < runtime.jsonl

# ISSUE_BACKEND=none — каталог спеки
perl scripts/issue-token-lifecycle.pl ingest-jsonl \
  --ticket specs/001-export --attempt run-1-a1 --class feature \
  --runtime claude --model unknown < runtime.jsonl
```

Прямые команды ниже остаются низкоуровневым API метрики.

Если runtime дал числа напрямую:

```bash
perl scripts/context-budget.pl record-usage \
  --ticket github:owner/repo#123 --attempt run-123-a1 --class bug \
  --runtime codex --model gpt-coding \
  --input 42000 --output 7000 --cached-input 30000
```

Для JSONL Claude/Codex безопаснее дать parser'у исходный stream, не разбирать его shell-командами:

```bash
perl scripts/context-budget.pl ingest-jsonl \
  --ticket spec:001-export --attempt run-1-a1 --class feature \
  --runtime claude --model unknown < runtime.jsonl
```

Если провайдер не отдаёт точный usage receipt, запись не создаётся. Выдумывать токены или подменять
их размером файла/числом сообщений запрещено.

После проверенной публикации каноническое закрытие GitHub-задачи выполняет mutation, verify-read и
запись resolution одной командой:

```bash
perl scripts/issue-token-lifecycle.pl close \
  --ticket 123 --comment "[developer] опубликовано и проверено"
```

Ручная запись resolution после уже доказанного закрытия (в т.ч. для `ISSUE_BACKEND=none` — после
verified remote SHA публикации спеки):

```bash
perl scripts/context-budget.pl resolve \
  --ticket spec:001-export --resolution publish-001-<commit>
```

Операции идемпотентны по `attempt`/`resolution`; повтор с другими байтами получает exit `3`.

## Отчёт и red flag

```bash
perl scripts/context-budget.pl report
perl scripts/context-budget.pl check
```

По умолчанию последняя ревизия харнесса сравнивается с предыдущей внутри одинаковой когорты
`task class × runtime × model`. Это защищает метрику от ложного роста из-за того, что в новой
порции задач оказалось больше сложных feature или сменилась модель.

- минимум: `5` закрытых задач в обеих ревизиях;
- red flag: среднее выросло более чем на `15%`;
- до выборки: `WARMUP`;
- достаточная выборка без регрессии: `GREEN`;
- подтверждённый рост: `RED`, а `check` возвращает exit `4`.

Порог и выборка настраиваются: `--min-sample N --threshold-pct P`. Отчёт также показывает median,
размеры когорт, baseline/latest ревизию харнесса и точный процент изменения. Среднее остаётся
главным гейтом; median нужен для диагностики выбросов.

## Где хранятся данные

Default ledger: private mode-0600 файл `agent-harness/token-efficiency.jsonl` в canonical Git
common-dir. Поэтому все worktree одного клона видят одну историю, а рабочее дерево и коммиты не
загрязняются. Путь можно задать через `--ledger` или `HARNESS_TOKEN_LEDGER` для private shared
storage с корректным `flock`.

Текущая поставка честно является local/shared-file v1. Объединение нескольких машин требует
отдельного коллектора с дедупликацией event ID — не поставлено; до него независимые локальные
ledger нельзя складывать простым суммированием.

## Ревизия харнесса

По умолчанию ревизия = короткий SHA (`--short=12`) текущего `HEAD` репозитория. Можно явно
передать `--harness <атом>` или задать `HARNESS_REVISION` (например, тег версии харнесса, если
проект хочет сравнивать поколения харнесса, а не каждый коммит). Таким образом отчёт сохраняет
историю до/после каждого изменения процесса.
