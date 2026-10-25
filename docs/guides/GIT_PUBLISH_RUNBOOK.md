# Git Publish Runbook For Agents

**Версия:** 1.0

Документ обязателен для агентов, которые меняют репозиторий и публикуют результат (PR или прямо в
`main`), а также комментируют или закрывают тикеты в настроенном backend задач.

Короткая версия:

```bash
bash scripts/agent-preflight.sh origin main   # read-only: git-контур, publish_state, backend задач
bash scripts/check.sh                         # единая точка проверок — перед коммитом и публикацией
bash scripts/agent-publish-main.sh            # публикация: режим выбирается по ветке (см. ниже)
```

## Три режима публикации

Единственный канал публикации — `bash scripts/agent-publish-main.sh [remote] [branch]` (дефолт
`origin main`). Режим выбирается так:

| Условие | Режим | Что происходит |
|---|---|---|
| текущая ветка ≠ целевой (feature-ветка) — **по умолчанию** | **PR** | clean-tree → `fetch` → rebase на свежую вершину `origin/main` → `bash scripts/check.sh` → `git push --force-with-lease -u` ветки → подсказка открыть PR |
| текущая ветка = целевой (`main`) или явно `AGENT_PUBLISH_MODE=main` | **прямая публикация** (solo-проекты) | lease-гейт → dirty-guard → retry ≤3 (fresh fetch, rebase при дивергенции) → push → verify-after-push |
| задан `PIPELINE_SPEC_DIR` или `AGENT_PUBLISH_EXPECT_HEAD` | **strict exact-OID** | один immutable attempt literal-OID без rebase/autocommit/retry (раздел «Публикация итогов пайплайн-прогона») |

### PR-режим (по умолчанию)

```text
clean tracked tree → git fetch origin main → rebase на FETCH_HEAD (конфликт → rebase --abort + честный отказ)
→ bash scripts/check.sh на перенесённых коммитах (красный → отказ без push)
→ git push --force-with-lease -u origin <ветка> → «открой PR: gh pr create --fill --base main --head <ветка>»
```

- Целевая ветка не трогается; **merge жмёт человек**. Подсказка `gh pr create --fill` печатается,
  когда `origin` — GitHub; для другого хостинга — открыть PR из ветки в веб-интерфейсе.
- `scripts/check.sh` обязателен: нет файла → отказ. Пропуск проверок — только осознанный
  `AGENT_PUBLISH_SKIP_TESTS=1` (скрипт печатает WARN, что PR уходит непроверенным).
- Ветка без коммитов поверх `main` → «PR не нужен», push не выполняется.
- `AGENT_PUBLISH_MODE=pr` на целевой ветке → отказ. Detached HEAD без явного
  `AGENT_PUBLISH_MODE=main` → отказ (нет ветки, которую можно предложить в PR).
- DORA-событие: `publish:pr` (best-effort, не деплой).

### Прямая публикация в `main`

Для solo-проектов без PR-ревью: запуск на `main` (или с явным `AGENT_PUBLISH_MODE=main`).

- Предварительный lease-гейт выполняется ДО EXIT-trap: отказ из-за чужого действующего lease
  (`coordination/README.md`) не пишет ложное `publish:failed`.
- Dirty-guard: tracked-изменения → отказ (commit или stash); untracked-файлы не мешают.
- До трёх попыток; каждая начинает со свежего `fetch`. Дивергенция → `rebase --autostash` на
  свежую вершину (конфликт → автоматический `rebase --abort`, репо не остаётся в mid-rebase,
  честный отказ). Повторный lease-чек на свежем диффе. Push `HEAD:<branch>`.
- **Verify-after-push:** remote читается через `git ls-remote` и сравнивается с опубликованным OID;
  затем обновляется локальный `refs/remotes/origin/main`. Без совпадения публикация не считается
  состоявшейся. Гонка на push → `retry N/3 (diverged)` + `publish:retry` → бэкофф; исчерпание
  попыток → честный отказ.
