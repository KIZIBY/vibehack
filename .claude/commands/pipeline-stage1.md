---
description: "State V4 Stage 1: требования, ограничения и архитектурные кандидаты. Usage: /pipeline-stage1 \"описание\" SPEC_DIR=specs/NNN-slug"
---

# /pipeline-stage1 — Creative / candidate discovery

Feature: **$ARGUMENTS**

Это тонкий Claude UX-адаптер. Источник истины: `AGENTS.md`, `docs/constitution.md`,
`.claude/skills/pipeline.md` (если доступен) и `scripts/pipeline-state.sh`. Без skill-файла исполни
этот byte-exact fallback; provider delegation не является authority.

## Lifecycle

Извлеки `SPEC_DIR` и `SCOPE` (`feature` по умолчанию; `enterprise` ужесточает NFR/Units). Для нового
прогона создай свободный `specs/NNN-slug/reviews` и выполни `init`; существующий прогон сначала
проверь через `status`, не re-open'и завершённую Stage 1 без осознанной ревизии.

```bash
bash scripts/pipeline-state.sh init "$SPEC_DIR" "<описание>" "${SCOPE:-feature}"
bash scripts/pipeline-state.sh stage-start "$SPEC_DIR" stage-1-creative
```

Любой nonzero — `BLOCKED`; state/audit не правь руками.

## Артефактный DoD

Прочитай `CLAUDE.md` только как provider/project adapter, а обязательные правила — из
`AGENTS.md`, `docs/constitution.md`, `docs/guides/NFR_GUIDE.md`, `PROJECT.md` (стек, команды,
окружения, модель входа) и применимых domain-doctrines. Подтверждённые владельцем правила процесса —
`docs/pipeline-rules.md`. Независимые creative/research проходы можно распараллелить; без delegation
выполни их последовательно и отметь `degraded-concurrency`.

Навигацию веди repo-native поиском/Glob/read и подтверждай найденное точечным чтением живых файлов;
отсутствие одного результата поиска не доказывает отсутствие реализации.

Создай:

- `$SPEC_DIR/spec.md`: intent, границы класса, numbered FR/NFR, acceptance, out-of-scope,
  затронутые компоненты/данные/trust boundaries (`## Affected Services`); каждый NFR измерим.
  Раздел `## Authentication & Access` обязателен всегда: по `docs/guides/AUTH_GUIDE.md` §3 со
  значениями из `PROJECT.md §6`, либо явное «N/A (не затрагивает вход/роли/доступ)».
- `$SPEC_DIR/reviews/stage-1-creative.md`: минимум три реально различающихся архитектурных
  кандидата; минимум два viable после hard constraints либо typed `single-feasible-option` с
  доказательством; risks, protected hard axes, assumptions, consequences, rollback/revisit triggers.
- `$SPEC_DIR/reviews/learnings.md`: append-only секция `## stage-1` с фактическими interpretations,
  deviations, tradeoffs и open questions.

Сверь кандидатов с живым репозиторием, не предполагай отсутствие по одному пустому поиску. Hard axes
correctness/data safety/security/compatibility нельзя обменять на скорость или удобство.

## Gate

```bash
bash scripts/spec-lint.sh "$SPEC_DIR"
bash scripts/pipeline-state.sh stage-done "$SPEC_DIR" stage-1-creative <green|yellow|red> "<что проверено; конкретное сомнение и способ проверки для non-green>"
```

`green` допустим только после собственного зелёного lint и при отсутствии named gaps. Non-green
блокирует Stage 2 до typed owner `ack`; отсутствие строки `confidence recorded:` — divergence.
Заверши кратким summary артефактов и точным `next:` из `pipeline-state.sh status`, не вопросом
«что делать дальше?».
