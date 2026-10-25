#!/usr/bin/env bash
set -euo pipefail

die() { printf 'agent-git: %s\n' "$*" >&2; exit 1; }
physical_dir_from() {
  case "$2" in
    /*) (cd "$2" 2>/dev/null && pwd -P) ;;
    *)  (cd "$1/$2" 2>/dev/null && pwd -P) ;;
  esac
}
full_oid_valid() { LC_ALL=C printf '%s\n' "$1" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'; }

repo_root="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git rev-parse --show-toplevel 2>/dev/null
)" || die "not inside a registered git worktree"
local_gitdir="$repo_root/.codex-worktree-git"

if [ -e "$local_gitdir" ]; then
  [ -d "$local_gitdir" ] && [ ! -L "$local_gitdir" ] \
    && [ -f "$local_gitdir/HEAD" ] && [ ! -L "$local_gitdir/HEAD" ] \
    || die "localized gitdir malformed"
  top="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$repo_root" \
      git rev-parse --show-toplevel 2>/dev/null
  )" || die "localized worktree unavailable"
  registered_common="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git rev-parse --git-common-dir 2>/dev/null
  )" || die "registered common repository unavailable"
  local_common="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$repo_root" \
      git rev-parse --git-common-dir 2>/dev/null
  )" || die "localized common repository unavailable"
  root_phys="$(cd "$repo_root" && pwd -P)" || die "registered worktree unavailable"
  top_phys="$(cd "$top" && pwd -P)" || die "localized worktree unavailable"
  registered_common_phys="$(physical_dir_from "$repo_root" "$registered_common")" \
    || die "registered common repository path invalid"
  local_common_phys="$(physical_dir_from "$repo_root" "$local_common")" \
    || die "localized common repository path invalid"
  [ "$root_phys" = "$top_phys" ] && [ "$registered_common_phys" = "$local_common_phys" ] \
    || die "localized gitdir is not bound to registered repository"
  registered_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || die "registered HEAD is not a commit"
  local_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$repo_root" \
      git rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || die "localized HEAD is not a commit"
  full_oid_valid "$registered_head" && full_oid_valid "$local_head" \
    || die "registered/localized HEAD is not canonical"
  if [ "$registered_head" != "$local_head" ]; then
    if (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
      GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$repo_root" \
        git merge-base --is-ancestor "$registered_head" "$local_head" 2>/dev/null
    ); then
      : # expected recovery shape: localized HEAD is ahead
    elif (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
      GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$repo_root" \
        git merge-base --is-ancestor "$local_head" "$registered_head" 2>/dev/null
    ); then
      die "localized HEAD is stale; relocalize/retest before Git mutation"
    else
      die "registered/localized histories diverged; explicit recovery required"
    fi
  fi
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export GIT_DIR="$local_gitdir"
  export GIT_WORK_TREE="$repo_root"
else
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
fi

exec git "$@"
