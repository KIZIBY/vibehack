---
name: pipeline
description: 4-stage feature, behavioral-bugfix and enterprise delivery pipeline. Runs Creative → Audit → Dev → Quality with State V4 evidence gates. Use /pipeline command to start.
---

# /pipeline Feature Development Pipeline

> Этот файл — UX-адаптер Claude. Источник истины и механические гейты runtime-neutral:
> корневой `AGENTS.md`, артефакты `specs/` и `scripts/pipeline-state.sh`; другой кодовый агент
> исполняет тот же протокол напрямую либо через собственный тонкий адаптер.

## Usage

```
/pipeline "описание фичи"
```

## Requires

Delegation capability is optional. If Claude Agent Teams are unavailable, run independent roles
sequentially in fresh contexts and mark `degraded-concurrency`; authority remains in artifacts and
Bash/Perl verifiers, not in the provider feature.

## Overview

```
/pipeline "описание фичи"
    │
    Stage 1: Creative Team ────→ spec.md + architecture candidates
    │
    Stage 2: Audit Team ───────→ dossier + living SDD + Design-Root
    │         ┌─ USER APPROVAL ─┐
    │         │ (показывает план)│
    │         └─────────────────┘
    │
    Stage 3: Dev Team ─────────→ real RED→GREEN + Implementation-Root
    │   ▲
    │   │ retry (max 2) + список доработок
    │   │
    Stage 4: Quality Team ─────→ independent critical/performance evidence + Evidence-Root
                                  вердикт: PASS / FAIL

    FAIL + retry < 2  → назад в Stage 3
    FAIL + retry = 2  → спрашивает user
    PASS              → финальный отчёт + готовый feature branch
```

## Artifacts

```
specs/NNN-feature-name/
├── spec.md                        # Stage 1: что строим (WHAT/WHY)
├── plan.md                        # Stage 2: как строим (HOW)
├── decisions/AD-NNN.md            # typed candidates, fitness matrix, choice/rollback
├── traceability.tsv               # requirement → decision → test intent
├── sdd-changelog.tsv              # append-only living design revisions
├── delivery-trace.tsv             # execution-grounded RED/GREEN delivery chain
├── implementation-map.tsv         # requirement/decision/test → exact implementation paths
├── delivery-changelog.tsv         # Stage-3 reviewed-no-change / delivery revisions
├── roadmap-handoff.md             # explicit future scope, not hidden implementation
├── state.md                       # State-машина: чекбоксы этапов + гейты (ведёт pipeline-state.sh)
├── audit.md                       # Append-only журнал событий пайплайна (кто/когда/что решил)
├── data-model.md                  # Stage 2: entities
├── tasks.md                       # Stage 3: task breakdown
├── research.md                    # Stage 2: technology decisions
├── contracts/                     # Stage 2: API specs
└── reviews/
    ├── stage-1-creative.md        # Creative Team отчёт
    ├── stage-2-audit.md           # Audit findings
    ├── stage-3-dev.md             # Dev decisions + competency matrix
    ├── stage-4-quality.md         # QA вердикт
    ├── architecture-critical-review.md # independent review bound to design candidate
    ├── critical-code-review.md    # independent exact-C correctness/cleanliness/security review
    ├── performance-review.md      # comparable benchmark/budget or typed N/A
    └── requirements-matrix.md     # Requirement ↔ code mapping
```

## State-машина и детерминированные гейты

`scripts/pipeline-state.sh` ведёт versioned `state.md`/append-only `audit.md` per SPEC_DIR. Fresh
run использует State V4 + registered delivery contract `architecture-evidence-v1`; V1/V2/V3
inspectable, но mutation/bind/publish требуют explicit forward migration. `stage-start`: `[ ]→[-]`,
`[-]` = resume no-op; re-open инвалидирует downstream roots/receipts по scope. Stage 2 не завершается
без verified architecture dossier, living SDD/traceability, independent architecture receipt,
`Design-Root` и owner approval exact root. Stage 3 не стартует без approve + `MUST-FLAG:0` /
`NEEDS-INFO:0`; behavioral work требует runner-grounded RED exact pre-root → GREEN exact candidate +
adjacent regression, closed implementation map и `Implementation-Root`. Self-authored TSV literals
не execution evidence. Stage 4 требует separate critical-code and performance reviewer attempts exact
C, P0/P1/P2=0, then `Evidence-Root` before Quality-HEAD. UI-impact дополнительно требует два
независимых доказательства: visual-qa (визуал) и ux-route-qa (measured journey) в разных attempts на
одной served version; missing headed-browser capability = typed `CAPABILITY-BLOCKED`. Deploy-bound
гейт для этих доказательств не поставлен — не выдавай его за существующий.

