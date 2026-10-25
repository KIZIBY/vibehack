#!/usr/bin/env bash
set -euo pipefail

die() {
  printf 'agent-localize-gitdir: %s\n' "$*" >&2
  exit 1
}

repo_root="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git rev-parse --show-toplevel 2>/dev/null
)" || die "not inside a git worktree"
git_file="$repo_root/.git"
git_dir="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git -C "$repo_root" rev-parse --absolute-git-dir
)" || die "cannot resolve registered gitdir"
# From here on the registered/localized tuple is selected explicitly. Discard all caller-provided
# repository selectors so ancestry/copy/publish probes cannot escape through a foreign index/common.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
local_gitdir="$repo_root/.codex-worktree-git"
quarantine_root="$repo_root/.codex-gitdir-quarantine"
stage_gitdir=""

cleanup_stage() {
  [ -n "$stage_gitdir" ] && rm -rf -- "$stage_gitdir" 2>/dev/null || true
}
trap cleanup_stage EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

physical_dir_from() {
  local base="$1" path="$2"
  case "$path" in
    /*) (cd "$path" 2>/dev/null && pwd -P) ;;
    *)  (cd "$base/$path" 2>/dev/null && pwd -P) ;;
  esac
}

registered_common_phys() {
  local common
  common="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git rev-parse --git-common-dir 2>/dev/null
  )" || return 1
  physical_dir_from "$repo_root" "$common"
}

common_dir="$(registered_common_phys)" || die "cannot resolve registered common repository"

managed_leaf_safe() { # $1 path: absent or regular non-symlink only
  local f="$1"
  if [ -e "$f" ] || [ -L "$f" ]; then
    [ -f "$f" ] && [ ! -L "$f" ] || return 1
  fi
  return 0
}

managed_leaves_safe() { # $1 localized gitdir
  local d="$1" leaf
  for leaf in .gitignore env.sh commondir gitdir; do
    managed_leaf_safe "$d/$leaf" || return 1
  done
}

reset_stage_managed_leaf() { # stage is private: unlink file/link before recreating, reject devices/dirs
  local f="$1"
  if [ -e "$f" ] || [ -L "$f" ]; then
    { [ -f "$f" ] || [ -L "$f" ]; } \
      || die "staged managed gitdir leaf is not a file/link"
    rm -f -- "$f" || die "cannot reset staged managed gitdir leaf"
  fi
}

ensure_self_ignored() { # $1 materialization directory
  local d="$1" t
  managed_leaf_safe "$d/.gitignore" \
    || die "local gitdir .gitignore is not a regular managed leaf"
  # The localized gitdir contains HEAD/index/reflogs and absolute commondir/gitdir paths. Keep
  # it invisible even to `git status --untracked-files=all` / `git add -A` without depending on
  # a target project's root .gitignore (which is project-owned and is not managed by bootstrap).
  t="$(umask 077; mktemp "$d/.gitignore.tmp.XXXXXX")" \
    || die "cannot allocate local gitdir self-ignore"
  if ! printf '*\n' > "$t" || ! mv -f -- "$t" "$d/.gitignore"; then
    rm -f -- "$t" 2>/dev/null || true
    die "cannot install self-ignore in local gitdir"
  fi
}

write_wrapper_env() { # $1 materialization directory; values deliberately point at final name
  local d="$1" t
  managed_leaf_safe "$d/env.sh" \
    || die "local gitdir env.sh is not a regular managed leaf"
  t="$(umask 077; mktemp "$d/env.sh.tmp.XXXXXX")" \
    || die "cannot allocate local gitdir wrapper environment"
  # %q keeps spaces/quotes/metacharacters in checkout paths safe when env.sh is sourced by Bash.
  {
    printf 'unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR\n'
    printf 'export GIT_DIR=%q\n' "$local_gitdir"
    printf 'export GIT_WORK_TREE=%q\n' "$repo_root"
  } > "$t" || {
    rm -f -- "$t" 2>/dev/null || true
    die "cannot write local gitdir wrapper environment"
  }
  mv -f -- "$t" "$d/env.sh" || {
    rm -f -- "$t" 2>/dev/null || true
    die "cannot publish local gitdir wrapper environment"
  }
}

local_gitdir_valid() { # $1 candidate: same worktree AND same physical common repository
  local d="$1" top candidate_common candidate_common_phys repo_phys top_phys
  [ -d "$d" ] && [ ! -L "$d" ] && [ -f "$d/HEAD" ] && [ ! -L "$d/HEAD" ] || return 1
  managed_leaves_safe "$d" || return 1
  top="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_DIR="$d" GIT_WORK_TREE="$repo_root" git rev-parse --show-toplevel 2>/dev/null
  )" || return 1
  candidate_common="$(
    cd "$repo_root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_DIR="$d" GIT_WORK_TREE="$repo_root" git rev-parse --git-common-dir 2>/dev/null
  )" || return 1
  candidate_common_phys="$(physical_dir_from "$repo_root" "$candidate_common")" || return 1
  repo_phys="$(cd "$repo_root" && pwd -P)" || return 1
  top_phys="$(cd "$top" && pwd -P)" || return 1
  [ "$top_phys" = "$repo_phys" ] && [ "$candidate_common_phys" = "$common_dir" ]
}

prepare_quarantine_root() {
  if [ -e "$quarantine_root" ] || [ -L "$quarantine_root" ]; then
    [ -d "$quarantine_root" ] && [ ! -L "$quarantine_root" ] \
      || die "localized gitdir quarantine root is not a real directory"
  else
    (umask 077; mkdir "$quarantine_root") || die "cannot create localized gitdir quarantine root"
  fi
  if [ -e "$quarantine_root/.gitignore" ] || [ -L "$quarantine_root/.gitignore" ]; then
    [ -f "$quarantine_root/.gitignore" ] && [ ! -L "$quarantine_root/.gitignore" ] \
      && [ "$(cat "$quarantine_root/.gitignore")" = "*" ] \
      || die "localized gitdir quarantine ignore contract is invalid"
  else
    printf '*\n' > "$quarantine_root/.gitignore" \
      || die "cannot self-ignore localized gitdir quarantine"
  fi
}

quarantine_existing_local() { # preserve exact existing payload in self-ignored quarantine
  local reason="$1" slot
  prepare_quarantine_root
  slot="$(umask 077; mktemp -d "$quarantine_root/local.XXXXXX")" \
    || die "cannot allocate quarantine for $reason localized gitdir"
  rmdir -- "$slot" || die "cannot prepare quarantine slot"
  if ! LOCALIZE_SRC="$local_gitdir" LOCALIZE_DST="$slot" perl -e '
      exit(rename($ENV{LOCALIZE_SRC}, $ENV{LOCALIZE_DST}) ? 0 : 1)
    '; then
    die "cannot atomically quarantine $reason localized gitdir"
  fi
  printf 'agent-localize-gitdir: quarantined %s local gitdir (id=%s); payload preserved\n' \
    "$reason" "${slot##*.}"
}

localized_relation() { # $1 structurally valid candidate → equal|local-ahead|stale|diverged
  local d="$1" registered_head local_head rc
  registered_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git -C "$repo_root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || return 1
  local_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$d" GIT_WORK_TREE="$repo_root" \
      git rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || return 1
  if [ "$registered_head" = "$local_head" ]; then printf 'equal'; return 0; fi
  rc=0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$d" GIT_WORK_TREE="$repo_root" \
      git merge-base --is-ancestor "$registered_head" "$local_head" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'local-ahead'; return 0; fi
  [ "$rc" -eq 1 ] || return 1
  rc=0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$d" GIT_WORK_TREE="$repo_root" \
      git merge-base --is-ancestor "$local_head" "$registered_head" 2>/dev/null
  ) || rc=$?
  if [ "$rc" -eq 0 ]; then printf 'stale'; return 0; fi
  [ "$rc" -eq 1 ] || return 1
  printf 'diverged'
}

gitdir_snapshot_signature() { # HEAD + index/split-index bytes, without path-dependent cksum output
  local d="$1" f found=0
  for f in "$d/HEAD" "$d/index" "$d"/sharedindex.*; do
    if [ -e "$f" ] || [ -L "$f" ]; then
      [ -f "$f" ] && [ ! -L "$f" ] || return 1
      printf '%s ' "${f##*/}"
      cksum < "$f" || return 1
      found=1
    fi
  done
  [ "$found" -eq 1 ]
}

