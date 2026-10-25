---
description: "State V4 Stage 4: independent critical/performance receipts, Evidence-Root и exact R→C→H→B. Usage: /pipeline-stage4 SPEC_DIR=specs/NNN-slug"
---
# /pipeline-stage4 — Quality / Evidence authority

Arguments: **$ARGUMENTS**

Это тонкий Claude UX-адаптер. Авторитетны `AGENTS.md`, `docs/constitution.md`, accepted roots,
`.claude/skills/pipeline.md` (если доступен), canonical evidence templates/verifiers и exit code
state-machine. Без skill-файла исполни byte-exact fallback ниже. Никакая проза reviewer'а не
заменяет receipt exact checkpoint `C`.
## Start и write boundary

Stage 3 заранее обязан оставить clean committed checkpoint `C`, который является sole direct child
pinned remote `R`. Извлеки существующий `SPEC_DIR` и выполни:

```bash
bash scripts/pipeline-state.sh stage-start "$SPEC_DIR" stage-4-quality
```

Команда фиксирует exact `C`; nonzero означает `BLOCKED`. До `Evidence-Root` разрешены только
canonical Stage-4 artifacts и штатные state/audit mutations. Нужна правка production-кода, теста,
design/delivery artifact, общей документации или performance manifest — запиши FAIL и re-open Stage
3. Не делай add→revert/intermediate/merge историю: `H` должен быть единственным evidence child `C`.

## 1. Independent critical code review

Reviewer actor и attempt обязаны отличаться от implementation actor/attempt. Открой receipt до
передачи exact `C` reviewer'у, затем создай
`$SPEC_DIR/reviews/critical-code-review.md` строго по template
`scripts/templates/architecture-evidence-v1/critical-code-review.md`. Все axes имеют execution/file
evidence; P0/P1/P2 должны быть 0.

```bash
bash scripts/pipeline-state.sh review-start "$SPEC_DIR" critical-code <critical-attempt-64hex> <critical-reviewer-actor>
bash scripts/pipeline-state.sh review-finish "$SPEC_DIR" critical-code <critical-attempt-64hex> "$SPEC_DIR/reviews/critical-code-review.md"
```

## 2. Independent performance review

Используй другой attempt, отличный и от implementation, и от critical review. Actor также не может
совпадать с implementation actor.

```bash
bash scripts/pipeline-state.sh review-start "$SPEC_DIR" performance <performance-attempt-64hex> <performance-reviewer-actor>
```

Для runtime/verification impact процессный путь обязателен: manifest был подготовлен в Stage 3,
а команда сама исполняет все workload immutable manifest в canonical порядке, пишет aggregate `reviews/performance-review.md`
и добавляет одну reserved process start/finish пару, связанную с полным workload-set. Fail-closed предел process v1 — не более 64 workloads и 256 суммарных
base/candidate измерений и dependency probes; общий wall deadline — 600 секунд и прерывает уже
запущенный child. Deadline считается monotonic от старта producer и охватывает Git preparation,
immutable snapshot/helper work и workloads; subprocess исполняются через nonblocking pipes с kill
всей process group. До canonical rename действуют hard caps 16 MiB как на каждый workload result,
так и на aggregate; timeout/cap не оставляет PASS artifact и не меняет audit. Verifier повторяет
byte/cap проверки под собственным monotonic deadline 120 секунд, включая Git и immutable receipt helpers.
Manifest задаёт полное
разбиение implementation-map: `C workload path impact-class`
для measured objective (`product-runtime|verification-runtime|control-plane-runtime`) и
`N path reason-class` для остальных paths (closed set: `non-executed-content`, `test-support-only`,
`delivery-evidence-only`, `outside-declared-performance-objective`). `C∪N` обязан совпадать с map без
пропусков, overlap и extra; сам manifest входит ровно один раз как `N ... delivery-evidence-only` и запрещён в `C`/`D`.
Каждый `C` path обязан принадлежать Requirement/TestId workload, быть объявлен в
`test-manifest-v2.tsv`, иметь exact candidate-byte `D` binding и отдельный
`execution-dependency-probe-v1`: clean nonzero либо изменившиеся stdout/stderr. Probe доказывает
только execution dependency, но не semantic relevance: её независимо подтверждает critical reviewer
в обязательной оси `performance-scope`, связанной с exact ScopeRoot/C-count/N-count и
`synthetic-preflight=none`. PASS этой оси допустим только после просмотра command/test semantics:
успех или observable output каждого workload должен зависеть от точных байтов его `C` paths; отдельный
open/stat/read-only preflight или синтетический пролог не считается semantic evidence. `D` может включать `N`, если это реальная dataset/test-support dependency.
`ScopeRoot = sha256("HARNESS-PERFORMANCE-SCOPE-V1\n" + canonical C rows + canonical N rows)`, где
`C` упорядочены по raw-byte workload/path, а `N` — по raw-byte path; строки включают class целиком.
Все repo paths — валидный UTF-8, но после validation хранятся и сравниваются как exact bytes с Git;
`|` запрещён fail-closed, чтобы path не мог изменить Markdown dataset table.
Candidate и каждый comparative base материализуются один раз, переиспользуются read-only, а их
digest сверяется до и после каждого измерения:

```bash
bash scripts/pipeline-state.sh performance-run "$SPEC_DIR" <performance-attempt-64hex>
```

Для доказанного non-runtime-only delta допустима только typed N/A форма
`performance-review-na.md`, сохранённая canonical path `reviews/performance-review.md`; runtime,
test, verifier или executable path делает N/A invalid. Этот branch закрывается generic receipt:

```bash
bash scripts/pipeline-state.sh review-finish "$SPEC_DIR" performance <performance-attempt-64hex> "$SPEC_DIR/reviews/performance-review.md"
```

Не вызывай generic `review-finish performance` после успешного `performance-run`: process command
уже создала terminal receipt.

## 3. Requirement evidence и Evidence-Root

Отдельно сверь каждый FR/NFR с exact implementation path, decision, trusted GREEN/adjacent run или
typed inspection evidence. Создай `$SPEC_DIR/checklists/requirement-evidence.md` по canonical
template. UI-impact дополнительно требует два независимых доказательства на одной served version:
visual-qa (визуал) и ux-route-qa (measured journey) в разных attempts; отсутствие headed-browser
capability (`PROJECT.md §8`) — typed `CAPABILITY-BLOCKED`, не PASS.

После трёх canonical evidence artifacts выполни:

```bash
bash scripts/pipeline-state.sh evidence-bind "$SPEC_DIR"
```

Команда обязана проверить exact C receipts, вычислить `Evidence-Root` и staged boundary. После неё
запрещены generic/usage events и любые изменения evidence bytes.

## 4. Immutable H→B envelope

1. Убедись, что staged delta содержит только штатные state/audit и три canonical evidence artifacts.
   Создай ровно один commit `H`, sole single-parent direct child `C`.
2. На clean HEAD=`H` выполни:

   ```bash
   bash scripts/pipeline-state.sh quality-head "$SPEC_DIR"
   ```

3. Повтори required final suite на exact `H` без правок. PASS разрешён только с фактическим evidence:

   ```bash
   bash scripts/pipeline-state.sh verdict "$SPEC_DIR" PASS "<tests/counts + exact checks>"
   bash scripts/pipeline-state.sh stage-done "$SPEC_DIR" stage-4-quality <green|yellow|red> "<verified checks; named uncertainty>"
   ```

4. Повтори `bash scripts/check.sh` и pre-commit checks с финальными state/audit bytes. Создай единственный
   direct child `B`, меняющий только `$SPEC_DIR/state.md` и `$SPEC_DIR/audit.md`, затем:

   ```bash
   bash scripts/pipeline-state.sh bind-head "$SPEC_DIR"
   bash scripts/pipeline-state.sh check "$SPEC_DIR" publish
   ```

До `B`/binding publish обязан быть BLOCKED. После `quality-head` нельзя refresh confidence, писать
generic events или менять H.

## FAIL и retry

Любой missing/partial requirement, blocking review finding, process/test failure или нужная правка
до `H` фиксируется:

```bash
bash scripts/pipeline-state.sh verdict "$SPEC_DIR" FAIL "<точная причина и evidence>"
```

Вернись в Stage 3 через её штатный `stage-start`: invalidation сбросит stale roots/receipts/Units,
после исправления весь affected RED→GREEN/review lifecycle выполняется заново. Batch/retry count сам
по себе не создаёт PASS и не является поводом спрашивать generic «что дальше?»: продолжай до PASS
либо typed owner-authority/budget/hard blocker. Финальный ответ назови `Design-Root`,
`Implementation-Root`, `Evidence-Root`, C/H/B, reviewers, checks и exact publish status.