Release shape остаётся exact `R→C→H→B`: C — clean Stage-3 checkpoint sole child pinned R; H — sole
single-parent evidence child C; B — state/audit-only child H. После `quality-head` generic events и
refresh mutations запрещены. `check publish` повторно вычисляет applicable roots/receipts, проверяет
immutable H→B, raw non-symbolic binding и C/H/B graph/metadata. Malformed state/CLI = exit 2,
валидный BLOCKED = 1. `spec-lint.sh` и `plan-lint.sh` обязательны на своих стадиях.

**Scope** (`SCOPE=` при запуске, хранится в state.md): `feature` (default) · `bugfix`
(нетривиальный баг проходит тот же V4 contract и дополнительно следует
`docs/bug-handling-process.md`; это не bypass) · `enterprise` (NFR все 5 категорий
`docs/guides/NFR_GUIDE.md`, Units обязательны, matrix без PARTIAL). Units опциональны для
`feature|bugfix`, но три roots и quality gates обязательны для всех scope.

**Confidence-светофор (fail-safe эскалация).** Каждая стадия завершается декларацией: `stage-done <stage> [green|yellow|red] "<причина>"`. **green** — сигналы зелёные, нет named-сомнений; **yellow/red** — конкретное falsifiable сомнение/дыра. Non-green блокирует следующий `check` до owner `ack`; ack допустим только для завершённой стадии. Green/«—» не unlock. `PIPELINE_SPEC_DIR` остаётся opt-in, но State V4 publisher требует три roots, HEAD-binding и literal-OID push; V1–V3 publish не авторизуют. Flight Deck показывает worst-of confidence.

**Learnings ritual**: каждый этап дописывает `reviews/learnings.md` (Interpretations / Deviations / Tradeoffs / Open questions); stage-4 Technical Writer (tech-writer) консолидирует и предлагает владельцу, что закрепить в `AGENTS.md`, `docs/pipeline-rules.md` или канонах `agents/roles/` — закрепление только с одобрения владельца.

**Flight Deck (визуализация)**: `bash scripts/pipeline-dashboard.sh` → `docs/pipeline-dashboard.html` — статический per-run trace-дашборд из `specs/*/state.md + audit.md`: обзор прогонов, этапы/гейты/юниты, roots, таймлайн событий с длительностями (`X:start`→`X:done`). Субагенты логируются через `pipeline-state.sh event` (`agent:<имя>`). Если среда вернула фактический расход субагента — запиши `bash scripts/pipeline-state.sh event "$SPEC_DIR" "usage:agent:<имя>" "tokens=<N> source=subagent-report"` (только реальные числа из отчёта среды; нет источника — не пиши, фабрикация запрещена). Для V4 Stage 4 все `agent:*`/`usage:*` события обязаны попасть в audit **до** commit H и `quality-head`; после H команда `event` fail-closed. Никаких демонов — перегенерируй в любой момент.

## Stage 1: Creative Team
- **Lead**: Creative Director (Opus)
- **Teammates**: Brainstormer, Critical Analyst, system-analyst, hard-critic (all Sonnet)
- **Architecture output**: constraints + FR/NFR, ≥3 candidates, ≥2 viable alternatives or
  `single-feasible-option`, protected hard axes and revisit triggers
- **Gate**: Automatic → Stage 2

## Stage 2: Audit Team
- **Lead**: Audit Director (Opus)
- **Teammates**: Security Reviewer, Performance Analyst, Architecture Reviewer, AI Reviewer, Frontend Reviewer (all Sonnet)
- **Authority**: typed fitness matrix rejects hard violations/Pareto-dominated choice; living SDD +
  architecture receipt bind Design-Root
- **Gate**: USER APPROVAL exact Design-Root — shows dossier/plan/findings, asks Approve / Revise / Abort

## Stage 3: Dev Team
- **Lead**: Tech Lead (Opus)
- **Adaptive composition** from `.claude/agents/`:
  - backend-developer, db-expert, frontend-developer, ai-engineer, integration-engineer, test-runner, devops-deployer
  - Только роли затронутых слоёв; слой, которого нет в `PROJECT.md §2` (`-`), — роль N/A
- **Order**: contracts → data/migrations → domain/services → interfaces/handlers → UI → e2e
- **TDD authority**: real assertion-failed RED on pre-implementation root, then same-test
  assertion-passed GREEN exact candidate + adjacent regression; bind closed delta to Implementation-Root
- **Gate**: Automatic → Stage 4