- Remote уже равен HEAD → `publish:noop`, публикацией не считается.
- `scripts/check.sh` в этом режиме сам не вызывается — его запускают перед коммитом.

### DORA-события публикации

`agent-publish-main.sh` пишет в `docs/ops-journal.md` (через `scripts/ops-log.sh`, best-effort —
сбой журнала никогда не меняет exit-код публикации): `publish:done` · `publish:failed` ·
`publish:noop` · `publish:retry` · `publish:pr`. Публикация — **не деплой**: события `deploy:*`
пишет только деплой-скрипт проекта (команда из `PROJECT.md §3`). Правило подсчёта в
`scripts/dora-metrics.sh`: деплои = `deploy:done|failed`; если в журнале нет ни одного `deploy:*`
события (у проекта нет деплой-шага), поставка считается по `publish:done|failed`; `publish:pr`
не считается никогда. Так DORA не удваивает частоту, когда проект и деплоит, и публикует.

Exit-коды publisher'а: `0` — опубликовано или noop · `1` — отказ/сбой · `3` —
`REVALIDATION_REQUIRED` (exact-режим).

## Почему push/resolve ломается

Кодовые агенты и IDE-оркестраторы часто работают не в обычной ветке, а в linked worktree с
detached `HEAD` (автоматизации Codex App, фоновые worktree других оркестраторов). Worktree
изолирует изменения агента от незавершённой локальной работы, но файл `.git` в рабочей папке
содержит ссылку вида:

```text
gitdir: <корень-репозитория>/.git/worktrees/<имя-worktree>
```

Часть git-команд пишет служебные файлы не в текущий checkout, а в этот внешний gitdir. В sandbox это
может падать:

```text
cannot open .../.git/worktrees/<имя-worktree>/FETCH_HEAD: Operation not permitted
```

Отдельная проблема — сеть. Если хостинг/DNS недоступны, команды падают так:

```text
Could not resolve host: github.com
error connecting to api.github.com
```

Это не означает, что правка плохая. Это означает, что агент не имеет надёжного publish channel в
текущем запуске.

## Общее правило

Связанный с изменением кода тикет можно закрывать только после трёх фактов:

1. Коммит опубликован в `origin/main` (в PR-режиме — PR смёржен человеком).
2. Remote SHA проверен после push (verified remote SHA).
3. В активном backend задач оставлен комментарий: что сделано, commit SHA, проверки, остаточные
   ограничения.

Если любой пункт не выполнен, тикет не закрывать. Blocker записывается в память агента
(`agents/memory/<role>.md`).

## Безопасная публикация: preflight

Перед началом работы или перед закрытием тикета проверить состояние Git-контура и backend задач:

```bash
bash scripts/agent-preflight.sh origin main
```

Preflight не меняет репозиторий. Он выдаёт metadata-only статусы canonical worktree/gitdir (без
локальных путей), `HEAD`, локального `origin/main`, exact remote SHA через bounded `ls-remote`,
`publish_state` (`remote_matches_head` / `head_can_fast_forward_remote` / `blocked_…`), backend
задач и гигиену корня. Exit строго `0|1`; классы различаются WARN-маркером.

Backend задач выбирается единым правилом харнесса: переменная окружения `ISSUE_BACKEND` → иначе
первая строка `PROJECT.md`, начинающаяся с `ISSUE_BACKEND=` (обязана точно совпасть с
`^ISSUE_BACKEND=(github|none)\s*$`) → иначе `none`. Неизвестное значение → `WARN
issue_contract=invalid-backend` (fail closed).

- `none` — внешнего трекера нет: `issue_backend=none`, issue-пробы пропускаются; работа живёт в
  `specs/`, очередь задач — `docs/backlog.md`.
- `github` — репозиторий **всегда** выводится из canonical `origin` (`github.com/<owner>/<repo>`);
  `GH_REPO`, если задан, может только точно повторять его (иначе
  `issue_contract=github-repo-mismatch`). Preflight проверяет `gh auth`, `gh issue list` на чтение,
  repo permissions через GitHub API и вероятную возможность issue write/triage. Если он показывает
  `gh_auth=failed`, `gh_issues_read=failed` или `gh_issues_write_likely=not_confirmed`, агент не
  должен считать, что сможет смотреть, комментировать, закрывать или переоткрывать тикеты.

