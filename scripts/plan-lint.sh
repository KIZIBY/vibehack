#!/usr/bin/env bash
# plan-lint.sh — детерминированный линт plan.md + traceability требований (сенсор stage-2).
#
# Две проверки:
#   1. Структура plan.md: REQUIRED-секции (контракт /pipeline-stage2), стеко-зависимые — warn.
#   2. Traceability: каждый FR-xxx / NFR-xxx из spec.md упомянут в plan.md ИЛИ tasks.md —
#      требование без следа в плане = осиротевшее (аналог upstream-coverage sensor в AI-DLC);
#      план обязан отвечать на каждое требование, иначе stage-4 найдёт MISSING слишком поздно.
#
# Usage: bash scripts/plan-lint.sh <SPEC_DIR>
# Exit:  0 = OK (warn допустимы) · 1 = нет REQUIRED-секции / осиротевшие требования · 2 = файлы не найдены
set -uo pipefail

DIR="${1:?usage: plan-lint.sh <SPEC_DIR>}"
PLAN="$DIR/plan.md"; SPEC="$DIR/spec.md"; TASKS="$DIR/tasks.md"
[ -f "$PLAN" ] || { echo "plan-lint: FATAL: не найден $PLAN" >&2; exit 2; }
[ -f "$SPEC" ] || { echo "plan-lint: FATAL: не найден $SPEC (traceability без спеки не считается)" >&2; exit 2; }

fail=0
req() { if grep -q "^## $1" "$PLAN"; then echo "plan-lint: ok    ## $1"
        else echo "plan-lint: FAIL  нет секции '## $1' (REQUIRED)"; fail=1; fi; }
rec() { if grep -q "^## $1" "$PLAN"; then echo "plan-lint: ok    ## $1"
        else echo "plan-lint: warn  нет секции '## $1' (RECOMMENDED)"; fi; }

req "Technical Approach"
req "Implementation Steps"
req "Known Risks"
rec "Units of Work"
rec "Files to Create/Modify"

# --- traceability: FR/NFR из spec.md → plan.md (или tasks.md, если есть) ---
# Требование должно быть адресовано хоть где-то в «покрытом корпусе» plan (+tasks).
has_tasks=0; tasks_note=""
[ -f "$TASKS" ] && { has_tasks=1; tasks_note="/tasks.md"; }
in_corpus() { # $1 = id
  grep -qE "\b$1\b" "$PLAN" && return 0
  [ "$has_tasks" -eq 1 ] && grep -qE "\b$1\b" "$TASKS" && return 0
  return 1
}
# ID собираются ТОЛЬКО из секций требований и только из ДЕКЛАРАЦИЙ: жирная (`**FR-N`) или
# в начале строки/пункта (`FR-N:`, `- FR-N`). Цитата чужого требования в середине прозы
# («прецедент spec NNN FR-M») — не декларация: иначе ложный сирота.
ids="$( { awk '/^## (Functional|Non-Functional) Requirements/{f=1;next} /^## /{f=0} f' "$SPEC" \
  | grep -ohE '\*\*N?FR-[0-9]+|^[-*0-9. ]*N?FR-[0-9]+' | grep -oE 'N?FR-[0-9]+' || true; } | sort -u)"
if [ -z "$ids" ]; then
  echo "plan-lint: warn  в spec.md нет ни одного FR-xxx/NFR-xxx — traceability проверить нечего (нумеруй требования)"
else
  orphans=""
  for id in $ids; do
    in_corpus "$id" || orphans="$orphans $id"
  done
  if [ -n "$orphans" ]; then
    echo "plan-lint: FAIL  осиротевшие требования (есть в spec.md, нет следа в plan.md$tasks_note):$orphans"
    echo "plan-lint:        каждое требование адресуется в плане явно — или переносится в Out of Scope спеки"
    fail=1
  else
    echo "plan-lint: ok    traceability: все $(echo "$ids" | wc -l | tr -d ' ') требований из spec.md адресованы в плане"
  fi
fi

# --- coherence: КОНСИСТЕНТНОСТЬ plan↔spec, не трассировка ---
# plan-lint выше проверяет «есть ли след требования» (spec→plan); coherence — «согласован ли»:
# plan-overreach = план ДЕКЛАРИРУЕТ FR-N, которого нет в spec.md (план решает вне спеки).
# Строгий сбор (наивный any-mention ложно срабатывает на cross-spec цитатах): (1) отбросить строки
# с контекстом `spec NNN` — цитата чужого требования «догон spec NNN FR-M» НЕ overreach; (2) собрать
# ТОЛЬКО декларации plan-ID (жирная `**FR-N` / начало пункта / Traceability `- FR-N`), тем же классом,
# что spec-сбор; (3) под-ID `FR-12.1` нормализуется до `FR-12` самим `grep -oE 'N?FR-[0-9]+'`.
# Нет spec-ID → skip.
if [ -n "$ids" ]; then
  # $ids от sort -u — newline-separated; схлопываем в пробел-разделённый набор для case-матча
  # (без кавычек echo делает word-splitting \n→пробел). Иначе " $ids " несёт \n и *" ID "* не матчит.
  ids_set=" $(echo $ids) "
  plan_ids="$( grep -vE 'spec[[:space:]]*[0-9]' "$PLAN" \
    | grep -ohE '\*\*N?FR-[0-9]+|^[-*0-9. ]*N?FR-[0-9]+' | grep -oE 'N?FR-[0-9]+' | sort -u )"
  overreach=""
  for pid in $plan_ids; do
    case "$ids_set" in *" $pid "*) ;; *) overreach="$overreach $pid";; esac
  done
  if [ -n "$overreach" ]; then
    echo "plan-lint: FAIL  coherence: plan декларирует требование вне spec.md (overreach):$overreach"
    echo "plan-lint:        план не должен решать то, чего нет в спеке — определи в spec.md или убери из плана"
    fail=1
  else
    echo "plan-lint: ok    coherence: plan-декларации согласованы со spec.md (0 overreach)"
  fi
fi

# terminology-контракт (advisory warn): структурный drift модели.
# Точный маркер `## Tasks` (заголовок spec-kit) — пайплайн использует `## Units of Work`.
# НЕ ловит «tasks.md» в прозе-обсуждении (whitelist by construction — только заголовок секции).
if grep -qE '^## Tasks' "$PLAN"; then
  echo "plan-lint: warn  terminology: plan несёт секцию '## Tasks' (spec-kit); пайплайн — '## Units of Work' (drift?)"
fi

if [ "$fail" -eq 0 ]; then echo "plan-lint: OK ($PLAN)"; else echo "plan-lint: FAILED ($PLAN)"; fi
exit "$fail"
