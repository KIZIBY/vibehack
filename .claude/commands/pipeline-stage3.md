---
description: "State V4 Stage 3: implementation с process-grounded RED/GREEN/adjacent и Implementation-Root. Usage: /pipeline-stage3 SPEC_DIR=specs/NNN-slug"
---

# /pipeline-stage3 — Dev / TDD / Implementation authority

Arguments: **$ARGUMENTS**

Это тонкий Claude UX-адаптер. Авторитетны accepted `Design-Root`, `AGENTS.md`, plan/traceability,
`.claude/skills/pipeline.md` (если доступен) и CLI/verifiers. Без skill-файла lifecycle ниже
самодостаточен. Текстовый test report не заменяет process receipt.

## Start и immutable base

Извлеки `SPEC_DIR`, прочитай approved dossier/plan и project rules, затем:

```bash
bash scripts/pipeline-state.sh stage-start "$SPEC_DIR" stage-3-dev
BASE="$(git rev-parse --verify 'HEAD^{commit}')"
bash scripts/pipeline-state.sh implementation-start "$SPEC_DIR" "$BASE" <implementation-attempt-64hex> <implementation-actor>
```

`BASE` обязан быть exact clean pre-implementation commit и совпадать с HEAD на start. Nonzero —
`BLOCKED`, обходить Design-Root/approval/gate нельзя. Re-open Stage 3 инвалидирует старые TDD,
Implementation/Evidence roots, verdict и Unit completion.

## Исполнение Units

Разбей работу только по approved Units/file boundaries. Независимые чтение и правки можно вести в
2–5 изолированных контекстах/worktrees; зависимости — последовательно. Build/test/deploy процессы
всегда по одному. Каждый worker получает exact requirement+decision+test IDs и возвращает summary,
но оркестратор сам подтверждает convergence.

Точку изменения ищи repo-native поиском/Glob/read и подтверждай по живым файлам; неполнота
навигации — не основание ослаблять TDD или architecture authority. Тестовые команды проекта —
`PROJECT.md §3`; в `tdd-run` они передаются через исполняемый bash/perl wrapper из того же раздела.

`implementation-start` — runtime-neutral authority и единственная точка первичной инициализации:
она одним fail-closed batch создаёт отсутствующие `delivery-trace.tsv`, `implementation-map.tsv`,
`test-manifest-v2.tsv` и `delivery-changelog.tsv` из штатных templates. Адаптер не копирует их сам.
При resume/re-open CLI сохраняет существующие canonical bytes и не индексирует их semantic edits.
До первого RED заполни ожидаемые signatures/test/path declarations в trace/map/test manifest и
явно проиндексируй именно подготовленные delivery inputs:

```bash
git add -- "$SPEC_DIR/delivery-trace.tsv" "$SPEC_DIR/implementation-map.tsv" "$SPEC_DIR/test-manifest-v2.tsv"
```

Если init или staging не завершились целиком, RED запрещён; повтори `implementation-start`, который
сначала reconciles собственный orphan transaction и не перезаписывает пользовательские файлы.

Для каждого behavioral requirement сначала зафиксируй ожидаемые assertion/failure signatures и
выполни настоящий assertion-failed RED до production change:

```bash
bash scripts/pipeline-state.sh tdd-run "$SPEC_DIR" "$BASE" <implementation-attempt-64hex> <red-run-64hex> <primary-test-id> red <primary-test-id> <implementation-actor> -- <test-argv...>
```

Setup/compile/network failure не RED. Только после accepted RED меняй код. Затем тот же primary test
на exact candidate и отдельный adjacent regression должны исполниться через тот же runner boundary:

```bash
bash scripts/pipeline-state.sh tdd-run "$SPEC_DIR" "$BASE" <implementation-attempt-64hex> <green-run-64hex> <primary-test-id> green <primary-test-id> <implementation-actor> -- <test-argv...>
bash scripts/pipeline-state.sh tdd-run "$SPEC_DIR" "$BASE" <implementation-attempt-64hex> <adjacent-run-64hex> <primary-test-id> adjacent <adjacent-test-id> <implementation-actor> -- <adjacent-test-argv...>
```

После receipt-run дозаполни результатами canonical `delivery-trace.tsv` и `implementation-map.tsv`;
затем подготовь `performance-manifest-v1.tsv` для каждого runtime workload, `delivery-changelog.tsv`,
`reviews/stage-3-dev.md` и append-only learnings. Non-behavioral requirement
получает typed non-executable classification и inspection evidence, а не выдуманный RED. Ревизии
delivery добавляй только командой ниже. Существующие canonical outputs являются накопленной
delivery authority и изменяются только осознанным заполнением/штатным append, не повторным init.

```bash
bash scripts/pipeline-state.sh delivery-append "$SPEC_DIR" <revision> "<result>" "<evidence>"
```

После закрытия requirement→decision→test→path mapping свяжи exact implementation authority:

```bash
bash scripts/pipeline-state.sh implementation-bind "$SPEC_DIR" "$BASE" <implementation-attempt-64hex>
```

Для каждого Unit отдельно запусти его plan-defined convergence command, прочитай результат и только
потом:

```bash
bash scripts/pipeline-state.sh unit-done "$SPEC_DIR" <unit-name>
```

## Gate и checkpoint C

Запусти все project-required targeted/full checks (`PROJECT.md §3`), `spec-lint`, `plan-lint`,
единый `bash scripts/check.sh` и pre-commit hook (`.githooks/pre-commit`). Затем:

```bash
bash scripts/pipeline-state.sh stage-done "$SPEC_DIR" stage-3-dev <green|yellow|red> "<реально прогнанные checks; named uncertainty>"
```

Stage 4 требует clean committed checkpoint `C`: sole direct child pinned remote `R`, содержащий
реализацию, specs, receipts и актуальные state/audit. Собери его штатным git workflow только после
зелёных проверок; не запускай Stage 4 на dirty tree. Финальный ответ: Units, `Implementation-Root`,
test receipt IDs, checks и точный `next:` из `status`.
