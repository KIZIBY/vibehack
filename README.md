# AI-судья

Короче, это штука, которая оценивает хакатонные проекты вместо уставшего жюри.

Жюри из 3–5 человек за пару часов не успевает открыть код 20–50 команд. Смотрят скринкаст,
ставят «по ощущениям», оценки расходятся, плагиат всплывает случайно. Мы это починили:
каждой работе — одна рубрика, одна глубина проверки и баллы с источником.

## Что оно делает

- Организатор заводит проект и рубрику (≤ 10 мин), грузит работы: архивы, git-ссылки, презентации.
- Серверная часть сама распаковывает и вытаскивает материалы. Без LLM, детерминированно.
- На каждую работу идут пять агентов в Hermes: sorter, code, business, design, critic.
  У каждого свой навык и урезанный набор инструментов.
- У каждого балла есть обоснование и ссылка: файл:строка, слайд, скриншот, URL.
- Итог считает формула, а не модель. Модель только ставит баллы по схеме.
- Флаги: плагиат, «сделано до старта», презентация врёт про код, попытки уболтать судью.
- Каждый шаг агентов пишется в журнал. Можно найти кто, что и зачем сделал.

Лидерборд по 20 работам — за ≤ 30 минут.

Код участников мы **не запускаем**. Это сознательно.

## Как устроено

```
браузер (чат + вкладки) → Backend API (FastAPI) → очередь (≤ 5 работ параллельно)
                                   │                    ├→ intake (распаковка, git, извлечение)
                                   │                    └→ Hermes gateway → плагин ai-judge
                                   └→ БД + том с материалами (общий с Hermes)
```

В интерфейсе слева проекты, в центре диалог с агентом, вкладки «Рубрика / Решения / Лидерборд /
Журнал». Подробности — `docs/design-doc.md`.

| Папка | Что там |
|---|---|
| `backend/` | REST API и оркестратор оценки |
| `frontend/` | веб-интерфейс (React + Vite + Tailwind) |
| `intake/` | распаковка и извлечение материалов |
| `hermes/` | Hermes Agent, плагин `ai-judge`, навыки, деплой на VPS |
| `specs/001-ai-judge-platform/` | спека, план, задачи, OpenAPI-контракт |

## Запуск

```bash
bash scripts/setup.sh      # зависимости
bash scripts/check.sh      # линт + тесты, прогоняй перед коммитом
```

- Backend запускай **одним воркером**: `uvicorn app.main:app`, без `--workers`. Сессии и лимит
  попыток входа лежат в памяти процесса.
- Frontend ходит только в реальный backend (`VITE_API_URL`). Без backend:
  `VITE_ENABLE_MOCKS=true npm run dev`.
- Hermes и деплой на VPS — `hermes/README.md`. Секреты только в `~/.hermes/.env` на сервере,
  в репо их нет.

## Чего тут пока нет

Портала подачи для участников, автоштрафов, интеграций с LMS и Kaggle, платного антиплагиата.
Список целиком — Out of Scope в спеке.

## Правила игры

Процесс разработки, роли агентов и публикация — `AGENTS.md` и `CONTRIBUTING.md`.
В `main` напрямую не пушим, только PR.

---

## Харнесс разработки

agent-harness — нейтральный харнесс агентной разработки и планирования

Набор правил, ролей, команд и bash/perl-скриптов, который превращает любой git-репозиторий в
рабочее место команды кодовых агентов под управлением владельца. Харнесс не привязан ни к
компании, ни к продукту, ни к конкретной LLM/IDE и не тянет внешних интеграций: всё, что ему
нужно знать о проекте, лежит в одном файле — `PROJECT.md`.

Что даёт харнесс:

- **Формальный `/pipeline` из четырёх стадий** — Creative → Audit → гейт владельца →
  Dev/TDD → Quality/Evidence — на state-машине State V4: Design-Root, Implementation-Root и
  Evidence-Root связывают решение, реализацию и доказательства, а публикация пушит exact OID по
  цепочке R→C→H→B. Обрыв сессии не теряет прогресс: стадия возобновляется из `state.md`.
- **Лёгкий speckit-поток** (`/speckit.specify` → `/speckit.plan` → `/speckit.tasks` →
  `/speckit.implement`) и единую входную точку `/intake` («хотелка одной фразой → feature|bugfix →
  тикет/очередь + спека»).
- **Роли агентов** — каноны в `agents/roles/` (developer, repo-hygiene, tech-writer, visual-qa,
  ux-route-qa, workflow-qa, chaos-qa, regression-qa) плюс специалисты для Claude Code.
