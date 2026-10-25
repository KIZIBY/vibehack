# tests/agent-evals — execution-grounded eval-корпус

Курируемые «known-good» задачи для прогонщика `scripts/agent-eval.sh`. Каждая задача измеряется
контрактом SWE-bench: **FAIL→PASS ∧ PASS→PASS** (по exit-коду скрытого `verify.sh`, не по прозе).
Метрика набора — **`% Resolved`**.

## Формат задачи `NNN-slug/`

| Файл | Обяз. | Роль |
|---|---|---|
| `verify.sh` | ✅ | СКРЫТЫЙ судья. Запускается в CWD=рабочая-копия; `exit 0` = решено. Baseline ожидается FAIL (≠0). |
| `instruction.md` | ✅ | «Хотелка» — что сделать. Может нести блок `<!-- eval:apply --> … <!-- /eval:apply -->` с bash-правкой (детерминированный actor). |
| `snapshot.sh` \| `snapshot/` | — | Исходное состояние: скрипт готовит CWD **или** каталог копируется как есть. |
| `regress.sh` | — | Страж PASS→PASS: проверки, что были зелёными, обязаны остаться (`exit 0` после apply). |

## Контракт скоринга

`resolved` ⟺ **baseline verify FAIL** (доказывает, что было что чинить) **И** **final verify PASS**
(∧ `regress.sh` PASS, если есть). `baseline-already-green` не засчитывается (тривиальная задача).
`pass@k` — задача решена, если ≥1 из `k` прогонов resolved. Инвариант-гейт (`pass^k`) —
`bash scripts/check.sh` один раз на прогон (если его нет — `bash tests/harness/run-tests.sh --tier fast`;
переопределяется `AGENT_EVAL_GATE_CMD`).

## Запуск

```bash
bash scripts/agent-eval.sh "$PWD/tests/agent-evals"                  # весь корпус, k=3, + инвариант-гейт
bash scripts/agent-eval.sh "$PWD/tests/agent-evals" --k 1 --no-gate  # быстрый срез без гейта
bash scripts/agent-eval.sh --out report.json
bash scripts/agent-eval.sh --judge-only    # судить УЖЕ применённое состояние (ручной /pipeline-прогон)
bash scripts/agent-eval.sh --actor '<cmd>' # подать instruction реальному агенту
```

`% Resolved` пишется в `last-run.json` (generated, gitignored) и показывается строкой в выводе
`scripts/dora-metrics.sh` (и на дашборде `scripts/pipeline-dashboard.sh`).

## ⚠️ Траст-граница

`verify.sh`/`snapshot.sh`/`regress.sh`/apply — **произвольный bash с правами оператора, БЕЗ sandbox**.
Ревьюь набор как скрипты; НИКОГДА не гоняй корпус из недоверенного источника. Изоляция прогонщика —
репо-чистота (не мутирует `$ROOT` вне этого каталога), не machine-sandbox.

## Состав корпуса

- `001-fix-add` · `002-noop-apply` · `003-regress-catch` — универсальный **seed** без привязки к
  скриптам харнесса (002/003 — осознанно НЕ-resolved: демонстрируют семантику скоринга noop и
  regress-catch).
- `006-intake-fake-ticket` · `007-publish-exact-head` — задачи на реальные скрипты харнесса
  (`scripts/intake.sh` с backend `github` и fake-`gh`; `scripts/agent-publish-main.sh` в exact-режиме);
  путь к харнессу сохраняется в `.harness-root`. Ожидаемый эталон полного корпуса:
  **3/5 resolved** (все, кроме 002/003).

## Чек-лист автора задачи

1. `verify.sh` обязан **падать на baseline** (иначе `baseline-already-green` — задача не в счёт)
   и проверять НАБЛЮДАЕМЫЙ исход (файлы/exit-коды/git-refs), не прозу.
2. Всё герметично в CWD: фикстурные origin'ы — bare `file://` внутри рабочей копии,
   провайдеры — двойники из `tests/harness/fixtures`, никакой сети.
3. Путь к харнессу бери `${HARNESS_EVAL_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}` в
   `snapshot.sh` и сохраняй в `.harness-root` для verify/apply (задача остаётся запускаемой из копии).
4. Прогонщику передавай **абсолютный** TASKS_DIR (`"$PWD/tests/agent-evals"`) — рабочие копии
   создаются вне репо, относительный путь не переживёт `cd`.
5. Секрет-паттерны в текстах задач — только конкатенацией (I-7, иначе поймает pre-commit).
6. `regress.sh` добавляй, когда у исхода есть «не сломай ранее работавшее» (I-2/noop-повторы).

## Свои задачи проекта

Seed-задачи 001–003 универсальны (без литералов проекта). Заводи свои «known-good» задачи по
тому же формату рядом; существующие задачи не перезаписываются (данные священны).