## Работа с тикетами

Любой агент, который работает с тикетами, сначала выполняет preflight, затем открывает
`agents/README.md` → «Режим задач (ISSUE MODE)» и выполняет описанный там lifecycle
dedup → mutation → verify-read. Команды из канонов ролей, памяти и этого runbook не могут
переопределить ISSUE MODE.

- `ISSUE_BACKEND=none` — тикетов нет: результат фиксируется в спеке/`docs/backlog.md`, «закрытие»
  — это отметка в очереди после verified remote SHA.
- `ISSUE_BACKEND=github` — GitHub Issues через `gh` (или GitHub-коннектор рантайма). Переход
  коннектор → `gh issue` допустим только после успешного preflight; если ни один transport не
  подтверждён, операция остаётся blocked.

Создание, комментарий, close или reopen считаются выполненными только после verify-read через тот же
backend. Успешного ответа mutation API/CLI недостаточно; при недоступном verify-read состояние
считается неподтверждённым, слепой retry и отчёт об успехе запрещены. Перед созданием нового тикета
обязателен dedup. Связка «тикет ↔ спека» для `/intake` — `scripts/intake.sh` (dedup, verify-read,
`link-ticket-cas`; при `none` — исход `skipped:issue-backend-none`).

Repo changes и lifecycle тикета связываются так: сначала verified remote SHA в `origin/main`, затем
комментарий в тикете с SHA/проверками/остаточными ограничениями, затем close/update. Локальный
коммит без verified remote SHA не является resolved.

## Linked worktree: локализация gitdir

В linked worktree не начинать с `git fetch`, если sandbox уже показывал
`FETCH_HEAD: Operation not permitted`.

Если `git add`, `git commit`, `git fetch` или `git update-ref` падают на `index.lock`, `HEAD.lock`,
`FETCH_HEAD` или `COMMIT_EDITMSG` во внешнем `.git/worktrees/...`, сначала локализовать gitdir
текущего worktree:

```bash
bash scripts/agent-localize-gitdir.sh
```

Скрипт строит mutable gitdir state в same-filesystem staging, очищает весь ambient Git namespace,
сверяет stable source HEAD/index и только затем атомарно публикует `.codex-worktree-git/` внутри
текущего checkout. После rename перепроверяются source и final target; managed-leaf symlink не
получает write-through. Общий object store остаётся прежним; зарегистрированный `.git` pointer
linked worktree **никогда не переписывается**.
Equal/local-ahead копия переиспользуется. Stale или исторически partial/invalid/symlink копия
атомарно сохраняется в self-ignored `.codex-gitdir-quarantine/`. Затем контекст освежается: при
read-only registered gitdir строится свежий local fallback, а при writable/обычном `.git`
используется canonical registered context; diverged HEAD требует ручного reconciliation. Обе
служебные папки self-ignored: HEAD/index/reflog и machine-local пути не попадут в обычный
`git status`/`git add -A`.

После локализации обычный `git` по-прежнему идёт через исходный `.git` pointer во внешний gitdir.
Поэтому для ручных Git-команд wrapper обязателен, независимо от writable/read-only режима pointer:

```bash
bash scripts/agent-git.sh status
bash scripts/agent-git.sh add <files>
bash scripts/agent-git.sh commit -m "..."
```

Strict Git-команды `pipeline-state.sh` (Stage 4/quality-head/bind/publish-check) и
`agent-publish-main.sh` (прямой и exact-режимы) сами используют `.codex-worktree-git/`, если она
уже создана; вручную экспортировать `GIT_DIR`/`GIT_WORK_TREE` для них не нужно.

## Изоляция окружения publisher'а (прямой и exact-режимы)

