#!/usr/bin/env bash
# ops-log.sh — репо-уровневый append-only журнал эксплуатации: docs/ops-journal.md.
#
# Источник DORA-метрик (scripts/dora-metrics.sh) для событий, живущих ВНЕ прогонов пайплайна:
#   deploy:start | deploy:done | deploy:failed      — detail: sha/scope (деплой-скрипт проекта зовёт сам)
#   publish:done | publish:failed | publish:pr      — пишет scripts/agent-publish-main.sh (публикация
#                                                     в main / ветка под PR); деплоем НЕ являются —
#                                                     DORA берёт их, только если deploy:* в журнале нет
#   incident:open <slug> | incident:resolved <slug> — slug ПЕРВЫМ словом detail (MTTR-пара)
# Произвольные события допустимы. Формат строки = audit.md (| ts | event | detail |);
# '|' и переводы строк санируются (целостность таблицы).
#
# Usage: bash scripts/ops-log.sh <event> [detail]
set -euo pipefail

ops_root_error() {
  # HARNESS_OPS_ROOT может содержать путь машины: diagnostic намеренно не отражает значение (I-1/I-7).
  echo "ops-log: ОТКАЗ: HARNESS_OPS_ROOT должен быть canonical Git toplevel текущего repository" >&2
  exit 1
}

git_common_dir() { # $1 = existing Git worktree path; печатает physical common gitdir
  local base="$1" common
  common="$(git -C "$base" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) : ;;
    *) common="$base/$common" ;;
  esac
  ( cd "$common" 2>/dev/null && pwd -P )
}

git_without_repo_env() { # candidate-root Git lookup, isolated from caller/localized worktree
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git "$@"
  )
}

git_common_dir_without_repo_env() { # $1 = candidate toplevel; physical common gitdir
  local base="$1" common
  common="$(git_without_repo_env -C "$base" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common" in
    /*) : ;;
    *) common="$base/$common" ;;
  esac
  ( cd "$common" 2>/dev/null && pwd -P )
}

if [ -n "${HARNESS_OPS_ROOT:-}" ]; then
  # Внутренний override нужен disposable linked-worktree: operational telemetry должна осесть
  # в каноническом основном checkout, а не сделать одноразовый worktree dirty и погибнуть при teardown.
  # Fail closed: только absolute existing Git toplevel ТОГО ЖЕ repository (общий gitdir).
  case "$HARNESS_OPS_ROOT" in /*) : ;; *) ops_root_error;; esac
  requested_root="$(cd "$HARNESS_OPS_ROOT" 2>/dev/null && pwd -P)" || ops_root_error
  # Publisher localization экспортирует GIT_DIR/GIT_WORK_TREE текущего disposable checkout.
  # Они авторитетны для current_* ниже, но не должны перехватывать `git -C` manager override.
  override_top="$(git_without_repo_env -C "$requested_root" rev-parse --show-toplevel 2>/dev/null)" || ops_root_error
  override_top="$(cd "$override_top" 2>/dev/null && pwd -P)" || ops_root_error
  [ "$requested_root" = "$override_top" ] || ops_root_error
  current_top="$(git rev-parse --show-toplevel 2>/dev/null)" || ops_root_error
  current_common="$(git_common_dir "$current_top")" || ops_root_error
  override_common="$(git_common_dir_without_repo_env "$override_top")" || ops_root_error
  [ "$current_common" = "$override_common" ] || ops_root_error
  ROOT="$override_top"
else
  ROOT="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
fi
J="$ROOT/docs/ops-journal.md"
EV="${1:?event required (напр.: deploy:done | incident:open p1-export-hang)}"
DET="${2:--}"
EV="${EV//|/∕}";  EV="${EV//$'\n'/ }"
DET="${DET//|/∕}"; DET="${DET//$'\n'/ }"
# периметр-гард: журнал публичен (I-1) — event/detail с путём машины или
# IPv4 отклоняются ДО записи; регекс — пара confidence-гарда pipeline-state.sh, здесь на оба поля.
# Вызывающие обязаны '|| true' (I-8) — отказ телеметрии не должен ронять основную операцию.
if printf '%s %s' "$EV" "$DET" | grep -Eq '/(Users|home)/|[0-9]{1,3}(\.[0-9]{1,3}){3}'; then
  echo "ops-log: ОТКАЗ (I-1): event/detail несёт путь машины (/Users|/home) или IPv4 — журнал публичен; переформулируй без литералов среды" >&2
  exit 1
fi
TS="$(date -u +%FT%TZ)"

if [ ! -f "$J" ]; then
  mkdir -p "$ROOT/docs"
  printf '# Ops Journal — append-only журнал эксплуатации (пишет scripts/ops-log.sh)\n\n' > "$J"
  printf 'DORA-события: `deploy:start|done|failed` (деплой-скрипт проекта) · `publish:done|failed|noop|retry|pr` (agent-publish-main.sh) · `incident:open|resolved <slug>`; читает `scripts/dora-metrics.sh`.\n\n' >> "$J"
  printf '| ts (UTC) | event | detail |\n|---|---|---|\n' >> "$J"
fi
printf '| %s | %s | %s |\n' "$TS" "$EV" "$DET" >> "$J"
echo "ops-log: $EV${DET:+ — $DET}"
