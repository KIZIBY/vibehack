#!/usr/bin/env bash
# tests/harness/cases/memory-check.sh — agent-worktree-memory-check.sh (спутник I-2: память агентов
# не теряется в одноразовых worktree). Память живёт в agents/memory/<role>.md, архив —
# agents/memory/archive/<role>/<YYYY-MM>.md. Контракт: exit 0 чисто · 1 = грязная память ИЛИ
# непогашенный свой lease ИЛИ недоказуемая чистота · 2 = не git-репо.
# Скан — только linked worktrees (main-checkout пропускается by design).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "memory-check (worktree-память · непогашенный lease)"

SUT="$ROOT/scripts/agent-worktree-memory-check.sh"

t "не git-репозиторий → exit 2" 2 bash "$SUT" "$TMP"
t_out "диагностика FATAL про не-репо" 'FATAL'

R="$TMP/repo"
mk_repo "$R"
mk_commit "$R" "agents/README.md" "canon"
mk_commit "$R" "agents/memory/developer.md" "# память developer"
t "одиночный checkout без worktrees → OK (exit 0)" 0 bash "$SUT" "$R"
t_out "маркер OK" 'OK'

# ── linked worktree с непотерянной (закоммиченной) памятью → чисто ──
git -C "$R" worktree add -q -b wt-clean "$TMP/wt-clean" >/dev/null 2>&1
t "чистый linked worktree → OK (exit 0)" 0 bash "$SUT" "$R"

# ── untracked память в worktree → DIRTY MEMORY с именем файла ──
git -C "$R" worktree add -q -b wt-dirty "$TMP/wt-dirty" >/dev/null 2>&1
mkdir -p "$TMP/wt-dirty/agents/memory"
printf '# незакоммиченная память\n' >"$TMP/wt-dirty/agents/memory/tech-writer.md"
t "untracked agents/memory/<role>.md в worktree → exit 1" 1 bash "$SUT" "$R"
t_out "маркер DIRTY MEMORY" 'DIRTY MEMORY'
t_out "нарушивший файл назван по имени" 'agents/memory/tech-writer\.md'
t_out "подсказка указывает канонический путь памяти" 'agents/memory/<role>\.md'
rm -f "$TMP/wt-dirty/agents/memory/tech-writer.md"

# ── правка закоммиченной памяти (tracked) → тоже DIRTY ──
printf 'новая запись\n' >>"$TMP/wt-dirty/agents/memory/developer.md"
t "изменённая tracked agents/memory/developer.md → exit 1" 1 bash "$SUT" "$R"
t_out "tracked-правка названа по имени" 'agents/memory/developer\.md'
git -C "$TMP/wt-dirty" checkout -q -- agents/memory/developer.md

# ── архив памяти тоже память ──
mkdir -p "$TMP/wt-dirty/agents/memory/archive/developer"
printf '# архив\n' >"$TMP/wt-dirty/agents/memory/archive/developer/2026-01.md"
t "untracked архив памяти → exit 1" 1 bash "$SUT" "$R"
t_out "архивный файл назван по имени" 'agents/memory/archive/developer/2026-01\.md'
rm -rf "$TMP/wt-dirty/agents/memory/archive"

# ── не-память под agents/ (канон роли) не считается памятью ──
mkdir -p "$TMP/wt-dirty/agents/roles"
printf '# черновик канона\n' >"$TMP/wt-dirty/agents/roles/developer.md"
t "untracked agents/roles/*.md — не память → OK (exit 0)" 0 bash "$SUT" "$R"
rm -rf "$TMP/wt-dirty/agents/roles"

# ── непогашенный СВОЙ lease ветки worktree ──
# lease-каталог читается ИЗ worktree (coordination-lease.sh list с cwd=worktree)
mkdir -p "$TMP/wt-clean/coordination/leases"
printf 'session: wt-clean\nscope: file\npath: docs/x.md\ncreated: %s\nttl_hours: 9999\n' \
  "$(date -u +%FT%TZ)" >"$TMP/wt-clean/coordination/leases/own.lease"
t "живой lease ветки worktree → exit 1" 1 bash "$SUT" "$R"
t_out "маркер НЕПОГАШЕННЫЙ LEASE" 'НЕПОГАШЕННЫЙ LEASE'
rm -f "$TMP/wt-clean/coordination/leases/own.lease"

# ── просроченный lease не держит (liveness по created+ttl) ──
printf 'session: wt-clean\nscope: file\npath: docs/x.md\ncreated: 2020-01-01T00:00:00Z\nttl_hours: 1\n' \
  >"$TMP/wt-clean/coordination/leases/old.lease"
t "истёкший lease → снова OK (exit 0)" 0 bash "$SUT" "$R"

harness_exit
