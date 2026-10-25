---
description: "Runtime-neutral State V4 pipeline: Creative → Audit → owner approval → Dev/TDD → Quality/Evidence. Usage: /pipeline \"описание\""
---

# /pipeline — тонкий Claude-адаптер State V4

Feature: **$ARGUMENTS**

Этот prompt не является отдельной доктриной. Авторитетны корневой `AGENTS.md`,
`docs/constitution.md`, артефакты выбранного `SPEC_DIR` и exit code
`scripts/pipeline-state.sh`. Прочитай `.claude/skills/pipeline.md`, если файл доступен: он даёт
обзор и rubric, но его отсутствие не блокирует исполнение. Byte-exact lifecycle ниже и четыре
stage-adapter остаются достаточным fallback. Не имитируй успешную CLI-команду текстом.

## Подготовка и resume

1. Извлеки `SPEC_DIR=`, `SCOPE=` и необязательный `TICKET=` из аргументов. Поддерживаемый этим
   исполняемым маршрутом scope: `feature`, `bugfix` или `enterprise`. Для `bugfix` сначала примени
   diagnose/root-cause/scope-the-class контракт из `docs/bug-handling-process.md`, затем веди тот же
   State V4 lifecycle с тремя roots и exact `R→C→H→B`; тип scope не является bypass гейтов.
2. Для нового прогона выбери свободный `specs/NNN-slug`, создай `reviews/`, затем выполни:

   ```bash
   bash scripts/pipeline-state.sh init "$SPEC_DIR" "<описание>" "${SCOPE:-feature}"
   ```

   Если тикет известен, передай его только штатным пятым аргументом `init` либо отдельным
   `link-ticket`; не встраивай transport-specific команды в adapter.
3. Для существующего `state.md` ничего не пересоздавай:

   ```bash
   bash scripts/pipeline-state.sh status "$SPEC_DIR"
   ```

   Продолжи с напечатанного `next:`. `BLOCKED` — состояние, а не приглашение обойти гейт.

## Единственный порядок выполнения

Открывай и исполняй stage-файлы последовательно; каждый содержит точные V4-команды и свой
артефактный DoD:

| Stage | Adapter | Authority output |
|---|---|---|
| 1 Creative | `.claude/commands/pipeline-stage1.md` | требования, ограничения, кандидаты |
| 2 Audit/SDD | `.claude/commands/pipeline-stage2.md` | independent architecture receipt + `Design-Root` + owner approval exact root |
| 3 Dev/TDD | `.claude/commands/pipeline-stage3.md` | process-grounded RED/GREEN/adjacent + `Implementation-Root` |
| 4 Quality | `.claude/commands/pipeline-stage4.md` | independent critical/performance evidence + `Evidence-Root`, затем exact `R→C→H→B` |

После каждого stage снова вызови `status` и верь только state/audit. Stage 2 содержит обязательный
owner gate `Approve / Revise / Abort`; терминальное указание пользователя не подменяет approval
конкретного `Design-Root`. Publish разрешён только после успешного финала Stage 4:

```bash
bash scripts/pipeline-state.sh check "$SPEC_DIR" publish
```

Публикацию выполняй только по `docs/guides/GIT_PUBLISH_RUNBOOK.md`: `scripts/agent-publish-main.sh`
в strict-режиме `PIPELINE_SPEC_DIR="$SPEC_DIR"` публикует exact bound `B` (R→C→H→B), без rebase и
перезаписи истории.

## Исполнение ролей

Используй 2–5 независимых reviewer/worker контекстов там, где границы файлов и authority
действительно независимы. Если runtime не умеет delegation, выполни роли последовательно в свежих
контекстах и запиши `degraded-concurrency`; гейты и receipts не ослабляются. Build/test/deploy
запускаются строго по одному. Для telemetry используй только `pipeline-state.sh event` и только до
`Evidence-Root`/`Quality-HEAD`; зарезервированные authority events создают исключительно штатные
команды state-machine.

При сбое не начинай новый прогон: `status` → устранение причины → resume того же `SPEC_DIR`.
Финальный отчёт обязан назвать scope/ticket, три roots, C/H/B, реальные проверки, ограничения и
точный следующий action из state-machine.
