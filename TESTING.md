# Тесты харнесса: как устроены и как пополнять

Харнесс несёт собственный self-test сьют в `tests/harness/` — тонкий оркестратор + по одному
**поведенческому** case-файлу на домен (скрипты `scripts/`, git-хуки, Claude-хуки). Он отдельно от
тестов самого продукта (их команды — в `PROJECT.md §3`). Про процесс разработки и PR — в
[CONTRIBUTING.md](CONTRIBUTING.md).

## Как прогнать

```bash
bash scripts/check.sh                          # единая точка проверок перед коммитом/публикацией
bash tests/harness/run-tests.sh --tier fast    # быстрый dev-слой (~15 с); то же: run-tests.sh fast
bash tests/harness/run-tests.sh --tier full    # полный сьют (~1–2 мин); то же: run-tests.sh full
bash tests/harness/run-tests.sh intake preflight   # только перечисленные case'ы
bash tests/harness/run-tests.sh --list         # манифест уровней
bash tests/harness/cases/<имя>.sh              # один case во время написания
```

- `scripts/check.sh` гоняет `run-tests.sh --tier fast` (если `tests/harness/` есть; иначе одна
  строка SKIP) и затем проверки проекта из своего размеченного блока. `agent-publish-main.sh` в
  PR-режиме запускает `check.sh` сам на перенесённых коммитах.
- Exit раннера: `0` — всё зелёное · `1` — есть FAIL или нарушен `min-asserts` · `2` — ошибка
  аргументов · `124` — превышен жёсткий потолок сьюта.
- Последняя строка вывода — `ИТОГ: pass=<n> fail=<n> cases=<n> tier=<fast|full>`; перед ней —
  `SECTION_TIME <case> <сек>` и `SLOW_CASE …` для кейсов дольше `RT_SECTION_BUDGET` (90 с).
- JUnit для любого CI: `bash tests/harness/run-tests.sh full 2>&1 | python3 scripts/ci-test-report.py run-tests.log report.xml`
  (репортер всегда exit 0 — код сьюта бери из `PIPESTATUS`).

Зависимости среды: `bash`, `git`, `perl` (core-модули), `python3` (для `assert_json`/репортера).
Сеть не нужна: провайдеры — двойники и PATH-стабы, origin'ы — `file://`-bare.

## Структура

| Путь | Что |
|---|---|
| `tests/harness/run-tests.sh` | оркестратор (выбор уровня, suite- и пер-case watchdog, параллельные батчи, склейка вывода, `ИТОГ:`) |
| `tests/harness/tiers.tsv` | состав уровней fast/full + `min-asserts` + опциональный пер-case потолок (сек) |
| `tests/harness/lib/harness.sh` | общие ассерт-хелперы (`t`, `t_out`, `ps_reject_unchanged`, …) — API заморожен |
| `tests/harness/lib/fixtures.sh` | opt-in: фабрика git-фикстур + структурные ассерты (`mk_repo`, `assert_json`, `wait_for`) |
| `tests/harness/lib/stubs.sh` | opt-in: PATH-injected CLI-стабы с argv-логом (`stub_bin`, `stub_guard`, `hermetic_env`) |
| `tests/harness/cases/*.sh` | по одному поведенческому файлу на домен |
| `tests/harness/fixtures/` | статические фикстуры (спеки/планы для линтеров, двойники `gh`, legacy state) |
| `tests/agent-evals/` | отдельный eval-корпус `% Resolved` (`scripts/agent-eval.sh`, см. его README) |
| `scripts/ci-test-report.py` | stdout сьюта → консольный прогресс + лог + JUnit `report.xml`; контракт охраняет `cases/ci-report.sh` |

Гейт = **0 FAIL**. Фиксированного baseline-числа нет; `min-asserts` в `tiers.tsv` страхует, что
case не «прошёл» пустым и что ассерты не пропали тихо.

## Уровни

- **fast** (dev-гейт, потолок сьюта 180 с, последовательно): syntax, secret-patterns, spec-plan-lint,
  install-hooks, runtime-adapter, context-budget, issue-token-lifecycle, changelog-v1, ci-report,
  memory-check, state-recover, check-entrypoint.
- **full** (= fast + остальное, потолок 1800 с, батчи по `RT_PARALLEL=4`): pipeline-state, intake,
  publish-main, preflight, publish-pr, localize-gitdir, receipts, coordination-lease, dora-ops-log,
  dashboards-smoke, eval-runner, evidence-verifiers.

Состав определяет только `tiers.tsv` — авто-обнаружения case-файлов нет.

## Как добавить новый тест

