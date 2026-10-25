#!/usr/bin/env bash
# agent-worktree-memory-check.sh — детектор незакоммиченной памяти агентов в worktree
# (data-sacred: память, записанная в worktree, теряется при его удалении).
#
# Память агентов: agents/memory/<role>.md, архив — agents/memory/archive/<role>/<YYYY-MM>.md
# (docs/guides/MEMORY_CONVENTION.md). Протокол спасения — канон agents/roles/repo-hygiene.md
# («Worktree memory rescue»): dirty/untracked memory-файл диф-инспектируется, уникальный
# append-only контент портируется в канонический agents/memory/<role>.md ДО удаления worktree.
# Этот скрипт — детерминированный ДЕТЕКТОР для гейта «не удаляй worktree с непроверенной
# памятью»; сам перенос остаётся за агентом (нужна оценка diff).
#
# Плюс (симметрия memory-гейту): предупреждает о НЕПОГАШЕННОМ СВОЁМ lease worktree
# (session lease = имя ветки worktree, не просрочен) — иначе забытый lease блокирует чужие коммиты
# до истечения TTL. Advisory: снятие остаётся за агентом (`coordination-lease.sh release <slug>`).
# TTL/парсер lease не копируются — переиспользуются вызовом `coordination-lease.sh list` из cwd worktree.
#
# Usage: bash scripts/agent-worktree-memory-check.sh [repo-root] [exact-worktree]
# Exit:  0 = чисто (ни памяти под риском, ни непогашенных lease) · 1 = найдена dirty/untracked память
#        ИЛИ непогашенный свой lease/не удалось доказать clean · 2 = не git-репозиторий
set -uo pipefail   # НЕ -e: упавший детектор на одном worktree не должен прятать остальные

ROOT="${1:-.}"
TARGET_WT="${2:-}"
[ "$#" -le 2 ] || { echo "worktree-memory-check: FATAL: usage: $0 [repo-root] [exact-worktree]" >&2; exit 2; }
# A caller can inject arbitrarily many command-scope config pairs.  Scrub their names before the
# first repository probe; local/default Git config remains usable, while authority diffs below
# explicitly override every option that could hide a staged gitlink.
scrub_ambient_git_config() {
  local git_env_name
  for git_env_name in $(env | sed -n \
    -e 's/^\(GIT_CONFIG_KEY_[0-9][0-9]*\)=.*/\1/p' \
    -e 's/^\(GIT_CONFIG_VALUE_[0-9][0-9]*\)=.*/\1/p'); do
    unset "$git_env_name"
  done
  unset GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM
  export GIT_CONFIG_COUNT=0
}
scrub_ambient_git_config
# Repository authority comes from explicit ROOT/worktree arguments, never the caller's Git tuple.
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0

root_git() { # authoritative registry commands never inherit a caller's repository namespace
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$ROOT" "$@"
  )
}

root_git rev-parse --git-dir >/dev/null 2>&1 || { echo "worktree-memory-check: FATAL: $ROOT не git-репозиторий" >&2; exit 2; }
TARGET_PHYS=""
if [ -n "$TARGET_WT" ]; then
  TARGET_PHYS="$(cd "$TARGET_WT" 2>/dev/null && pwd -P)" || {
    echo "worktree-memory-check: UNVERIFIED target worktree $TARGET_WT — каталог недоступен"
    exit 1
  }
fi

# lease-хелпер лежит рядом (SELF_DIR, не cwd — вызывается из разных мест); отсутствует → lease-чек no-op
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
LEASE_SH="$SELF_DIR/coordination-lease.sh"
PRIVATE_TMP_HELPER="$SELF_DIR/private-temp-dir.pl"