- Сетевые git-вызовы идут в bounded owned POSIX session/process-group: зависшая сеть и
  same-session descendants завершаются TERM→KILL, escaped pipe holder не удерживает capture.
  Таймаут — `AGENT_PUBLISH_NET_TIMEOUT` (дефолт 30 с). Capture проверяет абсолютный deadline,
  поэтому постоянно readable stdout/stderr не откладывает timeout; лимит 32 MiB — отдельный
  fail-closed исход.
- До первого `rev-parse` publisher нейтрализует caller-selected `GIT_DIR`/`GIT_WORK_TREE`/index/
  common, dynamic `GIT_CONFIG_COUNT` + `KEY_*`/`VALUE_*`, config-file overrides, object/alternate/
  shallow, replace/graft и namespace selectors — caller и localized re-exec не могут перенаправить
  repo-local `origin` на другой remote. System/global config network-процесса закреплены
  fail-closed: `url.*`, include, proxy, hooks и push-policy станции не становятся publish authority.
- Единственное, что берётся из global config, — `credential.helper|username|useHttpPath|interactive`
  (без includes), снятые под `env -i` в private identity/digest-bound `0600` leaf под pinned
  `0700` root. Hex-представление snapshot живёт только в неэкспортируемой shell-переменной и не
  попадает в environment детей. Network child получает clean env: `PATH/HOME/XDG_CONFIG_HOME/LANG`,
  canonical Git guards и `SSH_AUTH_SOCK`; ambient `GIT_SSH*`, AskPass, proxy, SSL/CA удалены.
  Корпоративный proxy/custom CA требует явной policy-bound capability — не поставлено.
- Каждый descriptor-bound/network child закрывает все унаследованные FD `>2`, кроме явно
  удерживаемых. Только tool, который намеренно делает новый `setsid`/daemonize, выходит за
  trusted transport contract; его внешние side effects не считаются подтверждёнными publisher'ом.

## Публикация итогов пайплайн-прогона (strict exact-OID)

Если перед запуском выставить `PIPELINE_SPEC_DIR=<SPEC_DIR>`:

```bash
PIPELINE_SPEC_DIR=specs/NNN-slug bash scripts/agent-publish-main.sh
```

скрипт сперва механически проверит V4-предикат `pipeline-state.sh check <SPEC_DIR> publish` и
откажется публиковать, пока по прогону:

- не завершены `[x]` все четыре стадии Creative → Audit → Dev → Quality;
- `State-Version` не равен 4 или delivery contract не является зарегистрированным current profile;
  V1/V2/V3 остаются inspectable, но mutation/bind/publish требуют explicit forward migration;
- не записаны constitution-gate `MUST-FLAG: 0` / `NEEDS-INFO: 0`, verified `Design-Root` и
  `user-approval: approved` exact этого root;
- не закрыты все объявленные Units (для enterprise непустые Units обязательны);
- не bound `Implementation-Root` с unchanged Design-Root, closed R→C delta и runner-grounded
  RED→GREEN+adjacent evidence; self-authored delivery literals не являются receipt;
- отсутствуют fresh independent architecture, critical-code и performance receipts exact
  applicable subject, implementation actor совпадает с reviewer либо P0/P1/P2 не равны нулю;
- не bound `Evidence-Root`, вычисленный по exact C + closed prospective-H review/evidence path-set,
  либо повторная проверка committed H не воспроизводит тот же root;
- не записан `quality-verdict: PASS` с evidence;
- confidence stage-4 остался non-green без ack владельца;
- `Quality-HEAD` не указывает на committed evidence candidate H;
- текущий HEAD не является единственным direct-child B, меняющим только state/audit допустимым образом;
- в effective per-worktree gitdir нет CAS-binding `(SPEC_DIR,H)→B`;
- после чтения pinned remote R checkpoint C не является его sole single-parent direct child либо
  raw bytes любого outbound commit C/H/B содержат canonical secret/owner-machine-path violation.

Отказ initial binding/remote/drift гейта — это НЕ провал публикации: проверка происходит до
установки EXIT-trap, поэтому ложное `publish:failed` в DORA-журнал не пишется.

