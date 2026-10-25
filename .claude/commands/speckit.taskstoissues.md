---
description: "Convert tasks from tasks.md into issues through the active ISSUE MODE (GitHub Issues or none). Usage: /speckit.taskstoissues [SPEC_DIR]"
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Find tasks**: Resolve the repository root (`git rev-parse --show-toplevel`), locate the active
   spec in `specs/` (or use `SPEC_DIR` from arguments), and load `tasks.md`.

2. **Resolve the active backend**: the only issue contract is `agents/README.md` →
   «Режим задач (ISSUE MODE)». Resolve `ISSUE_BACKEND` exactly by the rule stated there:
   environment variable `ISSUE_BACKEND` → otherwise the first line matching
   `ISSUE_BACKEND=github|none` in `PROJECT.md` (§7) → otherwise `none`. Do not infer a backend from
   the git remote, installed tools, or prior knowledge.

   - **`none`** → stop before any mutation with the typed outcome
     `CAPABILITY-BLOCKED: issue-backend-none` (per task — `issue: N/A (ISSUE_BACKEND=none)`) and
     report: 0 issues created; the work stays in `$SPEC_DIR/tasks.md`; if the owner wants queue
     entries, the project queue is `docs/backlog.md` (suggest the entries in its format, do not write
     them unasked). Never imitate issue creation, never print fake issue numbers, never call `gh`.
   - **unknown value** → fail closed: `BLOCKED: issue-backend-invalid`, no mutations.
   - **`github`** → continue. If the ISSUE MODE section or any command it requires is missing,
     ambiguous, or unavailable (no `gh`, no auth, `origin` is not a GitHub repository), stop with
     `BLOCKED: issue-backend-unavailable`. The repository is always the one from `origin`; never
     redirect to another repository, mirror an issue, or switch transport.

3. **Preflight**: Run the exact preflight command declared in ISSUE MODE. Any non-zero result
   blocks all issue mutations for this run.

4. **For each task**:
   - Build a title that starts with the author token required by ISSUE MODE (`[<роль>] …`, e.g.
     `[developer]`) from the task description, and a body with file paths, dependencies, acceptance
     criteria and a link back to `$SPEC_DIR`.
   - Run the declared dedup command before mutation. Reuse/report an existing matching issue instead
     of creating a duplicate.
   - Otherwise run the declared create command, then its verify-read command. A dedup, create, or
     verify failure is `BLOCKED: issue-backend-unavailable`; do not retry through another transport.
   - Add labels (phase, component, priority) or a milestone only when ISSUE MODE explicitly
     declares executable commands for that metadata. Otherwise omit it and report the capability
     gap.
   - Never put secrets, tokens, passwords or machine-specific paths into an issue body.

5. **Report**: per task — created / reused / blocked with the issue reference returned by the
   verify-read (not by memory), plus the totals.
