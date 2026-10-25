---
description: "Generate actionable, dependency-ordered tasks.md from plan. Usage: /speckit.tasks [SPEC_DIR]"
handoffs:
  - label: Analyze For Consistency
    agent: speckit.analyze
    prompt: Run a project analysis for consistency
    send: true
  - label: Implement Project
    agent: speckit.implement
    prompt: Start the implementation in phases
    send: true
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Find plan**: Locate active spec in `specs/` (or from arguments). Load `plan.md` and `spec.md`.

2. **Load design docs**: Also load if exist: `data-model.md`, `contracts/`, `research.md`.

3. **Generate tasks** organized by user story priority:

### Checklist Format (REQUIRED)
```
- [ ] [TaskID] [P?] [Story?] Description with file path
```
- `- [ ]` checkbox always
- `T001, T002...` sequential IDs
- `[P]` if parallelizable
- `[US1], [US2]...` for user story phases
- Clear file paths

### Phase Structure
- **Phase 1**: Setup (структура и зависимости по `PROJECT.md §2/§3`, только если реально нужны)
- **Phase 2**: Foundation (общие библиотеки, контракты, схемы данных)
- **Phase 3+**: User Stories in priority order
  - Within each: contracts → data/migrations → domain/services → interfaces/handlers → UI → e2e
- **Final Phase**: Polish (tests, docs, runbook/deploy-конфиг, если затронуты)

4. **Write tasks.md** to `specs/NNN/tasks.md`.

5. **Report**: total tasks, per-phase counts, parallel opportunities, MVP scope.

## Task Rules
- Each task specific enough for an LLM to complete without extra context
- File paths required for every code task
- Module/component prefix for cross-component awareness
- contracts → data/migrations → domain/services → interfaces/handlers → UI → e2e ordering within each story
- Behavioral task начинается с падающего теста (RED), затем реализация (GREEN)