UI-impact имеет дополнительный doctrine-гейт: до вызова publisher должны существовать разные
visual-qa (визуал) и ux-route-qa (измеренный маршрут) результаты на одной published/served
identity. `CAPABILITY-BLOCKED` не разрешает ordinary release. Профиль `architecture-evidence-v1`
ещё не включает browser artifacts криптографически; deploy-bound CAS/read-back и механическое
замыкание этого residual не поставлены — называть его закрытым publisher'ом нельзя.

### Порядок V4 Quality → publish

1. На Stage 2 architecture verifier связывает typed dossier/living SDD/traceability и independent
   architecture receipt в `Design-Root`; owner approval относится exact к нему. Design discovery
   после bind re-open'ит Stage 2 и инвалидирует downstream roots/receipts.
2. После fresh remote read/reconciliation фиксируется deployment base R. Stage 3 получает
   execution-grounded RED→GREEN+adjacent proof, closed implementation map и `Implementation-Root`.
   Итог Stage 3 собирается одним clean checkpoint C непосредственно поверх R (при накопленной
   локальной истории — squash final tree в новый C), затем полный suite проходит на exact bytes C.
   История релиза обязана начинаться ровно `R→C`; pre-C add→revert/merge commits нельзя оставлять
   в outbound range.
3. Stage 4 отдельными от implementation actor attempts формирует critical-code и performance
   review, требует P0/P1/P2=0, затем bind'ит `Evidence-Root`. В профиле
   `architecture-evidence-v1` prospective/committed H может изменить только state/audit и exact
   `reviews/critical-code-review.md`, `reviews/performance-review.md`,
   `checklists/requirement-evidence.md`; любой matrix/learnings/TSV/HTML/extra path после C
   блокируется. H обязан быть sole single-parent direct child C, а C→H сохраняет exact
   audit-prefix. Fresh C содержит ровно один current `stage-4-quality:start`; официальный re-open
   C с завершённым S4 — ровно canonical `stage-4-quality:invalidated` (`reset from
   stage-4-quality`) → новый start. Любые иные преждевременные `quality-head`, verdict,
   confidence-4/ack, S4 done/invalidated блокируют H. Между `stage-4-quality:start` и
   `evidence-bind` допустимы только typed review/performance lifecycle rows в exact порядке
   профиля; generic `agent:*`, generic `event` и любые другие trace rows блокируют H.
4. `bash scripts/pipeline-state.sh quality-head <SPEC_DIR>` фиксирует exact H; после него код,
   тесты, common docs и generated files не меняются.
5. После final checks записываются PASS/confidence/done, повторяется full suite и создаётся
   единственный direct-child B только со `<SPEC_DIR>/state.md` и `audit.md`. H audit обязан быть
   exact byte-prefix B audit, а suffix — ровно четыре core-строки quality-head → fresh PASS →
   confidence-4 → S4 done. Допустима только пятая canonical confidence-ack row, когда B state
   подтверждает те же actor/timestamp; PASS evidence/time и confidence level/reason/time также
   обязаны exact совпасть со state. Post-H invalidation, generic либо любая другая extra row
   блокирует authority, даже если state вручную возвращён к ожидаемым bytes.
6. `bash scripts/pipeline-state.sh bind-head <SPEC_DIR>` создаёт per-worktree binding; затем
   `check ... publish` обязан пройти. После pinned remote read publisher дважды вызывает
   `publish-base <SPEC_DIR> R`, доказывает exact `R→C→H→B` и сканирует raw commit objects
   (tree/parents/author/committer/extra headers/message), а не только endpoint tree или `%B`.
   Binding никогда не dereference'ит и не перетирает существующий symbolic ref — в том числе
   dangling symref с отсутствующей target-веткой.

### Exact-режим: как устроен push

