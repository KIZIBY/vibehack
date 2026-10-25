---
description: "State V4 Stage 2: adversarial audit, living SDD, Design-Root и approval exact root. Usage: /pipeline-stage2 SPEC_DIR=specs/NNN-slug"
---

# /pipeline-stage2 — Audit / living SDD / Design authority

Arguments: **$ARGUMENTS**

Это тонкий Claude UX-адаптер. Авторитетны `AGENTS.md`, `docs/constitution.md`,
`.claude/skills/pipeline.md` (если доступен), V4 templates/verifiers и exit code
`scripts/pipeline-state.sh`. Без skill-файла исполни fallback ниже без ослабления гейтов.

## Start

Извлеки существующий `SPEC_DIR`, прочитай Stage-1 artifacts и project rules.

```bash
bash scripts/pipeline-state.sh stage-start "$SPEC_DIR" stage-2-audit
bash scripts/spec-lint.sh "$SPEC_DIR"
```

Nonzero означает `BLOCKED`. Re-open завершённой Stage 2 инвалидирует downstream authority и делается
только для реальной ревизии дизайна.

## Canonical dossier и SDD

Используй `scripts/templates/architecture-evidence-v1/` как форму, не сочиняй несовместимые TSV:

- `decisions/AD-NNN.md`: typed constraints, linked FR/NFR, ≥3 candidates, fitness matrix,
  hard-invalid exclusions, Pareto check, selected option или `single-feasible-option`, consequences,
  migration/rollback и revisit triggers; author/reviewer actor+attempt identities различны;
- `traceability.tsv`, `sdd-changelog.tsv`, `roadmap-handoff.md`;
- `plan.md`: implementation steps, exact file boundaries, dependencies, convergence command каждого
  Unit, тестовые намерения и performance budget;
- `reviews/stage-2-audit.md`: constitution/security/performance/architecture/product findings;
- append-only `reviews/learnings.md` section `## stage-2`.

Каждую последующую design-ревизию проводи штатно:

```bash
bash scripts/pipeline-state.sh sdd-append "$SPEC_DIR" <revision> "<change>" "<reason>"
```

Прогони независимые audit-роли параллельно либо последовательно в свежих контекстах. Architecture
reviewer не может совпадать с author actor/attempt. Сначала заверши bytes кандидата и lint, затем
открой receipt, дай reviewer'у проверить exact subject, запиши canonical artifact и закрой receipt:

```bash
bash scripts/plan-lint.sh "$SPEC_DIR"
bash scripts/pipeline-state.sh review-start "$SPEC_DIR" architecture <review-attempt-64hex> <reviewer-actor>
bash scripts/pipeline-state.sh review-finish "$SPEC_DIR" architecture <review-attempt-64hex> "$SPEC_DIR/reviews/architecture-critical-review.md"
bash scripts/pipeline-state.sh design-bind "$SPEC_DIR"
```

Self-authored PASS, совпадающий actor/attempt, устаревший subject или P0/P1/P2 > 0 не authority.
После `design-bind` не меняй design artifacts; изменение требует штатной invalidation/re-review.

## Constitution, units и owner approval

```bash
bash scripts/pipeline-state.sh gate "$SPEC_DIR" "MUST-FLAG: 0 · SHOULD-FLAG: <N> · NEEDS-INFO: 0"
bash scripts/pipeline-state.sh units-set "$SPEC_DIR" "unit-a,unit-b"
```

`units-set` выполняй с реальными именами из plan; для `enterprise` непустой список обязателен. Для
простого feature без отдельной секции Units команда не нужна.

Покажи владельцу план, findings, exact `Design-Root`, candidate choice/alternatives, rollback,
confidence и результаты lint. Только явный ответ на этот exact root:

- Approve:

  ```bash
  bash scripts/pipeline-state.sh approve "$SPEC_DIR" approved <owner>
  bash scripts/pipeline-state.sh stage-done "$SPEC_DIR" stage-2-audit <green|yellow|red> "<проверенное и named uncertainty>"
  ```

- Revise: `bash scripts/pipeline-state.sh approve "$SPEC_DIR" revise <owner>`, затем revised
  candidate проходит новый independent receipt/bind/approval.
- Abort: `bash scripts/pipeline-state.sh approve "$SPEC_DIR" abort <owner>`.

Не вызывай `stage-done` до approval. Заверши точным `next:` из `status`; не подменяй approval
предыдущим общим указанием пользователя.
