#!/usr/bin/env bash
# agent-preflight.sh — read-only проверка готовности рабочей копии перед работой/публикацией.
#
# Usage: bash scripts/agent-preflight.sh [remote=origin] [branch=main]
# Exit:  строго 0|1 (классы различаются WARN-маркером, не кодом). Ничего не мутирует.
#
# Проверки: git-селекторы и worktree (в т.ч. локализованный gitdir), publish_state против
# remote/branch (bounded ls-remote), backend задач и его доступность, гигиена корня.
# Backend задач: env ISSUE_BACKEND → первая строка PROJECT.md, начинающаяся с `ISSUE_BACKEND=`
# (обязана точно совпасть с `^ISSUE_BACKEND=(github|none)\s*$`) → `none`; неизвестное значение →
# WARN issue_contract=invalid-backend (fail closed). `none` → issue-пробы пропускаются;
# `github` → репозиторий только из canonical origin (github.com), GH_REPO может лишь повторять его.
set +exv
set +o pipefail
export CDPATH=
set -u
unset PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC 2>/dev/null || true

remote="${1:-origin}"
branch="${2:-main}"
status=0
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" || SELF_DIR=""
PRIVATE_TMP_HELPER="$SELF_DIR/private-temp-dir.pl"
PROVIDER_ENV_HELPER="$SELF_DIR/provider-env.pl"
SELF_DIR_ID=""
if [ -n "$SELF_DIR" ]; then
  SELF_DIR_ID="$(ROOT="$SELF_DIR" perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR -e '
    sysopen(my $fh,$ENV{ROOT},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @s=stat($fh);
    exit 1 unless @s && S_ISDIR($s[2]); print $s[0],q{:},$s[1];
  ' 2>/dev/null)" || SELF_DIR_ID=""
fi

# Git config/worktree/object selectors are authority, not harmless ambient tuning. Remove them
# before even validating selectors or discovering the worktree; transport auth such as
# GIT_SSH_COMMAND intentionally remains available to the bounded remote probe.
clear_git_authority_env() {
  local i=0
  while [ "$i" -lt 1024 ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i" 2>/dev/null || true
    i=$((i + 1))
  done
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    GIT_CONFIG_NOSYSTEM GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE GIT_NAMESPACE GIT_SHALLOW_FILE GIT_GRAFT_FILE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_PREFIX GIT_INTERNAL_SUPER_PREFIX \
    GIT_ATTR_SOURCE GIT_EXEC_PATH GIT_TRACE GIT_TRACE_SETUP GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS \
    GIT_TRACE_PERFORMANCE GIT_TRACE_SHALLOW GIT_TRACE_CURL GIT_TRACE_REDACT GIT_TRACE2 \
    GIT_TRACE2_EVENT GIT_TRACE2_PERF 2>/dev/null || true
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0
}
clear_git_authority_env

# per-run tmp + trap-очистка: фиксированные /tmp/agent-preflight-* копились мусором и
# сталкивались между параллельными агентами (у команды не один пишущий агент).
# A failed allocator/canonicalizer must not echo TMPDIR (often a runner-private path).
preflight_tmp_fatal() {
  printf 'agent-preflight: WARN: private temp unavailable\n' >&2
  exit 1
}
tmp_base="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" || preflight_tmp_fatal
[ -r "$PRIVATE_TMP_HELPER" ] || preflight_tmp_fatal
case "${HARNESS_PRIVATE_TMP_LEAF_TEST_PAUSE:-}" in
  ""|agent-git) :;;
  *) preflight_tmp_fatal;;
esac
if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = 1 ] \
   || [ -n "${HARNESS_PRIVATE_TMP_LEAF_TEST_PAUSE:-}" ]; then
  { : >&9; } 2>/dev/null || preflight_tmp_fatal
fi
tmpdir="$(umask 077; mktemp -d "$tmp_base/agent-preflight.XXXXXX" 2>/dev/null)" \
  || preflight_tmp_fatal
