---
description: Perform cross-artifact consistency and quality analysis across spec.md, plan.md, and tasks.md. READ-ONLY.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Goal

Identify inconsistencies, duplications, ambiguities, and underspecified items across `spec.md`, `plan.md`, `tasks.md` before implementation. READ-ONLY — no file modifications.

## Execution Steps

1. **Find artifacts**: Locate active spec in `specs/`. Load spec.md, plan.md, tasks.md. Прогони детерминированные линты и включи их вывод в отчёт: `bash scripts/spec-lint.sh "$SPEC_DIR"` + `bash scripts/plan-lint.sh "$SPEC_DIR"` (traceability FR/NFR → plan).

2. **Build semantic models**:
   - Requirements inventory from spec.md
   - Task coverage mapping from tasks.md
   - Architecture decisions from plan.md

3. **Detection passes** (max 50 findings):
   - **Duplication**: near-duplicate requirements
   - **Ambiguity**: vague terms without metrics (fast, scalable, robust)
   - **Underspecification**: requirements without tasks, tasks without file paths
   - **Coverage gaps**: requirements with zero tasks, orphan tasks
   - **Inconsistency**: terminology drift, conflicting decisions, events/contracts declared in plan but missing in tasks (or vice versa)
   - **Cross-component**: module/service/component referenced in plan but no tasks for it

4. **Severity**: CRITICAL / HIGH / MEDIUM / LOW

5. **Output report** (Markdown, no file writes):

```
## Specification Analysis Report

| ID | Category | Severity | Location(s) | Summary | Recommendation |
|----|----------|----------|-------------|---------|----------------|

## Coverage Summary
| Requirement Key | Has Task? | Task IDs | Notes |

## Metrics
- Total Requirements / Tasks / Coverage %
- Ambiguity / Duplication / Critical counts

## Next Actions
[Specific command suggestions]
```

6. **Offer remediation**: Ask if user wants suggested edits (don't apply automatically).
