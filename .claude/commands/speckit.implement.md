---
description: "Execute implementation by processing tasks defined in tasks.md. Usage: /speckit.implement [SPEC_DIR]"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Find tasks**: Locate active spec in `specs/`. Load tasks.md, plan.md.

2. **Check checklists** (if `specs/NNN/checklists/` exists):
   - Count total/completed/incomplete items
   - If incomplete: ask user to proceed or stop

3. **Load implementation context**:
   - tasks.md: task list and execution plan
   - plan.md: tech stack, architecture, file structure
   - data-model.md: entities (if exists)
   - contracts/: API specs (if exists)
   - `PROJECT.md`: §2 стек и каталоги, §3 команды сборки/линта/тестов (`ЗАПОЛНИ` → спроси владельца)

4. **Project setup** (только если задачи этого требуют):
   - Verify `.gitignore` covers build artifacts, env-файлы и секреты стека проекта
   - Verify ignore-файлы сборки/контейнеров, если проект их использует
   - Не меняй структуру workspace/монорепо без задачи в tasks.md

5. **Execute tasks phase-by-phase**:
   - Phase 1: Setup (project structure, dependencies)
   - Phase 2: Foundation (shared libs, contracts, DB schemas)
   - Phase 3+: User stories (contracts → data/migrations → domain/services → interfaces/handlers → UI → e2e)
   - Final: Polish (tests, docs, deploy config if affected)

6. **Implementation rules**:
   - Follow project conventions: `docs/constitution.md`, existing module patterns, Clean Architecture
   - TDD when requested: RED (assertion-failed) → GREEN on every behavioral task
   - Mark completed tasks as `[X]` in tasks.md
   - Halt on non-parallel task failure

7. **Completion validation**:
   - Build, lint/type-check, unit and integration tests — exact commands from `PROJECT.md §3`
     (поле `-` = N/A, отметь явно; `ЗАПОЛНИ` = blocker, спроси владельца)
   - `bash scripts/check.sh` (единый check перед коммитом)
   - Report final status with real counts (PASS/FAIL/SKIP — skip ≠ pass)