[ -n "$tmpdir" ] || preflight_tmp_fatal
chmod 0700 "$tmpdir" >/dev/null 2>&1 \
  || { rmdir "$tmpdir" >/dev/null 2>&1 || true; preflight_tmp_fatal; }
tmpdir_canonical="$(cd "$tmpdir" 2>/dev/null && pwd -P)" \
  || { rmdir "$tmpdir" >/dev/null 2>&1 || true; preflight_tmp_fatal; }
tmpdir="$tmpdir_canonical"
tmpdir_id="$(perl "$PRIVATE_TMP_HELPER" id "$tmpdir" 2>/dev/null)" \
  || { rmdir "$tmpdir" >/dev/null 2>&1 || true; preflight_tmp_fatal; }
preflight_tmp_guard() {
  perl "$PRIVATE_TMP_HELPER" guard "$tmpdir" "$tmpdir_id" >/dev/null 2>&1
}
preflight_snapshot_write() { # leaf; stdin -> inode/digest/length record
  perl "$PRIVATE_TMP_HELPER" write "$tmpdir" "$tmpdir_id" "$1" 2>/dev/null
}
preflight_snapshot_read() { # leaf, record -> verified bytes
  perl "$PRIVATE_TMP_HELPER" read "$tmpdir" "$tmpdir_id" "$1" "$2" 2>/dev/null
}
preflight_leaf_test_pause() { # causal test hook; never enabled in production
  [ "${HARNESS_PRIVATE_TMP_LEAF_TEST_PAUSE:-}" = "$1" ] || return 0
  PREFLIGHT_TEST_LEAF="$2" perl -e '
    use strict; use warnings; open(my $gate,q{>&=9}) or exit 1;
    my $msg=q{leaf=}.$ENV{PREFLIGHT_TEST_LEAF}.q{ pid=}.$$."\n";
    syswrite($gate,$msg,length($msg))==length($msg) or exit 1; close($gate) or exit 1;
    kill(q{STOP},$$)==1 or exit 1;
  ' || return 1
  preflight_tmp_guard
}
if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = 1 ]; then
  printf 'ready\n' >&9 || preflight_tmp_fatal
  kill -STOP "$$" 2>/dev/null || preflight_tmp_fatal
  preflight_tmp_guard || preflight_tmp_fatal