- **Доктрины** — устав проекта (17 инвариантов), свод работы с багами, правила bug-hunter'ов,
  NFR, аутентификация продукта, эксплуатация, память агентов, публикация в git.
- **Локальные метрики** — Flight Deck (`docs/pipeline-dashboard.html`), DORA и метрика автономии
  из git/`audit.md`/`docs/ops-journal.md`, контекстный бюджет и `tokens per resolved ticket`.
- **Evals** — execution-grounded `% Resolved` на курируемых задачах (`tests/agent-evals/`).

## Граница универсальности (честно)

**Runtime-neutral.** Авторитетный слой — `AGENTS.md`, каноны в `agents/roles/`, артефакты
`specs/` и enforcement-скрипты в `scripts/` — не зависит от конкретной LLM или IDE. Claude Code,
Codex, Copilot, Cursor или человек запускают одну и ту же state-машину, линты, тесты и
exact-OID publisher; смена рантайма не меняет правила допуска.

**Не toolchain-neutral.** Формальный `/pipeline` исполняет RED/GREEN- и performance-доказательства
только через `/usr/bin/perl`, `/bin/bash`, `/bin/sh` или исполняемый (`100755`) wrapper внутри
репозитория с таким shebang, вызванный в direct-argv форме. Явные `npm`/`go`/`pytest`/`java`-команды
дают `CAPABILITY-BLOCKED: execution-toolchain-v1`: бинарник в `PATH` не является identity-bound
ToolchainRoot. Решение простое — **оберни команду тестов в bash-скрипт** (например
`scripts/test-unit.sh`, `#!/bin/bash`, режим `100755`) и укажи его в `PROJECT.md §3`. Digest
wrapper'а связывает только его собственные байты; то, что он запускает внутри, — граница
доверенного (отревьюенного) тестового кода, статически это не «доказывается». Поведенческие
TDD/performance-доказательства нельзя заменить на `N/A`. Лёгкий delivery-поток этого
ограничения не имеет — там проектные проверки запускаются как есть.

**UX-адаптеры.** `.claude/commands`, `.claude/agents`, `.claude/skills` и `.claude/hooks` дают
нативные slash-команды, роли и хуки Claude Code, но не являются источником истины. Другие
рантаймы читают `AGENTS.md` и вызывают скрипты напрямую
(`bash scripts/pipeline-state.sh …`); оркестрацию стадий оператор тогда ведёт по доктрине
вручную — enforcement тот же, нативного UX нет.

## Что внутри

