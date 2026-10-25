---
description: Identify underspecified areas in the current feature spec by asking up to 5 targeted clarification questions and encoding answers back into the spec.
handoffs:
  - label: Build Technical Plan
    agent: speckit.plan
    prompt: Create a plan for the spec. The tech stack is described in PROJECT.md §2.
---

## User Input

```text
$ARGUMENTS
```

You **MUST** consider the user input before proceeding (if not empty).

## Outline

1. **Find active spec**: Look for the most recent spec directory in `specs/` (or use SPEC_DIR from arguments). Load `spec.md`.

2. **Ambiguity scan** using taxonomy:
   - Functional Scope & Behavior (goals, out-of-scope, roles)
   - Domain & Data Model (entities, relationships, lifecycles)
   - Interaction & UX Flow (user journeys, error states)
   - Non-Functional Quality (5 категорий `docs/guides/NFR_GUIDE.md`; каждый NFR квантифицирован: метрика/цель/метод/нагрузка — «быстро» и «надёжно» превращай в числа вопросами)
   - Authentication & Access (модель входа и провайдер из `PROJECT.md §6` применимы? источник ролей → маппинг на роли продукта? logout/сессии/ревокация? QA-вход/тест-байпас? — доктрина `docs/guides/AUTH_GUIDE.md`)
   - Integration & Dependencies (внешние системы из `PROJECT.md §2`, сторонние API, вебхуки, события/очереди, контракты и их версии)
   - Edge Cases & Failure Handling (внешняя зависимость или опциональная подсистема недоступна, частичный отказ, конкурентное изменение)
   - Constraints & Tradeoffs (модель размещения данных по инварианту Data Sovereignty в `docs/constitution.md`, ограничения окружений из `PROJECT.md §4`, бюджеты)

   Mark each: Clear / Partial / Missing.

3. **Generate max 5 questions** prioritized by impact:
   - Multiple-choice (2-5 options) with recommended option
   - Present ONE at a time
   - Only ask if answer materially impacts architecture or implementation

4. **After each answer**: Update spec.md immediately:
   - Add to `## Clarifications` section
   - Update relevant spec sections
   - Remove ambiguous statements replaced by clarification

5. **Report**: questions asked, sections updated, coverage summary, suggest next command.

## Rules
- Max 5 questions total
- Present one at a time with recommendation
- Always offer "yes"/"recommended" shortcut
- Respect user "done"/"stop" signals