fi
preflight_cleanup() {
  local rc="$?" cleanup_rc=0
  trap - EXIT
  perl "$PRIVATE_TMP_HELPER" cleanup "$tmpdir" "$tmpdir_id" >/dev/null 2>&1 || cleanup_rc=1
  if [ "$cleanup_rc" -ne 0 ]; then
    printf 'agent-preflight: WARN: private temp cleanup failed\n' >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap preflight_cleanup EXIT

note() {
  printf 'agent-preflight: %s\n' "$*"
}

warn() {
  printf 'agent-preflight: WARN: %s\n' "$*" >&2
  status=1
}

# Production has no ambient test-mode switch. The full test runner executes a private mechanical
# copy with this one literal changed to 1; no caller-controlled env or descriptor can widen the
# provider allowlist of the shipped consumer.
ISSUE_PROVIDER_TEST_ENABLED=0
{ exec 7<&-; } 2>/dev/null || true

# Keep the regex itself single-source while treating the source file as authority: no shell
# sourcing, no symlinks/hardlinks, and byte-identical reads from one descriptor.  A broken policy
# blocks issue probes with a metadata-only error.
SECRET_RE="$(POLICY_DIR="$SELF_DIR" POLICY_DIR_ID="$SELF_DIR_ID" \
  perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISREG -e '
    use strict; use warnings; my ($dir,$want)=@ENV{qw(POLICY_DIR POLICY_DIR_ID)};
    sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
    sysopen(my $root,$dir,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @root=stat($root);
    exit 1 unless @root && S_ISDIR($root[2]) && ($root[0].q{:}.$root[1]) eq $want;
    chdir($root) or exit 1; my $leaf=q{secret-patterns.sh}; my @named=lstat($leaf);
    exit 1 unless @named && !-l _ && S_ISREG($named[2]) && $named[3]==1;
    sysopen(my $fh,$leaf,O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($fh);
    exit 1 unless @opened && ident(@opened) eq ident(@named);
    local $/; my $raw=<$fh>//q{}; exit 1 if length($raw)>1048576;
    seek($fh,0,0) or exit 1; my $again=<$fh>//q{}; exit 1 if $again ne $raw;
    my @after=stat($fh); close $fh or exit 1; @named=lstat($leaf);
    exit 1 unless @after && @named && !-l _
      && ident(@after) eq ident(@opened) && ident(@named) eq ident(@opened);
    my @value; for my $line (split /\n/,$raw,-1) {
      next if $line=~/^\s*(?:#.*)?\z/;
      exit 1 unless $line=~/\ASECRET_RE=\x27([^\x27\x00-\x1f\x7f]+)\x27\z/; push @value,$1;
    }
    exit 1 unless @value==1; print $value[0];
  ' 2>/dev/null)" || SECRET_RE=""
if [ -z "$SECRET_RE" ]; then
  warn "issue_contract=secret-policy-invalid"
  exit "$status"
fi

if ! printf '%s\n' "$remote" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$' \
   || ! git check-ref-format --branch "$branch" >/dev/null 2>&1; then
  warn "git selector is invalid"
  exit "$status"
fi

# Every external probe is bounded as an owned POSIX session. A child may move to another process
# group with setpgid(2), so PGID-only teardown is insufficient; the shared private-temp supervisor
# proves the exact SID quiescent before returning. Stdout remains memory-bounded and NUL-rejected.
PREFLIGHT_NET_TIMEOUT="${AGENT_PREFLIGHT_NET_TIMEOUT:-15}"
case "$PREFLIGHT_NET_TIMEOUT" in [1-9]|[1-5][0-9]|60) :;; *) PREFLIGHT_NET_TIMEOUT=15;; esac
bounded() { # argv...; the whole owned session is reaped on timeout and early direct exit
  local meta rc out_leaf out_record err_leaf err_record extra pipe_rc
  preflight_tmp_guard || return 125
  meta="$(perl "$PRIVATE_TMP_HELPER" run-bounded "$tmpdir" "$tmpdir_id" \
    "$PREFLIGHT_NET_TIMEOUT" - - -- "$@")" || return 125
  IFS=$'\t' read -r rc out_leaf out_record err_leaf err_record extra <<EOF
$meta
EOF
  [ -z "${extra:-}" ] && case "$rc" in ''|*[!0-9]*) false;; *) [ "$rc" -le 255 ];; esac \
    && printf '%s\n' "$out_record" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    && printf '%s\n' "$err_record" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    || return 125
  preflight_tmp_guard || return 125
  set -o pipefail
  perl "$PRIVATE_TMP_HELPER" read "$tmpdir" "$tmpdir_id" "$out_leaf" "$out_record" \
    | perl -e '
      use strict; use warnings; my $total=0;
      while (1) { my $n=sysread(STDIN,my $buf,65536); exit 125 unless defined $n; last unless $n;
        $total+=$n; exit 125 if $total>4*1024*1024 || index($buf,"\0")>=0;
        my $off=0; while ($off<$n) { my $w=syswrite(STDOUT,$buf,$n-$off,$off);
          exit 125 unless defined($w) && $w>0; $off+=$w }
      }
    '
  pipe_rc=$?
  set +o pipefail
  [ "$pipe_rc" -eq 0 ] || return 125
  preflight_tmp_guard || return 125
  return "$rc"
}