| Путь | Что это |
|---|---|
| `PROJECT.md` | Паспорт проекта — **единственный файл, который заполняется при установке**: стек, команды, окружения, тестовые пользователи, аутентификация, трекер задач, UI-QA. |
| `AGENTS.md` | Операционный контракт для любого кодового агента (открытый стандарт [agents.md](https://agents.md)). |
| `CLAUDE.md` | Тонкий адаптер Claude Code: где команды, роли, хуки; словарь context-дисциплины. |
| `agents/README.md` | Гайд команды агентов: роли, маршрутизация, память, правила доказательств, «Режим задач (ISSUE MODE)». |
| `agents/roles/*.md` | Каноны ролей — источник истины поведения агентов. |
| `agents/memory/` | Персистентная память ролей: `<роль>.md`, append-only; файлы и помесячные архивы создаются по мере работы (`docs/guides/MEMORY_CONVENTION.md`). |
| `.claude/agents/*.md` | Тонкие стабы ролей + специалисты: backend-developer, frontend-developer, db-expert, devops-deployer, ai-engineer, integration-engineer, test-runner, code-reviewer, system-analyst, hard-critic. |
| `.claude/commands/` | `/pipeline`, `/pipeline-stage1…4`, `/intake`, `/speckit.*`. |
| `.claude/skills/pipeline.md` | Скилл оркестрации `/pipeline`. |
| `.claude/hooks/` + `.claude/settings.json` | `bash-guard.sh` (блок `--no-verify`, `--force` без lease, прямого push в main) и `session-main-sync.sh` (предупреждение об отставании от `origin/main`). |
| `docs/constitution.md` | Устав проекта: 17 универсальных инвариантов + доменные слоты `[ЗАПОЛНИ]`. |
| `docs/constitution-check.md` | Gate-процедура сверки спеки/плана/диффа с уставом (`MUST-FLAG` блокирует). |
| `docs/pipeline-rules.md` | Подтверждённые владельцем правила процесса (базовые правила харнесса + проектные). |
| `docs/bug-handling-process.md` | Единый свод: intake → диагностика → фикс → закрытие бага. |
| `docs/backlog.md` | Очередь задач при `ISSUE_BACKEND=none`. |
| `docs/ops-journal.md` | Append-only журнал эксплуатации (пишет `scripts/ops-log.sh`). |
| `docs/state-v4-recovery.md` · `docs/context-budget-and-token-efficiency.md` · `docs/issue-token-lifecycle.md` | Восстановление State V4, контекстный бюджет, связь тикетов с расходом токенов. |
| `docs/guides/` | `MEMORY_CONVENTION`, `BUG_HUNTER_RULES`, `GIT_PUBLISH_RUNBOOK`, `NFR_GUIDE`, `AUTH_GUIDE`, `OPERATIONS_GUIDE`. |
| `scripts/check.sh` | **Единая проверка перед коммитом/публикацией** — сюда проект добавляет свои линты и тесты. |
| `scripts/pipeline-state.sh` · `spec-lint.sh` · `plan-lint.sh` · `pipeline-state-recover-v4.sh` | State V4: гейты, audit, юниты, bound Design/Implementation/Evidence roots; read-only recovery. |
| `scripts/architecture-sdd-verify.pl` · `implementation-tdd-verify.pl` · `tdd-receipt-v1.pl` · `receipt-v1.pl` · `evidence-v1-verify.pl` · `performance-process-v1.pl` · `changelog-append-v1.pl` + `scripts/templates/architecture-evidence-v1/` | Верификаторы dossier/living SDD, execution-grounded TDD, независимых review-receipts и evidence; текстовый claim сам себе authority не выдаёт. |
| `scripts/agent-publish-main.sh` · `agent-git.sh` · `agent-localize-gitdir.sh` | Публикация: PR-режим по умолчанию, прямой main для соло-проектов, strict exact-OID для формального pipeline. |
| `scripts/intake.sh` · `agent-preflight.sh` | Связка «тикет ↔ SPEC_DIR» для `/intake` и preflight тикет-бэкенда. |
| `scripts/pipeline-dashboard.sh` · `dora-metrics.sh` · `ops-log.sh` | Flight Deck (статический HTML), DORA + автономия, журнал эксплуатации. |
| `scripts/context-budget.pl` · `issue-token-lifecycle.pl` | Контекстные пороги 30/50/75 %, ledger `tokens per resolved ticket`, мост GitHub Issues → ledger. |
| `scripts/agent-eval.sh` + `tests/agent-evals/` | Eval-раннер (FAIL→PASS ∧ PASS→PASS по exit-коду) и seed-корпус задач. |
| `scripts/install-git-hooks.sh` + `.githooks/pre-commit` + `scripts/secret-patterns.sh` | Git-хук: append-only журналы, секреты, TODO без тикета. |
| `scripts/coordination-lease.sh` + `coordination/` | Лизы для действительно параллельных сессий (best-effort, advisory). |
| `scripts/agent-worktree-memory-check.sh` | Детектор незакоммиченной памяти агентов в worktree перед его удалением. |
| `specs/` | Артефакты фич и багфиксов (`specs/NNN-slug/`); в чистом харнессе пусто. |
| `tests/harness/` | Self-test харнесса (`bash tests/harness/run-tests.sh`, уровни `--tier fast`/`full`). |

## Требования

- `git`, `bash` ≥ 3.2, `perl` 5 (ядро не требует `jq`/`python3`/`node`).
- `gh` (с выполненным `gh auth login`) — только при `ISSUE_BACKEND=github`.
- Для browser-QA ролей — headed-браузер, доступный агенту (`PROJECT.md §8`); без него UI-проверки
  честно дают `CAPABILITY-BLOCKED`.

## Установка в проект

Модель — **папка-шаблон**: файлы харнесса копируются прямо в корень проекта и дальше живут как
часть его репозитория. Никакого внешнего «центра», синхронизации или подстановки плейсхолдеров нет.

### 1. Что копировать

| Копировать | Зачем |
|---|---|
| `AGENTS.md`, `CLAUDE.md`, `PROJECT.md` | контракт агентов, адаптер Claude Code, паспорт проекта |
| `agents/` | гайд команды, каноны ролей, память |
| `.claude/` | команды, роли, скилл, хуки Claude Code (можно не копировать, если Claude Code не используется) |
| `.githooks/`, `.gitattributes`, `.gitignore` | pre-commit-гард, `merge=union` для append-only журналов, игнор generated-файлов |
| `docs/` | устав, доктрины, гайды, пустые журнал/очередь/правила |
| `scripts/` | state-машина, верификаторы, публикация, метрики, `check.sh` |
| `coordination/`, `specs/` | скелет координации и пустой каталог спек |
| `tests/agent-evals/` | seed-корпус eval-задач (проект пополняет своими) |

**Не копировать:** `README.md`, `TESTING.md`, `CONTRIBUTING.md` — они про сам харнесс, а не про
проект. `tests/harness/` — self-test харнесса, копируется **по желанию** (полезен, если в проекте
будут дорабатывать скрипты харнесса; `scripts/check.sh` гоняет его `fast`-набор, а если каталога
нет — пропускает этот шаг одной строкой SKIP).

**Если в проекте уже есть** `AGENTS.md`, `CLAUDE.md`, `.claude/` (в том числе
`.claude/settings.json`), `.gitignore` или `.gitattributes` — **сливай, не перезаписывай**:
добавь разделы и строки харнесса к существующим. Для каталогов удобно копирование без
перезаписи, после которого конфликтующие файлы сливаются руками:

```bash
cd <корень проекта>
cp -Rn <клон харнесса>/{AGENTS.md,CLAUDE.md,PROJECT.md,agents,.claude,.githooks,.gitattributes,.gitignore,docs,scripts,coordination,specs} .
mkdir -p tests && cp -Rn <клон харнесса>/tests/agent-evals tests/
```

`cp -n` молча пропускает уже существующие файлы: сравни их с версиями харнесса (обычно это
`AGENTS.md`, `CLAUDE.md`, `.claude/settings.json`, `.gitignore`, `.gitattributes`) и слей вручную.

### 2. Заполни `PROJECT.md`

Все поля `ЗАПОЛНИ`: идентичность, стек, команды (тесты — через bash-wrapper, см. «Граница
универсальности»), окружения, тестовые пользователи (пароли — только имена env-переменных),
аутентификация, трекер задач (`ISSUE_BACKEND=none|github`), UI-QA. Значение `-` означает
«осознанно не применимо». Незаполненное поле агент не угадывает — спрашивает владельца.

### 3. Заполни устав

В `docs/constitution.md` заполни слоты `[ЗАПОЛНИ: …]` (периметр данных, слои архитектуры,
замороженные контракты, деплой, конкурентность, дата принятия и владелец), неприменимые
инварианты пометь `N/A` с причиной. Это редакция 1.0.0; дальнейшие изменения инвариантов — только
поправками с записью в журнале (Часть III устава).

### 4. Включи git-хуки и проверки

```bash
bash scripts/install-git-hooks.sh     # один раз на клон: core.hooksPath → .githooks
$EDITOR scripts/check.sh              # в помеченный блок — линт и тесты проекта из PROJECT.md §3
bash scripts/check.sh                 # должно быть зелёным перед каждым коммитом
```

### 5. Первая задача

- Лёгкий путь (по умолчанию): `/speckit.specify "описание"` → `/speckit.plan` → `/speckit.tasks`
  → `/speckit.implement`, затем `bash scripts/agent-publish-main.sh` (PR-режим) — merge жмёт человек.
- Формальный путь (рискованное/регулируемое или по просьбе владельца): `/pipeline "описание"` —
  state-машина не даст пропустить architecture dossier, living SDD, execution-grounded RED/GREEN,
  constitution- и owner-гейты и независимый critical review. Для UI-impact обязательны два
  независимых доказательства: visual-qa (визуал) и ux-route-qa (маршрут). Обрыв →
  `bash scripts/pipeline-state.sh status specs/NNN-slug`.
- Любая хотелка или жалоба одной фразой: `/intake "фраза"` — классификация feature|bugfix, тикет
  в GitHub (при `ISSUE_BACKEND=none` шаг пропускается), спека и stage-1.

Без Claude Code те же шаги выполняются по `AGENTS.md` и скриптам напрямую.

### 6. Метрики

```bash
bash scripts/pipeline-dashboard.sh              # → docs/pipeline-dashboard.html (generated, в git не коммитится)
bash scripts/dora-metrics.sh --days 30          # терминальный срез DORA + автономия
bash scripts/ops-log.sh deploy:done "sha=<sha>" # деплой-скрипт проекта кормит DORA
bash scripts/agent-eval.sh                      # % Resolved на tests/agent-evals/
```

## Проверка самого харнесса

```bash
bash tests/harness/run-tests.sh                # полный self-test (state-машина, линты, верификаторы, хуки, bash -n)
bash tests/harness/run-tests.sh --tier fast    # быстрый dev-набор
bash tests/harness/run-tests.sh <CASE>         # один кейс из tests/harness/cases/
```

Как устроены тесты — [TESTING.md](TESTING.md); как вносить изменения в харнесс —
[CONTRIBUTING.md](CONTRIBUTING.md).