В exact-режиме publisher никогда не rebase'ит и не создаёт коммитов. Он отключает Git replace refs
(`GIT_NO_REPLACE_OBJECTS=1`), запрещает hidden index flags (`assume-unchanged`/`skip-worktree`) и
отделяет staged proof (`--no-textconv --ignore-submodules=none`) от live proof. Live tracked bytes,
symlink/type, executable mode, exact component spelling и recursive gitlinks descriptor-сверяются
напрямую с expected tree/blob, полностью мимо real/private index, stat cache, attributes и clean
filters. Untracked paths внутри SPEC_DIR перечисляются тем же raw tree walk без excludes, поэтому
real-index `intent-to-add` не может скрыть leaf. Цена этой fail-closed политики явная:
LFS/filter/EOL/`working-tree-encoding` checkout, где live bytes по дизайну отличаются от blob,
считается dirty; authority не запускает converter и требует canonical raw checkout.

После lease-чека publisher ещё раз повторяет authority proof непосредственно перед noop/push.
Каждая exact-команда получает новый Gitdir с пустым template: для SHA-1 local config
descriptor-проверенно удаляется, для SHA-256 остаётся ровно один identity/digest-bound `0600` leaf
только с `repositoryformatversion/bare/objectformat`; `config.worktree` и `commondir` запрещены.
Portable Git CLI не умеет запретить повторное открытие `$GIT_DIR/config` по pathname: намеренная
post-proof mutation тем же UID (как и malicious `git`) остаётся явной trusted-tool/host границей;
OS-isolated executor с недоступным на запись Gitdir не поставлен. Один raw URL обязан быть
единственным, distinct/ambiguous `pushurl` блокируется до сети. Push — одна ref с `--no-verify
--no-follow-tags --recurse-submodules=no` и exact `--force-with-lease=<branch>:<observed-base>`,
затем тот же literal endpoint проверяется повторно. `<B>:refs/heads/main`, а не `HEAD:main`,
остаётся единственной разрешённой remote mutation.

Механизм opt-in: без `PIPELINE_SPEC_DIR`/`AGENT_PUBLISH_EXPECT_HEAD` работают PR- или прямой режим.
Забытая переменная — честно задокументированный residual risk, а не основание называть весь
канал глобально fail-closed.

### Exact-SHA без пайплайна

`AGENT_PUBLISH_EXPECT_HEAD=<full-oid>` включает тот же immutable single-attempt path без
pipeline-state (например, для ревьюера, который проверил конкретный commit). Initial/current HEAD
обязан byte-exact совпасть; если одновременно задан `PIPELINE_SPEC_DIR`, оба OID должны совпасть.
Сокращённый (не 40/64-hex) OID отвергается.

## Если remote ушёл вперёд

Не делать force-push в целевую ветку.

- PR-режим сам переносит ветку на свежую вершину (конфликт → abort и ручное разрешение) и
  перепроверяет `scripts/check.sh` на перенесённых коммитах.
- Прямой режим выполняет собственный bounded rebase/retry; конфликт abort'ит и оставляет для
  ручного разрешения.
- Exact/pipeline режим не меняет проверенный commit и возвращает `REVALIDATION_REQUIRED`: после
  rebase/cherry-pick нужен новый test/Quality boundary и новый bind.

Безопасные пути для exact-режима:

1. Начать новый worktree от свежего `origin/main` и заново применить только свои изменения.
2. Выполнить `git fetch origin main` вне sandbox или в окружении, где есть запись в linked gitdir.
3. Пересобрать коммит поверх свежего `main`; для exact-SHA повторить tests/retest, для pipeline —
   Stage 2/3 roots as applicable → fresh independent Stage-4 evidence H → B → bind; только затем
   снова запустить publisher.

## Если remote или backend задач недоступен

Оставить локальный коммит или staged changes, затем записать в память агента:

- SHA локального коммита, если он создан;
- точную ошибку (`Could not resolve host`, `api.github.com`, `FETCH_HEAD`);
- какие тикеты нельзя закрывать до публикации и verify-read;
- следующий шаг для повторного запуска.

## Для агентов без изменений кода

Агенты без code changes тоже не должны считать действие выполненным, если transport активного
ISSUE MODE вернул ошибку. Комментарий, reopen или close считается сделанным только после успешной
mutation и verify-read того же backend; переключение backend запрещено.