physical_dir_from() { # $1 base, $2 absolute-or-base-relative directory → physical path
  local base="$1" path="$2"
  case "$path" in
    /*) (cd "$path" 2>/dev/null && pwd -P) ;;
    *)  (cd "$base/$path" 2>/dev/null && pwd -P) ;;
  esac
}

wt_effective_gitdir() { # $1 worktree → empty (registered) or validated same-repo local gitdir
  local wt="$1" local_gitdir="$1/.codex-worktree-git" top wt_phys top_phys
  local registered_common local_common registered_common_phys local_common_phys registered_head local_head rc _head
  if [ ! -e "$local_gitdir" ]; then return 0; fi
  [ -d "$local_gitdir" ] && [ ! -L "$local_gitdir" ] \
    && [ -f "$local_gitdir/HEAD" ] && [ ! -L "$local_gitdir/HEAD" ] || return 1
  top="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_DIR="$local_gitdir" GIT_WORK_TREE="$wt" git rev-parse --show-toplevel 2>/dev/null
  )" || return 1
  wt_phys="$(cd "$wt" 2>/dev/null && pwd -P)" || return 1
  top_phys="$(cd "$top" 2>/dev/null && pwd -P)" || return 1
  [ "$wt_phys" = "$top_phys" ] || return 1
  registered_common="$(
    cd "$wt" 2>/dev/null || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git rev-parse --git-common-dir 2>/dev/null
  )" || return 1
  local_common="$(
    cd "$wt" 2>/dev/null || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_DIR="$local_gitdir" GIT_WORK_TREE="$wt" git rev-parse --git-common-dir 2>/dev/null
  )" || return 1
  registered_common_phys="$(physical_dir_from "$wt" "$registered_common")" || return 1
  local_common_phys="$(physical_dir_from "$wt" "$local_common")" || return 1
  [ "$registered_common_phys" = "$local_common_phys" ] || return 1
  registered_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git -C "$wt" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || return 1
  local_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$wt" \
      git rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || return 1
  for _head in "$registered_head" "$local_head"; do
    case "$_head" in ''|*[!0-9a-f]*) return 1;; esac
    case "${#_head}" in 40|64) : ;; *) return 1;; esac
  done
  if [ "$registered_head" != "$local_head" ]; then
    rc=0
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_gitdir" GIT_WORK_TREE="$wt" \
      git merge-base --is-ancestor "$registered_head" "$local_head" 2>/dev/null || rc=$?
    [ "$rc" -eq 0 ] || return 1
  fi
  printf '%s' "$local_gitdir"
}

wt_git() { # $1 worktree, remaining argv = git argv in effective HEAD/index namespace
  local wt="$1" gitdir
  shift
  gitdir="$(wt_effective_gitdir "$wt")" || return 1
  if [ -n "$gitdir" ]; then
    (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
      export GIT_DIR="$gitdir" GIT_WORK_TREE="$wt"
      git "$@"
    )
  else
    (
      unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
      git -C "$wt" "$@"
    )
  fi
}

wt_run() { # $1 worktree, remaining argv = child inheriting effective Git namespace
  local wt="$1" gitdir
  shift
  gitdir="$(wt_effective_gitdir "$wt")" || return 1
  (
    cd "$wt" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    if [ -n "$gitdir" ]; then export GIT_DIR="$gitdir" GIT_WORK_TREE="$wt"; fi
    "$@"
  )
}

strong_memory_status() { # $1 worktree → status-like lines for agents/, fail-closed
  local wt="$1" proof proof_id staged tracked untracked rc=0 cleanup_rc=0 git_dir head tmp_base
  [ -r "$PRIVATE_TMP_HELPER" ] || return 2
  tmp_base="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || return 2
  proof="$(umask 077; mktemp -d "$tmp_base/wt-memory-proof.XXXXXX" 2>/dev/null)" || return 2
  proof_id="$(perl "$PRIVATE_TMP_HELPER" id "$proof" 2>/dev/null)" \
    || { rmdir "$proof" >/dev/null 2>&1 || true; return 2; }

  # The effective real index is authoritative only for staged memory. Explicit diff options expose
  # gitlinks even under hostile config; live bytes below are proved raw against HEAD without an index.
  staged="$(wt_git "$wt" diff --cached --name-status --no-ext-diff --no-textconv \
    --ignore-submodules=none HEAD -- 'agents/' 2>/dev/null)" \
    || rc=1
  if [ "$rc" -eq 0 ]; then
    wt_git "$wt" ls-files -v -z 2>/dev/null | perl -0ne '
      $bad=1 if /\A(?:[a-z]|S) /; END { exit($bad ? 1 : 0) }
    ' || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    git_dir="$(wt_git "$wt" rev-parse --absolute-git-dir 2>/dev/null)" || rc=1
    head="$(wt_git "$wt" rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    tracked="$(perl "$PRIVATE_TMP_HELPER" worktree-proof "$proof" "$proof_id" \
      "$git_dir" "$wt" "$head" paths 2>/dev/null | perl -0e '
        local $/; my $raw=<STDIN>//q{}; for my $p (split /\0/,$raw) {
          print " M\t$p\n" if $p =~ m{\Aagents/};
        }
      ')" || rc=1
  fi
  if [ "$rc" -eq 0 ]; then
    # Deliberately omit --exclude-standard: ignored memory is still user data and would also be
    # destroyed by `git worktree remove --force`.
    untracked="$(perl "$PRIVATE_TMP_HELPER" worktree-proof "$proof" "$proof_id" \
      "$git_dir" "$wt" "$head" untracked agents 2>/dev/null | perl -0e '
        local $/; my $raw=<STDIN>//q{}; for my $p (split /\0/,$raw) { print "$p\n" if length $p }
      ')" || rc=1
  fi
  perl "$PRIVATE_TMP_HELPER" cleanup "$proof" "$proof_id" >/dev/null 2>&1 || cleanup_rc=1
  [ "$cleanup_rc" -eq 0 ] || rc=1
  [ "$rc" -eq 0 ] || return 1

  [ -z "$staged" ] || printf '%s\n' "$staged"
  [ -z "$tracked" ] || printf '%s\n' "$tracked"
  [ -z "$untracked" ] || printf '%s\n' "$untracked" | sed 's/^/?? /'
}

found=0
matched=0
registry_status_seen=0
main_wt="$(root_git rev-parse --show-toplevel)"
main_phys="$(cd "$main_wt" && pwd -P)" || exit 2

# Porcelain -z preserves the full path (including spaces/newlines). Perl emits exact NUL-delimited
# path/branch pairs; Bash variables cannot contain NUL, but can safely contain every path byte Git
# permits except NUL itself. A detached worktree gets an empty branch field.
worktree_pairs_nul() {
  local raw
  if raw="$(root_git worktree list --porcelain -z 2>/dev/null)"; then
    printf '%s' "$raw" | perl -0777 -e '
    use strict; use warnings;
    my $raw = do { local $/; <STDIN> } // "";
    for my $rec (split /\0\0/, $raw) {
      next unless length $rec;
      my ($w) = $rec =~ /(?:^|\0)worktree ([^\0]*)/;
      die "malformed worktree porcelain" unless defined $w;
      my ($b) = $rec =~ /(?:^|\0)branch refs\/heads\/([^\0]*)/;
      $b = "" unless defined $b;
      print $w, "\0", $b, "\0";
    }
  '
  else
    # Git versions before porcelain -z (for example Debian/Ubuntu images with Git 2.34)
    # still provide a record-oriented porcelain format. Convert it to the same NUL protocol.
    root_git worktree list --porcelain 2>/dev/null | perl -0777 -e '
      use strict; use warnings;
      my $raw = do { local $/; <STDIN> } // "";
      for my $rec (split /(?:\r?\n){2,}/, $raw) {
        my ($w) = $rec =~ /(?:^|\n)worktree (.*)/;
        next unless defined $w;
        my ($b) = $rec =~ /(?:^|\n)branch refs\/heads\/(.*)/;
        $b = "" unless defined $b;
        print $w, "\0", $b, "\0";
      }
    '
  fi
}

# Process substitution keeps the while-loop in this shell (so `found`/`matched` need no predictable
# path-only flag files).  The impossible empty-worktree pair carries producer status in-band;
# absence/truncation of that sentinel is fail-closed even though Bash cannot `wait` a process
# substitution producer directly.
worktree_pairs_nul_with_status() {
  local rc=0
  worktree_pairs_nul || rc=$?
  printf '\0%s\0' "$rc"
}

list_rc=0
while IFS= read -r -d '' wt; do
  IFS= read -r -d '' br || {
    echo "worktree-memory-check: UNVERIFIED — truncated worktree registry"
    found=1; list_rc=1
    break
  }
  if [ -z "$wt" ]; then
    registry_status_seen=1
    [ "$br" = 0 ] || { found=1; list_rc=1; }
    break
  fi
  wt_phys="$(cd "$wt" 2>/dev/null && pwd -P)" || {
    # A targeted check must not be blocked by an unrelated stale registration, but its own missing
    # path is unsafe. Aggregate mode still reports every stale registration.
    if [ -z "$TARGET_PHYS" ] || [ "$wt" = "$TARGET_WT" ]; then
      echo "worktree-memory-check: UNVERIFIED worktree $wt — каталог недоступен"
      found=1
    fi
    continue
  }
  if [ -n "$TARGET_PHYS" ] && [ "$wt_phys" != "$TARGET_PHYS" ]; then continue; fi
  [ -z "$TARGET_PHYS" ] || matched=1
  [ "$wt_phys" = "$main_phys" ] && continue   # основной checkout проверяет обычная гигиена
  status_out=""; status_rc=0
  status_out="$(strong_memory_status "$wt" 2>&1)" || status_rc=$?
  if [ "$status_rc" -ne 0 ]; then
    echo "worktree-memory-check: UNVERIFIED worktree $wt — strong effective Git proof недоступен"
    echo "worktree-memory-check:   → destructive cleanup запрещён до восстановления gitdir/index"
    found=1
  else
    dirty="$(printf '%s\n' "$status_out" | grep -E '(^|[[:space:]])agents/memory/' || true)"
  fi
  if [ "$status_rc" -eq 0 ] && [ -n "$dirty" ]; then
    echo "worktree-memory-check: DIRTY MEMORY в $wt:"
    printf '%s\n' "$dirty" | sed 's/^/  /'
    echo "worktree-memory-check:   → перед удалением worktree портируй уникальный контент в канонический agents/memory/<role>.md (agents/roles/repo-hygiene.md, Worktree memory rescue)"
    found=1
  fi
  # Симметрия memory-предупреждению: worktree держит НЕПОГАШЕННЫЙ СВОЙ lease?
  # session lease = имя ветки worktree; TTL/парсер переиспользуются вызовом `coordination-lease.sh list`
  # из cwd этого worktree (не копия логики); detached worktree (br пуст) — lease без session бессмыслен, пропуск.
  if [ -n "$br" ] && [ -f "$LEASE_SH" ] && [ -d "$wt/coordination/leases" ]; then
    # list печатает по строке на lease: «slug session scope истекает-через»; фильтр — свой session
    # (== ветка worktree) И живой TTL (столбец истекает-через ≠ «истёк»/«битый»); заголовок отсеян по slug.
    mine="$( wt_run "$wt" bash "$LEASE_SH" list 2>/dev/null | awk -v s="$br" '
      $1=="slug" { next }
      $2==s && $NF!="истёк" && $NF!="битый" { print $1 }
    ' || true )"
    if [ -n "$mine" ]; then
      echo "worktree-memory-check: НЕПОГАШЕННЫЙ LEASE worktree $wt (ветка $br):"
      printf '%s\n' "$mine" | sed 's/^/  lease: /'
      printf '%s\n' "$mine" | while IFS= read -r sl; do
        [ -n "$sl" ] && echo "worktree-memory-check:   → сними перед удалением worktree: coordination-lease.sh release $sl"
      done
      found=1
    fi
  fi
  :
done < <(worktree_pairs_nul_with_status)
[ "$registry_status_seen" -eq 1 ] || { found=1; list_rc=1; }
[ "$list_rc" -eq 0 ] || {
  echo "worktree-memory-check: UNVERIFIED — worktree registry нельзя разобрать"
  found=1
}
[ -z "$TARGET_PHYS" ] || [ "$matched" -eq 1 ] || {
  echo "worktree-memory-check: UNVERIFIED target worktree $TARGET_WT — нет exact registration"
  found=1
}

if [ "$found" -eq 0 ]; then
  echo "worktree-memory-check: OK — незакоммиченной памяти агентов и непогашенных lease в worktree нет"
fi
exit "$found"
