#!/usr/bin/env bash
# tests/harness/cases/runtime-adapter.sh — рантайм-адаптеры ↔ универсальный pipeline-state API. Инвариант: I-17.
#
# Контекст: .claude/commands/pipeline*.md — тонкие provider-адаптеры поверх
# scripts/pipeline-state.sh. Реальный, тестируемый контракт — это state-CLI, которую они
# вызывают, а НЕ прозаический текст промптов. Порт behavioral-эссенции старого
# tests/runtime-adapter-v4-contract.sh: выброшены ВСЕ grep'ы prose команд; оставлена и усилена
# единственная герметичная state-машина-смока (bugfix-scope не является bypass'ом гейтов).
#
# Что доказываем поведенчески:
#   1. каждый рекламируемый scope (feature|bugfix|enterprise) — first-class: init создаёт ОДИН и
#      тот же полный V4-скелет (State-Version 4 · Delivery-Contract · 4 dash-root), а не shortcut;
#   2. неизвестный scope отвергается fail-closed (exit 2, state.md не создан);
#   3. scope НЕ обходит гейт: сразу после init stage-1 доступен, но stage-3 BLOCKED одинаково для
#      bugfix и feature (approval/design authority обязательны независимо от scope);
#   4. повторный init существующего spec — no-op (data sacred): scope не переписывается.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "runtime-adapter (поведенческий паритет с pipeline-state)"

STATE_CLI="$ROOT/scripts/pipeline-state.sh"

# Герметичный git-worktree под $TMP: pipeline-state привязывает Git-authority к cwd вызова, поэтому
# ST() всегда исполняется из корня фикстуры с каноническим relative-селектором specs/NNN-slug.
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email ci@harness.local
git -C "$REPO" config user.name  ci-harness

ST() { ( cd "$REPO" && bash "$STATE_CLI" "$@" ); }

# skel_ok <leaf> <scope> — init должен родить полный V4-скелет, идентичный для любого scope:
# тот же State-Version/Delivery-Contract и ровно 4 незаполненных root'а (Design/Implementation/
# Evidence + Quality-HEAD). Именно это доказывает, что scope — метаданные, а не обход lifecycle.
skel_ok() {
  local f="$REPO/specs/$1/state.md"
  [ -f "$f" ] || return 1
  grep -qxF -- '- State-Version: 4' "$f" || return 1
  grep -qxF -- '- Delivery-Contract: architecture-evidence-v1' "$f" || return 1
  grep -qxF -- "- Scope: $2" "$f" || return 1
  [ "$(grep -Ec '^- (Design-Root|Implementation-Root|Evidence-Root|Quality-HEAD): —$' "$f")" -eq 4 ]
}

# ── SCOPE-ПАРИТЕТ: каждый рекламируемый scope init'ится в один и тот же полный V4-контракт ──
run_scope() { # <scope> <leaf>
  local scope="$1" leaf="$2"
  t "init scope=$scope: принят, exit 0" 0 ST init "specs/$leaf" "фикстура $scope" "$scope"
  t "init scope=$scope: полный V4-скелет (version+contract+scope, 4 dash-root — не shortcut)" 0 \
    skel_ok "$leaf" "$scope"
  t "validate-state scope=$scope: shape валиден (exit 0)" 0 ST validate-state "specs/$leaf"
}
run_scope feature    001-feature
run_scope bugfix     002-bugfix
run_scope enterprise 003-enterprise

# ── НЕГАТИВ: неизвестный scope отвергается fail-closed ──
t "init: неизвестный scope отвергается (exit 2)" 2 ST init "specs/090-bad" "фикстура" wibble
bad_no_state() { [ ! -e "$REPO/specs/090-bad/state.md" ]; }
t "init: отклонённый scope не оставил state.md (fail-closed)" 0 bad_no_state

# ── ГЕЙТ НЕ BYPASS'ится SCOPE'ом (эссенция старой смоки :119-129, усиленная) ──
# Сразу после init нормальный старт (stage-1) доступен, но переход в поздний stage-3 BLOCKED,
# пока нет approval/design authority — одинаково для bugfix и feature. Exit 1 (а не 2) значит:
# Git-контекст валиден, блокирует именно гейт, а не окружение.
t "gate bugfix: stage-1 доступен сразу после init (scope не ломает старт)" 0 \
  ST check "specs/002-bugfix" stage-1-creative
t "gate bugfix: stage-3 BLOCKED — нет approval/design authority (scope ≠ bypass гейта)" 1 \
  ST check "specs/002-bugfix" stage-3-dev
t "gate feature: stage-3 тоже BLOCKED (гейт scope-независим — паритет)" 1 \
  ST check "specs/001-feature" stage-3-dev

# ── RESUME / DATA-SACRED: повторный init не переписывает существующий spec (нельзя сменить scope) ──
cp "$REPO/specs/002-bugfix/state.md" "$TMP/bugfix.before"
t "resume: повторный init существующего spec — no-op (exit 0)" 0 \
  ST init "specs/002-bugfix" "совсем другое описание" enterprise
resume_unchanged() { cmp -s "$TMP/bugfix.before" "$REPO/specs/002-bugfix/state.md"; }
t "resume: data sacred — байты state.md неизменны, scope остался bugfix" 0 resume_unchanged

harness_exit