**1. Создай `tests/harness/cases/<домен>.sh`** по шаблону:
```bash
#!/usr/bin/env bash
# tests/harness/cases/my-thing.sh — что проверяем + инварианты (I-N).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "my-thing (краткое описание)"

# t <имя> <ожидаемый-exit> <команда...>   (команда может быть функцией — исполняется в текущем
# shell, поэтому видит твои переменные и $ROOT / $FIX / $TMP)
t "валидный ввод → 0" 0 bash "$ROOT/scripts/my-thing.sh" "$FIX/good.txt"
t "битый ввод → 1"    1 bash "$ROOT/scripts/my-thing.sh" "$FIX/bad.txt"

# для пайплайнов/многошаговых — заведи функцию и проверь её код возврата:
emits_ok() { bash "$ROOT/scripts/my-thing.sh" | grep -Eq '^ok='; }
t "печатает ok=<...>" 0 emits_ok

harness_exit          # ← ОБЯЗАТЕЛЬНО последней строкой (exit 0 iff все ассерты зелёные)
```

**2. Зарегистрируй в `tests/harness/tiers.tsv`** одной строкой:
```
my-thing.sh    full    5    120   # <файл>  <fast|full>  <мин.ассертов>  [потолок, сек]
```
- `fast` — лёгкие/быстрые (их гоняет `scripts/check.sh`); `full` — всё остальное.
- `min-asserts` = текущее число ассертов кейса (честный пол, без «запаса»): если ассерты пропадут,
  гейт покраснеет. Добавил ассерты — подними пол.
- Порядок строк full-секции = планировка параллельных батчей (по 4, батч ждёт целиком): тяжёлые
  кейсы держи в разных батчах.
- 4-я колонка опциональна: жёсткий пер-case потолок в секундах («-»/пусто → default
  `RT_CASE_HARD_CAP=300`; `0` → выкл). Превышение → `FAIL  case-timeout…` в секции кейса,
  process-group кейса добивается (TERM→KILL), гейт красный. Ставь потолок явно только там,
  где >90 с легитимны — заодно это документирует ожидание.

**3. Прогони:** `bash tests/harness/cases/my-thing.sh`, затем `bash tests/harness/run-tests.sh full`.

**Сначала RED.** Изменение поведения начинается с падающего ассерта: допиши кейс, увидь `FAIL`,
затем меняй скрипт до `ok`.

## API хелпера (`tests/harness/lib/harness.sh`)

| Хелпер | Что делает |
|---|---|
| `section "<title>"` | заголовок секции (один на файл, первым) |
| `t "<имя>" <код> <cmd...>` | гоняет `cmd`, сверяет exit-код (`cmd` может быть функцией) |
| `t_out "<имя>" "<ERE>"` / `t_out_absent` | грепает вывод **последней** `t` (есть / нет паттерна) |
| `ok "<имя>"` / `no "<имя>" [деталь]` | ручной pass / fail |
| `ps_ <args>` | обёртка над `scripts/pipeline-state.sh` |
| `ps_reject_unchanged <dir> <args>` | exit2 + байты `state.md`/`audit.md` не изменились + нет temp |
| `$ROOT` / `$FIX` / `$TMP` | корень репо / `tests/harness/fixtures` / приватный авто-чистящийся temp |
| `harness_exit` | последняя строка case-файла: exit 0 iff все ассерты зелёные |

## API opt-in библиотек (source ПОСЛЕ harness.sh — печатают через те же счётчики)

`tests/harness/lib/stubs.sh` — мокирование внешних CLI (`git push`, `gh` …):

| Хелпер | Что делает |
|---|---|
| `stub_bin <name> [--log F] [--body '…']` | кладёт исполняемый стаб в `$TMP/stubs` (он первым в PATH); каждый вызов пишет строку `name <arg1> <arg2>…` в argv-лог; без body → exit 0 |
| `stub_guard <name> <allowed-ERE>` | fail-loud стаб: argv вне паттерна → stderr + exit 97 (нецелевая работа SUT с CLI роняет тест) |
| `stub_called <log> <ERE>` / `stub_not_called <log> [ERE]` | предикаты по argv-логу (для `t`/`ok`) |
| `hermetic_env [VAR=val…] <cmd…>` | `env -i` + минимальный PATH + HOME/XDG в `$TMP`: доказательство независимости SUT от ambient-окружения |

`tests/harness/lib/fixtures.sh` — git-фикстуры и структурные ассерты:

| Хелпер | Что делает |
|---|---|
| `mk_repo <dir>` / `mk_bare <dir>` | git init -qb main + identity per-repo (`--global` запрещён) / bare-origin |
| `mk_commit <dir> <rel> <content> [msg]` | файл + add + commit |
| `phys <path>` | физический путь (`pwd -P`) — macOS `/var` vs `/private/var` |
| `wait_for <secs> <cmd…>` | bounded-поллинг 0.2 с; **единственный** санкционированный способ ждать async (голый `sleep N` в кейсах запрещён) |
| `assert_file_contains/absent <имя> <file> <ERE>` | греп по файлу (absent = файла нет или паттерна нет) |
| `assert_path_absent` / `assert_branch` | путь не существует / текущая ветка репо |
| `assert_json <имя> <file> <py-expr>` | JSON парсится, py-выражение над `data` истинно (inline python3) |
| `assert_xml_wellformed <имя> <file>` | XML парсится ElementTree |

Паттерн «один fixture-репозиторий на ветку поведения»: кейс строит под `$TMP` ровно то
git-состояние, которое проверяет одну ветку логики SUT — не переиспользуй одну фикстуру
на разные ветки, состояния разъедутся.

**Дополнить существующий case** — просто добавь строки `t/ok` в нужный
`tests/harness/cases/*.sh` и подними его `min-asserts` в `tiers.tsv`.

## Тестовые хуки в скриптах

Некоторые скрипты читают переменные `HARNESS_*_TEST_PAUSE` / `HARNESS_PIPELINE_*_TEST_*` — это
детерминированные точки для causal-тестов гонок (STOP процесса в точно известном окне, обычно с
управляющим FD 9). В production они не выставляются; где FD 9 обязателен, запуск с выставленной
переменной без него — отказ, а не тихий пропуск.
Fixture-контролы провайдера `FAKE_GH_*` проходят через `scripts/provider-env.pl` только в
механической копии SUT с литералом `ISSUE_PROVIDER_TEST_ENABLED=1` (см. `cases/intake.sh`) —
в поставляемом скрипте production-allowlist не расширяется.

## Правила (чтобы тесты не гнили)

- **Только поведение** — проверяй наблюдаемое: exit-коды, содержимое файлов, stdout.
- **Нельзя:** golden-хэши (`sha256 == "cb89…"`), греп по *исходнику* SUT, точные длинные фразы,
  тайминг-бюджеты (`≤5s`), OS-специфику (`stat -f`, `ps -o lstart`).
- **Герметично** — фикстуры строй под `$TMP`; не трогай реальные `docs/ops-journal.md`,
  `coordination/leases/`, `agents/memory/`.
- **Parallel-safe** — full-tier кейсы бегут параллельно (`RT_PARALLEL=4`): всё состояние — в
  своём `$TMP`, git-конфиг только per-repo (`--global` запрещён), никаких фиксированных портов и
  живых серверов.
- **Async — только `wait_for`** (fixtures.sh, bounded-поллинг): голый `sleep N` в кейсах
  запрещён — это либо флейк, либо зря сожжённый бюджет.
- **Негатив обязателен** — тест, который умеет только зеленеть, бесполезен: перед сдачей кейса
  один раз сломай ожидание SUT (или прогони копию с испорченным ассертом) и увидь FAIL.
- **Секрет-паттерны в фикстурах** — только конкатенацией (`'sk-ant-''api03-'…`), иначе кейс
  поймает сам pre-commit (I-7).
- **stdin** — интерактивные скрипты (например, `intake.sh` без 4-го аргумента читает body из
  stdin) вызывай с `</dev/null` или явным аргументом, иначе кейс может повиснуть.

## Что НЕ тестируем (осознанные границы)

- **LLM-поведение и контент `.claude/*`** — детерминированный слой это не ловит; outcome-метрика
  харнесса — корпус `tests/agent-evals` (`% Resolved`, прогонщик `scripts/agent-eval.sh`).
- **Пиксели/вёрстку дашборда** — только структурные маркеры сгенерированного HTML.
- **Реальную сеть** (`gh`, хостинг git) — только PATH-стабы, двойники из `tests/harness/fixtures`
  и `file://`-bare-origin'ы (GitHub-origin имитируется через `url.<bare>.insteadOf`).
- **Позитивные цепочки `tdd-receipt run`/`performance-process run`** — требуют полной Stage-3/4
  фикстуры (минуты, producer-identity в base-коммите); в сьюте — exit-словарь и tamper-матрицы
  (`cases/receipts.sh`), полный позитив живёт в реальном пайплайне.
- **Байт-golden артефактов** — допустимы только self-referential сравнения (run1-vs-run2,
  clean-vs-poisoned, как в `cases/dora-ops-log.sh`).
