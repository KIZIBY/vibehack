---
description: "Create or update a feature specification from a natural language description. Usage: /speckit.specify \"описание фичи\""
handoffs:
  - label: Build Technical Plan
    agent: speckit.plan
    prompt: Create a plan for the spec. The tech stack is described in PROJECT.md §2.
  - label: Clarify Spec Requirements
    agent: speckit.clarify
    prompt: Clarify specification requirements
    send: true
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

The text the user typed after `/speckit.specify` is the feature description.

1. **Generate a concise short name** (2-4 words) for the feature:
   - Action-noun format (e.g., "order-export", "profile-settings", "rbac-system")
   - Preserve technical terms

2. **Determine feature number** (если `SPEC_DIR=` передан аргументом, например из `/intake`, —
   используй его и номер не считай):
   - Найди максимальный номер среди каталогов `specs/NNN-*`
   - Use next number: NNN (001, 002, ...)
   - Create: `specs/NNN-<slug>/` and `specs/NNN-<slug>/checklists/`
   - Set SPEC_FILE = `specs/NNN-<slug>/spec.md`

3. **Parse the feature description**:
   - Extract: actors, actions, data entities, constraints
   - Map to the project architecture (`PROJECT.md §2` + живая структура репозитория)
   - Identify which modules/services/components are affected

4. **Write spec.md** following this structure:

```markdown
# Feature: [Name]

<!-- Строка ниже необязательна: только если ключ тикета уже известен (для GitHub Issues — #456);
прогон связывается командой pipeline-state.sh link-ticket <SPEC_DIR> <KEY>, spec-lint предупредит о
рассинхроне маркера со state.md. Ключ неизвестен, фича без тикета или ISSUE_BACKEND=none — строку
не пиши (при вызове из /intake маркер ставит /intake). Формат — bullet, не blockquote. -->
- Источник: тикет <KEY>

## Overview
[1-2 paragraphs describing the feature and its business value]

## User Stories
- As a [role], I want [action] so that [benefit]

## Functional Requirements
FR-001: [Testable requirement]
FR-002: ...

## Non-Functional Requirements
[Доктрина: docs/guides/NFR_GUIDE.md — 5 категорий (performance / scalability / reliability /
observability / security), КАЖДЫЙ NFR квантифицирован: метрика — целевое значение — метод
измерения — условия. «Быстро/надёжно/безопасно» без числа запрещены. Неприменимая категория —
явное N/A. Security-вход/роли — в секции Authentication & Access, не здесь.]
NFR-001 (performance): [метрика — цель — как мерить — при какой нагрузке]

## Authentication & Access
[ОБЯЗАТЕЛЬНАЯ секция, доктрина: docs/guides/AUTH_GUIDE.md §3; значения — из PROJECT.md §6. Если
фича затрагивает вход/пользователей/роли/доступ: способ входа (модель входа и провайдер из
PROJECT.md §6; отклонение — только решением владельца); источник ролей и маппинг на роли продукта
(группа/роль администраторов — PROJECT.md §6); logout/сессии/ревокация при деактивации; тест-доступ
для QA (роли — PROJECT.md §5, пароли — только имена env-переменных). Если НЕ затрагивает — одна
строка: "N/A (не затрагивает вход/роли/доступ)".]

## Affected Services
- [module/service/component]: [what changes]

## Data Entities
- [Entity]: [fields, relationships]

## Edge Cases
- [scenario]: [expected behavior]

## Out of Scope
- [what is NOT included]

## Assumptions
- [documented assumptions]

## Success Criteria
- [measurable outcome]
```

5. **Specification Quality Validation**:
   - Create `specs/NNN-<slug>/checklists/requirements.md` with quality checks
   - Validate: no implementation details, testable requirements, measurable success criteria
   - Max 3 [NEEDS CLARIFICATION] markers for critical decisions only
   - If clarifications needed, present as multiple-choice questions
   - **Детерминированные гейты:** `bash scripts/pipeline-state.sh init "$SPEC_DIR" "<фича>"` (state.md + audit.md — speckit лёгкий трек: этапные чекбоксы/гейты /pipeline им не проходятся, но аудит-след и resume работают; для существующего state.md init — no-op) + `bash scripts/spec-lint.sh "$SPEC_DIR"` — FAIL → дополни spec.md до выхода

6. **Report**: Output spec file path, readiness status, suggest `/speckit.clarify` or `/speckit.plan` next.

## Guidelines
- Focus on **WHAT** users need and **WHY**
- Avoid HOW (no tech stack, APIs, code structure in spec)
- Written for business stakeholders, not developers
- Every requirement must be testable
- **Auth by default**: если у продукта есть пользовательский вход — модель входа берётся из
  `PROJECT.md §6` (доктрина `docs/guides/AUTH_GUIDE.md`); отклонение от неё (самодельный логин,
  демо-режим) — только явным решением владельца, зафиксированным в Authentication & Access +
  Assumptions; `ЗАПОЛНИ` в §6 → вопрос владельцу, а не догадка