## Stage 4: Quality Team
- **Lead**: QA Director (Opus)
- **Teammates**: Requirements Validator, Test Engineer, code-reviewer, Technical Writer (Sonnet)
- **Independent receipts**: critical-code + performance actors differ from implementation actor;
  correctness/cleanliness/maintainability/architecture/security/testability/complexity/performance,
  P0/P1/P2=0. UI-impact routes to distinct visual-qa + ux-route-qa sessions or stays `CAPABILITY-BLOCKED`
- **Boundary**: exact R→C→H→B; C — sole child pinned remote R, H — sole evidence child exact C,
  Evidence-Root bound before `quality-head`; after H only state/audit B + direct bind
- **Retry**: FAIL + retry < 2 → narrow Dev Team → retry Quality

## Agent Inventory

Специалисты (`.claude/agents/`, стек и каталоги — из `PROJECT.md §2`, команды — из `PROJECT.md §3`):

| Agent | Specialization | Files |
|-------|---------------|-------|
| backend-developer | Серверная бизнес-логика, API-хендлеры, события, доступ к данным | backend-каталог из `PROJECT.md §2` |
| db-expert | Схема, миграции, запросы и индексы, изоляция данных, векторный поиск | каталог схемы/миграций |
| frontend-developer | UI, формы, API-клиент и сессия, адаптивность, доступность | frontend-каталог |
| ai-engineer | LLM/ML-фичи: промпты, RAG, evals, бюджеты, безопасность | модули AI-фич |
| integration-engineer | Внешние системы: сторонние API, auth-провайдер, вебхуки, почта, очереди | адаптеры интеграций |
| test-runner | Unit/integration-тесты, честный PASS/FAIL/SKIP | тестовые каталоги |
| code-reviewer | Constitution Gate, качество, безопасность | review only |
| system-analyst | Анализ архитектурного влияния | analysis only |
| hard-critic | Devil's advocate, YAGNI | challenge only |
| devops-deployer | Сборка, окружения, деплой/откат, post-deploy verify | инфраструктурные конфиги |

Ролевые агенты с канонами в `agents/roles/` (тонкие стабы в `.claude/agents/`): developer,
repo-hygiene, tech-writer, visual-qa, ux-route-qa, workflow-qa, chaos-qa, regression-qa.

## Cost Estimate

| Stage    | Teammates       | ~Cost  |
|----------|-----------------|--------|
| Creative | 4 + Opus lead   | $4-6   |
| Audit    | 5 + Opus lead   | $5-7   |
| Dev      | 2-5 + Opus lead | $5-10  |
| Quality  | 4 + Opus lead   | $3-5   |
| **Total**|                 | **~$17-28** |

## Error Handling
- Teammate crashed: Lead spawns replacement after 5 min idle
- Stage crashed / сессия прервана: **resume по state.md** — `bash scripts/pipeline-state.sh status specs/NNN-slug` печатает `next:` (первый незакрытый этап + причина, если BLOCKED); `/pipeline` с существующим SPEC_DIR продолжает оттуда, не начиная с нуля. Конец batch/context/turn не означает, что исходная цель выполнена, и не разрешает generic «что дальше?»: текущий оркестратор вручную перечитывает последнюю явную цель, повторно проверяет полный scope и продолжает либо доказывает `DONE | WAIT_OWNER | BLOCKED`. Каждый status/final содержит 1–3 ranked advisory recommendations, не меняющих authoritative action. Автоматического продолжения в новой сессии нет: resume выполняется вручную через `status` того же `SPEC_DIR`.
- Agent Teams unavailable: fallback to regular subagents

## Individual Stage Commands
- `/pipeline-stage1 "feature" SPEC_DIR=specs/NNN-slug`
- `/pipeline-stage2 SPEC_DIR=specs/NNN-slug`
- `/pipeline-stage3 SPEC_DIR=specs/NNN-slug`
- `/pipeline-stage4 SPEC_DIR=specs/NNN-slug`

## Speckit Integration
For lighter-weight spec workflow (without adversarial teams):
- `/speckit.specify "feature"` → spec.md
- `/speckit.clarify` → refine spec
- `/speckit.plan` → plan.md
- `/speckit.tasks` → tasks.md
- `/speckit.analyze` → consistency check
- `/speckit.checklist [domain]` → requirements quality
- `/speckit.implement` → execute tasks
- `/speckit.constitution` → project principles
- `/speckit.taskstoissues` → issues через `agents/README.md` → «Режим задач (ISSUE MODE)» (`ISSUE_BACKEND=github`; при `none` — typed отказ без создания issues)
