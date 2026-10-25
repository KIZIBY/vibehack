# AD-001 — Replace with the architecture decision title

- Contract-Version: architecture-decision-v1
- Decision-ID: AD-001
- Status: accepted
- Requirements: FR-003, FR-004, FR-005, FR-006, FR-009, FR-014, NFR-001, NFR-002, NFR-003
- Author-Actor: {{AUTHOR_ACTOR}}
- Author-Attempt: {{AUTHOR_ATTEMPT_64HEX}}
- Reviewer-Actor: {{REVIEWER_ACTOR}}
- Reviewer-Attempt: {{REVIEWER_ATTEMPT_64HEX}}
- Selected-Option: OPT-001
- Selection-Status: selected

## Problem And Class Boundary

Describe the decision boundary, the invariant being protected and what remains outside this decision.

## Hard Constraints

- Correctness, data safety, security and compatibility must pass before cost or speed is considered.
- The implementation must remain portable to Bash 3.2 plus Perl.

## Fitness Functions

| ID | Axis | Direction | Unit | Class | Threshold |
|---|---|---|---|---|---|
| FF-001 | correctness | bool | result | hard | pass |
| FF-002 | data-safety | bool | result | hard | pass |
| FF-003 | security | bool | result | hard | pass |
| FF-004 | compatibility | bool | result | hard | pass |
| FF-005 | cost | min | changes | soft | <=100 |
| FF-006 | speed | min | days | soft | <=30 |

## Options

### OPT-001 — Minimal content-rooted contract

Bind the smallest closed artifact set and recompute it at every authority boundary.

### OPT-002 — Broader state schema

Store more detail in state at the cost of a larger compatibility and migration surface.

### OPT-003 — Prompt-only guidance

Keep the behavior advisory; this generated option fails the executable correctness predicate.

## Constraint Matrix

| Option | Requirement | Result | Evidence |
|---|---|---|---|
| OPT-001 | FR-003 | pass | checked:FR-003 |
| OPT-001 | FR-004 | pass | checked:FR-004 |
| OPT-001 | FR-005 | pass | checked:FR-005 |
| OPT-001 | FR-006 | pass | checked:FR-006 |
| OPT-001 | FR-009 | pass | checked:FR-009 |
| OPT-001 | FR-014 | pass | checked:FR-014 |
| OPT-001 | NFR-001 | pass | checked:NFR-001 |
| OPT-001 | NFR-002 | pass | checked:NFR-002 |
| OPT-001 | NFR-003 | pass | checked:NFR-003 |
| OPT-002 | FR-003 | pass | checked:FR-003 |
| OPT-002 | FR-004 | pass | checked:FR-004 |
| OPT-002 | FR-005 | pass | checked:FR-005 |
| OPT-002 | FR-006 | pass | checked:FR-006 |
| OPT-002 | FR-009 | pass | checked:FR-009 |
| OPT-002 | FR-014 | pass | checked:FR-014 |
| OPT-002 | NFR-001 | pass | checked:NFR-001 |
| OPT-002 | NFR-002 | pass | checked:NFR-002 |
| OPT-002 | NFR-003 | pass | checked:NFR-003 |
| OPT-003 | FR-003 | pass | checked:FR-003 |
| OPT-003 | FR-004 | pass | checked:FR-004 |
| OPT-003 | FR-005 | pass | checked:FR-005 |
| OPT-003 | FR-006 | pass | checked:FR-006 |
| OPT-003 | FR-009 | pass | checked:FR-009 |
| OPT-003 | FR-014 | pass | checked:FR-014 |
| OPT-003 | NFR-001 | pass | checked:NFR-001 |
| OPT-003 | NFR-002 | pass | checked:NFR-002 |
| OPT-003 | NFR-003 | pass | checked:NFR-003 |

## Fitness Matrix

| Option | FF-001 | FF-002 | FF-003 | FF-004 | FF-005 | FF-006 |
|---|---|---|---|---|---|---|
| OPT-001 | pass | pass | pass | pass | 5 | 4 |
| OPT-002 | pass | pass | pass | pass | 8 | 6 |
| OPT-003 | fail | pass | pass | pass | 12 | 2 |

## Chosen Decision

Choose OPT-001 because it satisfies every requirement and hard fitness predicate and is not
Pareto-dominated by another viable option. Cost or speed never overrides a protected hard failure.

## Migration And Rollback

- Migrate only through an explicit forward plan that preserves readable history.
- Rollback must retain readers for every already-written contract version.

## Consequences

- Authority becomes reproducible from repository bytes.
- Any design edit invalidates the previously computed root and requires a new review.

## Disconfirming Evidence And Revisit Triggers

Revisit if two supported platforms compute different manifests, the verifier exceeds its budget, or
a valid design cannot be represented without weakening a hard predicate.
