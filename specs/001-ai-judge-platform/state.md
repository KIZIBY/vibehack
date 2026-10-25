# Pipeline State — AI-судья: платформа оценки соревнований и домашних заданий

- State-Version: 4
- Delivery-Contract: architecture-evidence-v1
- SPEC_DIR: specs/001-ai-judge-platform
- Scope: feature
- Ticket: —
- Started: 2026-10-25T09:26:35Z
- Updated: 2026-10-25T09:26:35Z
- Design-Root: —
- Implementation-Root: —
- Evidence-Root: —
- Quality-HEAD: —

## Stages

- [ ] stage-1-creative
- [ ] stage-2-audit
- [ ] stage-3-dev
- [ ] stage-4-quality

## Gates

- constitution-gate: —
- user-approval: —
- quality-verdict: —

## Confidence

- confidence-stage-1-creative: —
- confidence-stage-2-audit: —
- confidence-stage-3-dev: —
- confidence-stage-4-quality: —

> Файл ведёт `scripts/pipeline-state.sh` — чекбоксы, гейты и confidence руками не редактируются;
> журнал событий — `audit.md` рядом (append-only). Confidence — fail-safe сигнал стадий:
> non-green блокирует следующий этап до `ack` владельца; green ничего не разблокирует;
> «—» = не задекларирован (поведение как до фичи).