# Pin a repository-relative companion (agent-git.sh, provider-env.pl) without following a symlink or
# accepting an escape outside the anchor directory.  Requiring a single-link regular file also
# prevents a hardlink from smuggling an external mutable file into the authority path.
freeze_repo_file() { # fd-anchored source -> helper-recorded private leaf
  local expected_root_id="${4:-}"
  perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISREG,S_ISDIR -e '
    use strict; use warnings;
    my ($root,$rel,$private_leaf,$root_id,$helper,$tmp,$tmp_id)=@ARGV;
    sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
    exit 1 if !defined($rel) || $rel eq q{} || $rel =~ m{^/};
    my @parts=split m{/},$rel,-1;
    exit 1 if !@parts;
    for my $part (@parts) {
      exit 1 if $part eq q{} || $part eq q{.} || $part eq q{..}
        || $part !~ /\A[A-Za-z0-9_.-]+\z/;
    }
    sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
    my @root=stat($root_fh); exit 1 unless @root && S_ISDIR($root[2]);
    exit 1 if length($root_id) && ($root[0].q{:}.$root[1]) ne $root_id;
    chdir($root_fh) or exit 1;
    my @dirs=($root_fh);
    for my $i (0..$#parts-1) {
      my $part=$parts[$i]; my @named=lstat($part);
      exit 1 unless @named && S_ISDIR($named[2]) && !-l _;
      sysopen(my $dir_fh,$part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir_fh);
      exit 1 unless @opened && ident(@opened) eq ident(@named); push @dirs,$dir_fh; chdir($dir_fh) or exit 1;
    }
    my $leaf=$parts[-1]; sysopen(my $fh,$leaf,O_RDONLY|O_NOFOLLOW) or exit 1;
    my @s=stat($fh); exit 1 unless @s && S_ISREG($s[2]) && $s[3]==1;
    my @p=lstat($leaf); exit 1 unless @p && !-l _ && ident(@p) eq ident(@s);
    my $raw=q{};
    while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n; last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
    sysseek($fh,0,0) >= 0 or exit 1; my $confirm=q{};
    while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n; last unless $n; $confirm.=$buf; exit 1 if length($confirm)>16777216 }
    exit 1 if $confirm ne $raw || index($raw,qq{\0})>=0; my @after=stat($fh); close $fh or exit 1;
    my @named=lstat($leaf); exit 1 unless @after && @named && !-l _ && ident(@after) eq ident(@s) && ident(@named) eq ident(@s);
    open(my $sink,q{|-},q{perl},$helper,q{write},$tmp,$tmp_id,$private_leaf) or exit 1;
    my $off=0; while ($off<length($raw)) { my $n=syswrite($sink,$raw,length($raw)-$off,$off); exit 1 unless defined($n) && $n; $off+=$n }
    close $sink or exit 1;
  ' "$1" "$2" "$3" "$expected_root_id" "$PRIVATE_TMP_HELPER" "$tmpdir" "$tmpdir_id" 2>/dev/null
}

# Pin the shared provider environment boundary through the same descriptor/inode path used for
# other executable companions. Missing or mutable boundary blocks provider probes, not Git hygiene.
PROVIDER_ENV_OK=1
PROVIDER_ENV_RECORD=""; PROVIDER_ENV_SCRIPT=""
if [ -z "$SELF_DIR" ] || [ -z "$SELF_DIR_ID" ] || [ ! -r "$PROVIDER_ENV_HELPER" ] \
  || ! PROVIDER_ENV_RECORD="$(freeze_repo_file "$SELF_DIR" \
    "provider-env.pl" "provider-env.pl" "$SELF_DIR_ID")" \
  || ! PROVIDER_ENV_SCRIPT="$(preflight_snapshot_read provider-env.pl "$PROVIDER_ENV_RECORD")" \
  || [ -z "$PROVIDER_ENV_SCRIPT" ] \
  || ! printf '%s' "$PROVIDER_ENV_SCRIPT" | perl -c - >/dev/null 2>&1 \
  || ! preflight_tmp_guard; then
  warn "issue_contract=provider-env-invalid"
  PROVIDER_ENV_OK=0
fi

provider_bounded() { # gh argv; shared clean env + private HOME/TMP
  [ "$PROVIDER_ENV_OK" -eq 1 ] && [ -n "$PROVIDER_ENV_SCRIPT" ] || return 125
  bounded perl -e "$PROVIDER_ENV_SCRIPT" github "$tmpdir" "$tmpdir_id" \
    "$ISSUE_PROVIDER_TEST_ENABLED" "$SECRET_RE" -- "$@"
}

