# Issue lifecycle → token-efficiency

`scripts/issue-token-lifecycle.pl` связывает задачи проекта с приватным ledger
`tokens per resolved ticket` (`docs/context-budget-and-token-efficiency.md`). Мост не хранит
содержимое тикета: он нормализует ключ, передаёт точный provider usage в `context-budget.pl`, а
resolution записывает только после проверенного terminal state.

## Выбор backend задач

Единое правило харнесса (то же в `scripts/intake.sh` и `scripts/agent-preflight.sh`):

1. переменная окружения `ISSUE_BACKEND`, если задана;
2. иначе первая строка `PROJECT.md`, начинающаяся с `ISSUE_BACKEND=`; она обязана точно совпасть с
   `^ISSUE_BACKEND=(github|none)\s*$` — опечатка не превращается молча в `none`;
3. иначе `none`.

Неизвестное значение (в env или в `PROJECT.md`) → exit `2` до любой mutation (fail closed).
`--backend` в CLI может только повторять результат правила; расхождение → exit `2`.
`PROJECT.md` читается как данные и никогда не `source`-ится.

## Контракт

- **`github`.** Identity: `github:<owner>/<repo>#<number>`. Репозиторий **всегда** выводится из
  canonical `origin` (`https://github.com/…`, `git@github.com:…`, `ssh://git@github.com/…`);
  не-GitHub origin → exit `2`. `--repo` и переменная `GH_REPO` (форма `owner/repo` или
  `github.com/owner/repo`) могут только точно повторять его — перенаправление → exit `2`.
- **`none`.** Внешнего трекера нет: работа живёт в `specs/`, очередь — `docs/backlog.md`.
  Usage-мост принимает `--ticket NNN-slug` или `specs/NNN-slug` → identity `spec:NNN-slug`.
  `close`/`sync` закрывать нечего → typed `BLOCKED: issue-backend-none` (exit `4`); resolution по
  спеке после verified remote SHA публикации записывается напрямую:
  `perl scripts/context-budget.pl resolve --ticket spec:NNN-slug --resolution <id>`.
- Сырой identity не попадает в ledger — сохраняется только SHA-256.
- `close` выполняет `gh issue close`, затем отдельный verify-read `gh issue view`. Только
  состояние `CLOSED` разрешает запись resolution.
- Verify-read обязан вернуть authoritative `closedAt`. Если timestamp нет, операция даёт typed
  `BLOCKED`, а метрика не изображает закрытие.
- Ошибка backend не включает fallback или mirror. stdout/stderr внешнего CLI не транслируются,
  поэтому случайно напечатанный credential не попадает в агентский лог.
- Повтор одного и того же verified close идемпотентен по namespaced ticket + backend timestamp.

Exit-коды: `0` — записано · `2` — конфигурация/аргументы (backend, repo, ticket) · `3` — ledger
отверг конфликтующий повтор · `4` — `BLOCKED` (backend недоступен, verify не подтвердил закрытие,
нет timestamp, `none` для close/sync).

## Usage без ручного namespace

Точный JSONL receipt runtime передаётся через stdin:

```bash
perl scripts/issue-token-lifecycle.pl ingest-jsonl \
  --ticket 123 --attempt run-123-a1 --class bug \
  --runtime codex --model unknown < runtime.jsonl
```

При `ISSUE_BACKEND=none` тот же вызов принимает `--ticket specs/001-export`. Для провайдера,
который уже вернул точные counters, доступен `record-usage` с теми же аргументами, что у
`context-budget.pl`. Если точного receipt/counters нет, запись не создаётся.

## Закрытие и восстановление связи (`github`)

Каноническое закрытие:

```bash
perl scripts/issue-token-lifecycle.pl close \
  --ticket 123 --comment "[developer] опубликовано и проверено"
```

Если тикет ранее закрыли напрямую или mutation прошла, но локальная запись не состоялась,
используется verify-only восстановление:

```bash
perl scripts/issue-token-lifecycle.pl sync --ticket 123
```

`sync` не меняет backend. Он перечитывает уже закрытый тикет и создаёт resolution только при том же
terminal+timestamp контракте.

## Архитектурное решение и rollback

Ограничения: один активный backend задач, отсутствие секретов в репо/логах, append-only ledger,
идемпотентность retry и запрет ложного `resolved` при недоступной сети.

Рассмотрены три варианта:

1. Встроить hooks отдельно в каждую команду `gh` — отклонено: расходящиеся lifecycle и прямое
   закрытие легко обходит метрику.
2. Фоново опрашивать все тикеты — отклонено: credentials и dedup нескольких машин требуют
   распределённого координатора, а polling теряет точную связь attempt→close.
3. Единый explicit bridge — выбран: одна fail-closed точка закрытия, одинаковый ledger-контракт и
   возможность восстановить связь через `sync`.

Rollback: вернуться к прямым командам `gh` из ISSUE MODE (`agents/README.md`); формат ledger не
меняется, поэтому уже собранные usage/resolution остаются читаемыми. Для нескольких машин
по-прежнему нужен отдельный коллектор с дедупликацией event ID — не поставлено.

## Ревизия харнесса

`context-budget.pl` по умолчанию относит события к ревизии = короткий SHA `HEAD` (или
`HARNESS_REVISION` / `--harness`), поэтому выборки до и после изменения процесса сравниваются как
разные поколения, а не смешиваются.

Покрытие: `tests/harness/cases/issue-token-lifecycle.sh` (backend-правило, origin-only identity,
`none`, verified close/sync).
