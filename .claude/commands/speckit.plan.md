---
description: "Generate technical implementation plan from feature spec. Usage: /speckit.plan [SPEC_DIR]"
handoffs:
  - label: Create Tasks
    agent: speckit.tasks
    prompt: Break the plan into tasks
    send: true
  - label: Create Checklist
    agent: speckit.checklist
    prompt: Create a checklist for the following domain...
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Find spec**: Locate active spec directory in `specs/` (or from arguments). Load `spec.md`.

2. **Load context**: Read `spec.md`, any existing `checklists/requirements.md`, `PROJECT.md`
   (§2 стек и структура, §3 команды, §4 окружения, §6 аутентификация) and `docs/constitution.md`.
   `ЗАПОЛНИ` в нужном поле → спроси владельца; технологию «по умолчанию» не подставляй.

3. **Phase 0 — Research**:
   - Extract unknowns from spec
   - Research best practices for each technology decision within the project stack
   - Write `specs/NNN/research.md` with: Decision, Rationale, Alternatives

4. **Phase 1 — Design**:
   - Extract entities → `specs/NNN/data-model.md`
   - Map entities to the project's storage (схема/таблицы/коллекции по `PROJECT.md §2`, владение
     данными, изоляция доступа, миграции)
   - Generate contracts the feature needs: публичные API (REST/RPC/GraphQL — что использует
     проект), события/сообщения, форматы обмена с внешними системами
   - Write to `specs/NNN/contracts/`

5. **Write plan.md** (после записи — `bash scripts/plan-lint.sh "$SPEC_DIR"`: FAIL = нет REQUIRED-секций или осиротевшие FR/NFR из spec.md — адресуй каждое или перенеси в Out of Scope):

```markdown
# Implementation Plan: [Feature]

## Technical Approach
### Technical Context
- Стек и структура: [из PROJECT.md §2 — языки/фреймворки, каталоги, хранилища, брокеры]
- Команды проверки: [из PROJECT.md §3 — сборка, линт, unit/integration/e2e]
- Затронутые окружения: [из PROJECT.md §4]
### Architecture Decisions
[Key decisions from research; каждое со ссылкой на FR/NFR]

## Components Affected
| Module/Service | Changes | New Files | Migrations |
|----------------|---------|-----------|------------|

## Implementation Steps
1. [Contracts — API/события/схемы, обратно-совместимо]
2. [Data — миграции expand-then-deploy]
3. [Domain/services — бизнес-логика]
4. [Interfaces/handlers — API, консьюмеры, authZ]
5. [UI — если затронут]
6. [Tests & e2e — RED→GREEN на каждое поведение]

## Units of Work
- unit-name: [file boundaries, dependencies, convergence command]

## Files to Create/Modify
[exact paths]

## Contract Changes
[New/modified API, events, schemas — и их совместимость (I-6)]

## Data Migrations
[Migration files, порядок применения, откат/необратимость + бэкап]

## Requirement Coverage
- FR-001: [step/unit]
- NFR-001: [step/unit + как измеряется]

## Known Risks
[Risks from spec + research]

## Dependencies
[External systems from PROJECT.md §2, auth provider from PROJECT.md §6, other teams/components]
```

6. **Report**: plan file path, artifacts generated, suggest `/speckit.tasks`.

## Key Rules
- Use absolute paths
- Map every requirement to implementation
- Identify cross-component dependencies
- Технология вне `PROJECT.md §2` — только как явное Architecture Decision с альтернативами