preflight_provider_metadata_secret_free() {
  {
    local value
    for value in "$@"; do printf '%s\0' "$value"; done
  } | PREFLIGHT_SECRET_RE="$SECRET_RE" perl -0777 -e '
    use strict; use warnings; my $raw=<>//q{}; exit 2 if length($raw)>4*1024*1024;
    my $re=eval { qr/$ENV{PREFLIGHT_SECRET_RE}/ }; exit 2 unless $re;
    exit($raw=~/$re/ ? 1 : 0);
  '
}

repo_root="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git rev-parse --show-toplevel 2>/dev/null
)"
local_gitdir="$repo_root/.codex-worktree-git"
if [ -e "$local_gitdir" ]; then
  preflight_tmp_guard || preflight_tmp_fatal
  agent_git_record=""; agent_git_script=""
  if [ -z "$SELF_DIR" ] || [ -z "$SELF_DIR_ID" ] \
    || ! agent_git_record="$(freeze_repo_file "$SELF_DIR" \
      "agent-git.sh" "agent-git.sh" "$SELF_DIR_ID")" \
    || ! preflight_leaf_test_pause agent-git agent-git.sh \
    || ! agent_git_script="$(preflight_snapshot_read agent-git.sh "$agent_git_record")" \
    || [ -z "$agent_git_script" ] \
    || ! bash -s -- rev-parse --verify 'HEAD^{commit}' \
      >/dev/null 2>&1 <<<"$agent_git_script"; then
    warn "localized git context invalid/stale; relocalize/retest required"
    exit "$status"
  fi
  preflight_tmp_guard || preflight_tmp_fatal
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export GIT_DIR="$local_gitdir"
  export GIT_WORK_TREE="$repo_root"
else
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  warn "not inside a git worktree"
  exit "$status"
fi

repo_root="$(git rev-parse --show-toplevel)"
cd "$repo_root" 2>/dev/null || { warn "canonical repo root unavailable"; exit "$status"; }
repo_root="$(pwd -P)"
git_dir="$(git rev-parse --git-dir)"
head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
local_tracking_sha="$(git rev-parse --verify --quiet "$remote/$branch" 2>/dev/null || true)"
dirty_lines="$(git status --short | wc -l | tr -d ' ')"