gitdir_top_locks_absent() {
  local d="$1" f
  for f in "$d"/*.lock; do
    if [ -e "$f" ] || [ -L "$f" ]; then return 1; fi
  done
  return 0
}

# A previous fallback may have advanced detached HEAD only inside the localized gitdir. Reuse a
# local-ahead context; quarantine stale/invalid payload in a self-ignored container before rebuilding;
# require manual reconciliation for divergence. Nothing is silently deleted. The registered
# linked-worktree .git pointer remains immutable so common worktree teardown stays valid.
if [ -e "$local_gitdir" ] || [ -L "$local_gitdir" ]; then
  if ! local_gitdir_valid "$local_gitdir"; then
    # Historical partial copies and symlink impostors contain no trusted active Git authority.
    # Preserve every byte/link in quarantine, then rebuild from the registered context.
    quarantine_existing_local invalid
  else
    relation="$(localized_relation "$local_gitdir")" \
      || die "cannot prove existing localized HEAD relation; preserve it and reconcile explicitly"
    case "$relation" in
      equal|local-ahead)
        ensure_self_ignored "$local_gitdir"
        write_wrapper_env "$local_gitdir"
        if [ "$git_dir" = "$local_gitdir" ]; then
          printf 'agent-localize-gitdir: existing local gitdir is active in the current environment\n'
        else
          printf 'agent-localize-gitdir: reusing existing local gitdir; registered .git pointer preserved\n'
        fi
        printf 'agent-localize-gitdir: use wrapper:\n'
        printf '  bash scripts/agent-git.sh status\n'
        printf '  bash scripts/agent-publish-main.sh\n'
        exit 0
        ;;
      stale)
        # Local HEAD is an ancestor of registered HEAD, so it has no unique commit. Index/reflog
        # may still be useful, therefore quarantine rather than delete before refreshing.
        quarantine_existing_local stale
        ;;
      *) die "existing localized HEAD diverged; preserve it and reconcile explicitly" ;;
    esac
  fi
fi

if [ -d "$git_file" ] && [ ! -L "$git_file" ]; then
  printf 'agent-localize-gitdir: normal .git directory; no localization needed\n'
  exit 0
fi

if [ ! -f "$git_file" ]; then
  die "expected .git file for linked worktree"
fi

write_probe="$git_dir/.codex-write-test-$$"
if ( : >"$write_probe" ) 2>/dev/null; then
  rm -f "$write_probe"
  printf 'agent-localize-gitdir: linked gitdir is writable; no localization needed\n'
  exit 0
fi

printf 'agent-localize-gitdir: localizing gitdir\n'
printf 'agent-localize-gitdir: source=%s\n' "$git_dir"
printf 'agent-localize-gitdir: target=%s\n' "$local_gitdir"

gitdir_top_locks_absent "$git_dir" || die "registered gitdir has active lock files"
source_signature_before="$(gitdir_snapshot_signature "$git_dir")" \
  || die "cannot capture registered gitdir HEAD/index signature"
stage_gitdir="$(umask 077; mktemp -d "$repo_root/.codex-worktree-git.stage.XXXXXX")" \
  || die "cannot create same-filesystem staging gitdir"
ensure_self_ignored "$stage_gitdir"
cp -R "$git_dir"/. "$stage_gitdir"/
for managed_leaf in .gitignore env.sh commondir gitdir; do
  reset_stage_managed_leaf "$stage_gitdir/$managed_leaf"
done
ensure_self_ignored "$stage_gitdir"
gitdir_top_locks_absent "$git_dir" || die "registered gitdir changed under active lock during localization"
source_signature_after="$(gitdir_snapshot_signature "$git_dir")" \
  || die "cannot recapture registered gitdir HEAD/index signature"
stage_signature="$(gitdir_snapshot_signature "$stage_gitdir")" \
  || die "cannot capture staged gitdir HEAD/index signature"
[ "$source_signature_before" = "$source_signature_after" ] \
  && [ "$source_signature_after" = "$stage_signature" ] \
  || die "registered HEAD/index changed during localization"

printf '%s\n' "$common_dir" >"$stage_gitdir/commondir"
printf '%s/.git\n' "$repo_root" >"$stage_gitdir/gitdir"
rm -f "$stage_gitdir"/*.lock
write_wrapper_env "$stage_gitdir"
local_gitdir_valid "$stage_gitdir" \
  || die "staged local gitdir failed same-repository validation"
[ "$(localized_relation "$stage_gitdir")" = equal ] \
  || die "registered HEAD changed while staging local gitdir"
gitdir_top_locks_absent "$git_dir" || die "registered gitdir locked before atomic publish"
source_signature_final="$(gitdir_snapshot_signature "$git_dir")" \
  || die "cannot perform final registered HEAD/index signature check"
[ "$source_signature_final" = "$stage_signature" ] \
  || die "registered HEAD/index changed before atomic publish"

# Perl rename is one atomic same-filesystem syscall and fails instead of nesting staging under an
# existing winner. A concurrent valid winner is reused; an invalid destination remains fail-closed.
if LOCALIZE_SRC="$stage_gitdir" LOCALIZE_DST="$local_gitdir" perl -e '
    exit(rename($ENV{LOCALIZE_SRC}, $ENV{LOCALIZE_DST}) ? 0 : 1)
  '; then
  stage_gitdir=""
  gitdir_top_locks_absent "$git_dir" || {
    quarantine_existing_local race
    die "registered gitdir locked during atomic publish; localized payload quarantined"
  }
  source_signature_post="$(gitdir_snapshot_signature "$git_dir")" \
    || {
      quarantine_existing_local race
      die "cannot verify registered HEAD/index after atomic publish; localized payload quarantined"
    }
  [ "$source_signature_post" = "$source_signature_final" ] || {
    quarantine_existing_local race
    die "registered HEAD/index changed during atomic publish; localized payload quarantined"
  }
  published_signature="$(gitdir_snapshot_signature "$local_gitdir")" \
    || {
      quarantine_existing_local race
      die "cannot verify published localized HEAD/index; localized payload quarantined"
    }
  [ "$published_signature" = "$stage_signature" ] || {
    quarantine_existing_local race
    die "published localized gitdir changed during atomic publish; payload quarantined"
  }
  local_gitdir_valid "$local_gitdir" \
    || {
      quarantine_existing_local race
      die "published localized gitdir failed same-repository validation; payload quarantined"
    }
  published_relation="$(localized_relation "$local_gitdir")" \
    || {
      quarantine_existing_local race
      die "cannot verify published localized HEAD relation; payload quarantined"
    }
  [ "$published_relation" = equal ] || {
    quarantine_existing_local race
    die "published localized gitdir changed during atomic publish; payload quarantined"
  }
elif local_gitdir_valid "$local_gitdir" \
    && relation="$(localized_relation "$local_gitdir")" \
    && { [ "$relation" = equal ] || [ "$relation" = local-ahead ]; }; then
  cleanup_stage
  stage_gitdir=""
  ensure_self_ignored "$local_gitdir"
  write_wrapper_env "$local_gitdir"
  printf 'agent-localize-gitdir: concurrent valid local gitdir won; reusing it\n'
else
  die "atomic publish of local gitdir failed and no valid concurrent winner exists"
fi

printf 'agent-localize-gitdir: ready; registered .git pointer preserved\n'
printf 'agent-localize-gitdir: use wrapper:\n'
printf '  bash scripts/agent-git.sh status\n'
printf '  bash scripts/agent-publish-main.sh\n'