note "repo=ok"
case "$git_dir" in "$repo_root"/*) note "git_dir=worktree-local";; *) note "git_dir=registered";; esac
note "head=${head_sha:-missing}"
note "local $remote/$branch=${local_tracking_sha:-missing}"
note "dirty_entries=$dirty_lines"

remote_url="$(git remote get-url "$remote" 2>/dev/null || true)"
origin_issue_url_frozen="$(git config --local --no-includes --get-all remote.origin.url 2>/dev/null || true)"
if [ -z "$remote_url" ]; then
  warn "remote $remote is missing"
else
  note "remote_url=present"
fi

remote_ref="refs/heads/$branch"
preflight_tmp_guard || preflight_tmp_fatal
remote_line="$(bounded git ls-remote --refs "$remote" "$remote_ref" 2>/dev/null || true)"
preflight_tmp_guard || preflight_tmp_fatal
# NB: без {n}-квантификаторов — mawk (дефолтный awk debian, т.е. канонический CI-контейнер)
# не поддерживает brace-интервалы, и /[0-9a-f]{40}/ там молча не матчится никогда
remote_sha="$(printf '%s\n' "$remote_line" | awk -v ref="$remote_ref" '
  $2==ref && $1 ~ /^[0-9a-f]+$/ && (length($1)==40 || length($1)==64) { oid=$1; n++ }
  END { if (n==1) print oid; else exit 1 }
' 2>/dev/null || true)"
if [ -z "$remote_sha" ]; then
  warn "cannot read $remote/$branch"
else
  note "remote $remote/$branch=$remote_sha"
  if [ "$remote_sha" = "$head_sha" ]; then
    note "publish_state=remote_matches_head"
  elif ! git cat-file -e "$remote_sha^{commit}" 2>/dev/null; then
    warn "publish_state=blocked_remote_commit_object_missing_need_fetch"
  elif git merge-base --is-ancestor "$remote_sha" "$head_sha" 2>/dev/null; then
    note "publish_state=head_can_fast_forward_remote"
  else
    warn "publish_state=blocked_remote_not_ancestor_of_head"
  fi
fi

# --- issue backend: env ISSUE_BACKEND → строка PROJECT.md → none (неизвестное → fail closed) ---
# PROJECT.md — данные, никогда не source-ится; symlink/нечитаемый файл → fail closed. Первая строка,
# начинающаяся с `ISSUE_BACKEND=`, обязана точно совпасть с `^ISSUE_BACKEND=(github|none)\s*$`.
project_issue_backend() { # stdout: github|none; rc!=0 → invalid declaration/authority
  perl -MFcntl=:DEFAULT,O_NOFOLLOW,S_ISREG -MErrno=ENOENT -e '
    use strict; use warnings; my $path=q{PROJECT.md}; my @named=lstat($path);
    if (!@named) { exit 1 unless $!{ENOENT}; print qq{none\n}; exit 0 }
    exit 1 if -l _ || !S_ISREG($named[2]);
    sysopen(my $fh,$path,O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($fh);
    exit 1 unless @opened && $opened[0]==$named[0] && $opened[1]==$named[1];
    my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
      last unless $n; $raw.=$buf; exit 1 if length($raw)>1048576 }
    close($fh) or exit 1;
    for my $line (split /\n/,$raw) {
      $line=~s/\r\z//; next unless $line=~/\AISSUE_BACKEND=/;
      if ($line=~/\AISSUE_BACKEND=(github|none)\s*\z/) { print qq{$1\n}; exit 0 }
      exit 1;
    }
    print qq{none\n};
  ' 2>/dev/null
}
ISSUE_CONTRACT_OK=1
if [ "${ISSUE_BACKEND+x}" = x ]; then
  case "$ISSUE_BACKEND" in
    github|none) :;;
    *) warn "issue_contract=invalid-backend"; ISSUE_CONTRACT_OK=0; ISSUE_BACKEND="";;
  esac
elif ! ISSUE_BACKEND="$(project_issue_backend)"; then
  warn "issue_contract=invalid-backend"; ISSUE_CONTRACT_OK=0; ISSUE_BACKEND=""
fi

# Секрет-дисциплина: stdout/stderr issue CLI остаётся в run-private tmp и не цитируется; preflight
# публикует только metadata-статус.  Contract failure is a hard boundary for probes too: an
# unauthenticated selector must not decide which external system we call.
if [ "$ISSUE_CONTRACT_OK" -ne 1 ]; then
  warn "issue_checks=blocked_by_contract"
elif [ "$ISSUE_BACKEND" = "none" ]; then
  note "issue_backend=none"
  note "issue_checks=skipped (работа в specs/, очередь — docs/backlog.md)"
elif [ "$ISSUE_BACKEND" = "github" ]; then
  note "issue_backend=github"
  repo_full=""; repo_authority_ok=1
  origin_issue_url="$origin_issue_url_frozen"
  case "$origin_issue_url" in *$'\n'*) origin_issue_url="";; esac
  case "$origin_issue_url" in
    https://github.com/*) repo_full="${origin_issue_url#https://github.com/}"; repo_full="${repo_full%.git}";;
    git@github.com:*) repo_full="${origin_issue_url#git@github.com:}"; repo_full="${repo_full%.git}";;
    ssh://git@github.com/*) repo_full="${origin_issue_url#ssh://git@github.com/}"; repo_full="${repo_full%.git}";;
  esac
  if [ -z "$repo_full" ] || ! printf '%s\n' "$repo_full" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    warn "github_repo=origin_unavailable"
    repo_authority_ok=0
  fi
  # GH_REPO (owner/repo или github.com/owner/repo) may only repeat the origin-derived identity.
  pinned_repo="${GH_REPO-}"; pinned_repo="${pinned_repo#github.com/}"
  if [ "$repo_authority_ok" -eq 1 ] && [ "${GH_REPO+x}" = x ] \
    && { ! printf '%s\n' "$pinned_repo" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' \
      || [ "$pinned_repo" != "$repo_full" ]; }; then
    warn "issue_contract=github-repo-mismatch"
    repo_authority_ok=0
  fi
  if [ "$repo_authority_ok" -eq 1 ]; then
    PROVIDER_METADATA_SECRET_RC=0
    preflight_provider_metadata_secret_free "$repo_full" "github.com/$repo_full" \
      "${GH_REPO:-}" || PROVIDER_METADATA_SECRET_RC=$?
    case "$PROVIDER_METADATA_SECRET_RC" in
      0) ;;
      1) warn "issue_contract=secret-in-provider-metadata"; repo_authority_ok=0 ;;
      *) warn "issue_contract=secret-policy-invalid"; repo_authority_ok=0 ;;
    esac
  fi
  if [ "$repo_authority_ok" -ne 1 ]; then
    warn "issue_checks=blocked_by_repo_authority"
  elif [ "$PROVIDER_ENV_OK" -ne 1 ]; then
    warn "issue_checks=blocked_by_contract"
  elif ! command -v gh >/dev/null 2>&1; then
    warn "gh_cli=missing"
  elif ! preflight_tmp_guard \
    || ! provider_bounded gh auth status --hostname github.com >/dev/null 2>&1 \
    || ! preflight_tmp_guard; then
    warn "gh_auth=failed"
  else
    note "gh_auth=ok"
    note "github_repo=resolved"
    if preflight_tmp_guard \
      && provider_bounded gh issue list --repo "github.com/$repo_full" --limit 1 --json number,title >/dev/null 2>&1 \
      && preflight_tmp_guard; then
      note "gh_issues_read=ok"
    else
      warn "gh_issues_read=failed"
    fi
    preflight_tmp_guard || preflight_tmp_fatal
    repo_permissions="$(provider_bounded gh api --hostname github.com "repos/$repo_full" --jq '.permissions' 2>/dev/null || true)"
    preflight_tmp_guard || preflight_tmp_fatal
    if [ -n "$repo_permissions" ]; then
      note "gh_repo_permissions=available"
      can_triage="$(provider_bounded gh api --hostname github.com "repos/$repo_full" --jq '(.permissions.admin or .permissions.maintain or .permissions.push or .permissions.triage)' 2>/dev/null || true)"
      preflight_tmp_guard || preflight_tmp_fatal
      if [ "$can_triage" = "true" ]; then
        note "gh_issues_write_likely=ok"
      else
        warn "gh_issues_write_likely=not_confirmed"
      fi
    else
      warn "gh_repo_permissions=unavailable"
    fi
  fi
else
  # Defensive unreachable branch: exact enum validation above is part of ISSUE_CONTRACT_OK.
  warn "issue_checks=blocked_by_backend"
fi

# Root hygiene: session artifacts do not live in the repo root. Evidence -> docs/audit-evidence/<date>/.
# Vendor PDFs are tolerated; the allowlist below is the only md/txt/json/png/html/csv set.
root_allow='README\.md|AGENTS\.md|CLAUDE\.md|PROJECT\.md|CONTRIBUTING\.md|TESTING\.md|CHANGELOG\.md'
root_artifacts="$(find "$repo_root" -maxdepth 1 -type f 2>/dev/null | sed "s|.*/||" | grep -E "\\.(md|txt|json|png|jpe?g|html|csv|docx|xlsx|zip|log|sql)$" | grep -Evx "($root_allow)" || true)"
if [ -n "$root_artifacts" ]; then
  root_artifact_count="$(printf '%s\n' "$root_artifacts" | awk 'NF{n++} END{print n+0}')"
  warn "root_hygiene=violations count=$root_artifact_count (move to docs/audit-evidence/<date>/)"
else
  note "root_hygiene=clean"
fi

exit "$status"
