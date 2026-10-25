#!/usr/bin/env bash
set +exv
export CDPATH=
# intake.sh — детерминированная связка «тикет ↔ SPEC_DIR» канала /intake.
#
# Usage:
#   bash scripts/intake.sh ticket <SPEC_DIR> "<summary>" [body]   # body: 4-й аргумент или stdin
#
# Backend задач (единое правило харнесса): переменная окружения ISSUE_BACKEND → иначе первая
# строка PROJECT.md, начинающаяся с `ISSUE_BACKEND=` (обязана точно совпадать с
# `^ISSUE_BACKEND=(github|none)\s*$`) → иначе `none`. Неизвестное значение → error (fail closed).
# Для `github` репозиторий ВСЕГДА выводится из канонического `origin` (github.com/<owner>/<repo>);
# переменная GH_REPO, если задана, может только точно повторять его.
#
# Контракт stdout — РОВНО одна строка-исход:
#   created:<KEY>                  — dedup/create, semantic verify-read и link-ticket прошли (exit 0)
#   deferred:<reason>[ KEY=<key>]  — backend/verify недоступен; спека продолжает жить без Ticket: (exit 0)
#   skipped:issue-backend-none     — ISSUE_BACKEND=none: тикет не создаётся, работа живёт в specs/
#                                    и очереди docs/backlog.md (exit 0, ни одного внешнего вызова)
#   error:<reason>                 — локальный контракт или сама транзакция невалидны (exit 1)
#
# Все данные backend-команд остаются в run-private tmp. В audit.md попадают только стабильные
# metadata-коды (backend/phase/outcome/key), без пользовательской фразы и без CLI-диагностики.
set -uo pipefail
# Perl is the trusted parser/supervisor runtime; ambient module injection must not run before our
# own validation logic.
unset PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC 2>/dev/null || true

early_error() {
  printf 'error:%s\n' "$1"
  exit 1
}

# Production has no ambient test-mode switch. The full test runner executes a private mechanical
# copy with this one literal changed to 1; no caller-controlled env or descriptor can widen the
# provider allowlist of the shipped consumer.
ISSUE_PROVIDER_TEST_ENABLED=0
ISSUE_PROVIDER_NET_TIMEOUT=15
{ exec 7<&-; } 2>/dev/null || true

INTAKE_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd -P)" \
  || early_error "secret-policy-invalid"
PRIVATE_TMP_HELPER="$INTAKE_SCRIPT_DIR/private-temp-dir.pl"
PROVIDER_ENV_HELPER="$INTAKE_SCRIPT_DIR/provider-env.pl"
INTAKE_SCRIPT_DIR_ID="$(POLICY_DIR="$INTAKE_SCRIPT_DIR" \
  perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR -e '
    sysopen(my $fh,$ENV{POLICY_DIR},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @s=stat($fh);
    exit 1 unless @s && S_ISDIR($s[2]); print $s[0],q{:},$s[1];
  ' 2>/dev/null)" || early_error "secret-policy-invalid"
SECRET_RE="$(POLICY_DIR="$INTAKE_SCRIPT_DIR" POLICY_DIR_ID="$INTAKE_SCRIPT_DIR_ID" \
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
  ' 2>/dev/null)" || early_error "secret-policy-invalid"
[ -n "$SECRET_RE" ] || early_error "secret-policy-invalid"

[ "$#" -ge 3 ] && [ "$#" -le 4 ] || early_error "usage"
CMD="$1"
[ "$CMD" = "ticket" ] || early_error "unknown-command"
SPEC_DIR="$2"
SUMMARY_RAW="$3"
[ -n "$SUMMARY_RAW" ] || early_error "invalid-summary"
BODY_RAW=""
INTAKE_SUMMARY_MAX_BYTES=512
INTAKE_BODY_MAX_BYTES=65536
if [ "$#" -eq 4 ]; then
  BODY_RAW="$4"
elif [ ! -t 0 ]; then
  BODY_RAW="$(MAX_BYTES="$INTAKE_BODY_MAX_BYTES" perl -e '
    use strict; use warnings; my $raw=q{};
    while (1) { my $n=sysread(STDIN,my $buf,65536); exit 2 unless defined $n; last unless $n;
      $raw.=$buf; exit 3 if length($raw)>$ENV{MAX_BYTES} }
    exit 4 if $raw =~ /\x00/;
    print $raw;
  ')" || early_error "body-too-large"
fi
[ -n "$BODY_RAW" ] || BODY_RAW="$SUMMARY_RAW"
printf '%s' "$SUMMARY_RAW" | MAX_BYTES="$INTAKE_SUMMARY_MAX_BYTES" perl -MEncode=decode,FB_CROAK -0777 -e '
  my $raw=<>//q{}; exit 1 if length($raw)>$ENV{MAX_BYTES}; my $text=decode("UTF-8",$raw,FB_CROAK);
  exit 1 if $text=~/[\x00-\x1f\x7f]/;
' || early_error "invalid-summary"
printf '%s' "$BODY_RAW" | MAX_BYTES="$INTAKE_BODY_MAX_BYTES" perl -MEncode=decode,FB_CROAK -0777 -e '
  my $raw=<>//q{}; exit 1 if length($raw)>$ENV{MAX_BYTES}; decode("UTF-8",$raw,FB_CROAK);
' || early_error "body-too-large"
payload_secret_free() { # scan the exact bytes that may cross the provider boundary
  printf '%s\0%s' "$1" "$2" | INTAKE_SECRET_RE="$SECRET_RE" perl -0777 -e '
  use strict; use warnings; my $raw=<>//q{}; exit 2 if length($raw)>66050;
  my $re=qr/$ENV{INTAKE_SECRET_RE}/;
  exit($raw=~/$re/ ? 1 : 0);
'
}
provider_metadata_secret_free() { # scan every effective non-credential provider argv value
  {
    local value
    for value in "$@"; do printf '%s\0' "$value"; done
  } | INTAKE_SECRET_RE="$SECRET_RE" perl -0777 -e '
    use strict; use warnings; my $raw=<>//q{}; exit 2 if length($raw)>4*1024*1024;
    my $re=qr/$ENV{INTAKE_SECRET_RE}/;
    exit($raw=~/$re/ ? 1 : 0);
  '
}
PAYLOAD_SECRET_RC=0
payload_secret_free "$SUMMARY_RAW" "$BODY_RAW" || PAYLOAD_SECRET_RC=$?
case "$PAYLOAD_SECRET_RC" in
  0) ;;
  1) early_error "secret-in-payload" ;;
  *) early_error "secret-policy-invalid" ;;
esac

# Test-only containment gates are still production control flow.  A requested pause without its
# inherited control descriptor is a local harness error, never a backend degradation after trace.
if [ "${HARNESS_ISSUE_TEST_LOCK_PAUSE:-0}" = "1" ] \
    || [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = "1" ]; then
  { : >&9; } 2>/dev/null || early_error "test-gate-unavailable"
fi

# ISSUE_BACKEND из окружения надо отличать от отсутствующего: заданное пустое/неизвестное значение
# не является разрешением переключить transport по умолчанию.
ISSUE_BACKEND_ENV_SET=0
ISSUE_BACKEND_ENV=""
if [ "${ISSUE_BACKEND+x}" = "x" ]; then
  ISSUE_BACKEND_ENV_SET=1
  ISSUE_BACKEND_ENV="$ISSUE_BACKEND"
fi
# Ambient Git authority must not select another worktree/config/object database.  Keep transport
# authentication (for example GIT_SSH_COMMAND), but remove every repository/config selector before
# the first git invocation. Dynamic config keys become inert when COUNT is unset; clear a bounded
# prefix too so descendants cannot accidentally re-enable inherited entries.
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
repo_root_raw="$(git rev-parse --show-toplevel 2>/dev/null)" || early_error "invalid-repository"
[ -n "$repo_root_raw" ] || early_error "invalid-repository"
repo_root="$(cd "$repo_root_raw" 2>/dev/null && pwd -P)" || early_error "invalid-repository"
[ "$(git -C "$repo_root" rev-parse --is-inside-work-tree 2>/dev/null)" = "true" ] \
  || early_error "invalid-repository"
repo_root_check="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null)" \
  || early_error "invalid-repository"
repo_root_check="$(cd "$repo_root_check" 2>/dev/null && pwd -P)" \
  || early_error "invalid-repository"
[ "$repo_root_check" = "$repo_root" ] || early_error "invalid-repository"
cd "$repo_root" 2>/dev/null || early_error "invalid-repository"

# Pin the physical common git directory once.  Every linked worktree of the repository therefore
# shares one intake transaction lane; per-worktree gitdirs cannot mint duplicate backend mutations.
# Later lock operations reopen the canonical pathname only after matching this device/inode.
git_dir_raw="$(git rev-parse --git-common-dir 2>/dev/null)" \
  || early_error "invalid-repository"
case "$git_dir_raw" in /*) :;; *) git_dir_raw="$repo_root/$git_dir_raw";; esac
INTAKE_GIT_DIR="$(cd "$git_dir_raw" 2>/dev/null && pwd -P)" \
  || early_error "invalid-repository"
INTAKE_GIT_DIR_ID="$(GITDIR="$INTAKE_GIT_DIR" perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR -e '
  use strict; use warnings; sysopen(my $fh,$ENV{GITDIR},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
  my @s=stat($fh); exit 1 unless @s && S_ISDIR($s[2]); print $s[0],q{:},$s[1];
' 2>/dev/null)" || early_error "invalid-repository"

# Канонический SPEC_DIR — ровно specs/NNN-slug. До первого trace/backend-вызова доказываем,
# что весь путь остаётся внутри git-toplevel, не проходит через symlink и state.md — single-link
# regular file. Это защищает и append-only trace, и последующий link-ticket.
SPEC_AUTHORITY="$(perl -e '
  use strict; use warnings; use Fcntl qw(O_RDONLY O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISREG);
  my ($root, $rel) = @ARGV;
  sub id { my (@s)=@_; return $s[0].q{:}.$s[1] }
  exit 1 unless defined($rel) && $rel =~ m{\Aspecs/[0-9]{3}-[a-z0-9][a-z0-9-]*\z};
  my @part = split m{/}, $rel;
  sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @root=stat($root_fh);
  exit 1 unless @root && S_ISDIR($root[2]); chdir($root_fh) or exit 1; my @ids=(id(@root)); my @dirs=($root_fh);
  for my $part (@part) {
    my @named=lstat($part); exit 1 unless @named && !-l _ && S_ISDIR($named[2]);
    sysopen(my $dir,$part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
    exit 1 unless @opened && id(@opened) eq id(@named); push @ids,id(@opened); push @dirs,$dir; chdir($dir) or exit 1;
  }
  sysopen(my $state,"state.md",O_RDONLY|O_NOFOLLOW) or exit 1; my @st=stat($state); my @named=lstat("state.md");
  exit 1 unless @st && @named && !-l _ && S_ISREG($st[2]) && $st[3]==1 && id(@st) eq id(@named);
  push @ids,id(@st); print join(q{|},@ids);
' -- "." "$SPEC_DIR" 2>/dev/null)" || early_error "invalid-spec-dir"
SPEC_ROOT_ID="${SPEC_AUTHORITY%%|*}"; SPEC_AUTHORITY="${SPEC_AUTHORITY#*|}"
SPEC_SPECS_ID="${SPEC_AUTHORITY%%|*}"; SPEC_AUTHORITY="${SPEC_AUTHORITY#*|}"
SPEC_DIR_ID="${SPEC_AUTHORITY%%|*}"; SPEC_STATE_ID="${SPEC_AUTHORITY#*|}"

# Backend задач: env → PROJECT.md → none. PROJECT.md — данные, никогда не source-ится; symlink или
# нечитаемый файл → fail closed. Первая строка, начинающаяся с `ISSUE_BACKEND=`, обязана точно
# совпасть с `^ISSUE_BACKEND=(github|none)\s*$` — опечатка не превращается молча в `none`.
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
if [ "$ISSUE_BACKEND_ENV_SET" -eq 1 ]; then
  case "$ISSUE_BACKEND_ENV" in github|none) ISSUE_BACKEND="$ISSUE_BACKEND_ENV" ;; *) early_error "invalid-issue-backend" ;; esac
else
  ISSUE_BACKEND="$(project_issue_backend)" || early_error "invalid-issue-backend"
fi
case "$ISSUE_BACKEND" in github|none) ;; *) early_error "invalid-issue-backend" ;; esac
if [ "$ISSUE_BACKEND" = none ]; then
  printf 'intake: ISSUE_BACKEND=none — тикет не создаётся; работа живёт в %s и очереди docs/backlog.md\n' "$SPEC_DIR" >&2
  printf 'skipped:issue-backend-none\n'
  exit 0
fi

tmp_base="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" \
  || early_error "tmp-unavailable"
[ -r "$PRIVATE_TMP_HELPER" ] || early_error "tmp-unavailable"
tmpdir="$(umask 077; mktemp -d "$tmp_base/intake.XXXXXX" 2>/dev/null)" \
  || early_error "tmp-unavailable"
chmod 0700 "$tmpdir" >/dev/null 2>&1 \
  || { rmdir "$tmpdir" >/dev/null 2>&1 || true; early_error "tmp-unavailable"; }
tmpdir="$(cd "$tmpdir" 2>/dev/null && pwd -P)" \
  || early_error "tmp-unavailable"
tmpdir_id="$(perl "$PRIVATE_TMP_HELPER" id "$tmpdir" 2>/dev/null)" \
  || { rmdir "$tmpdir" >/dev/null 2>&1 || true; early_error "tmp-unavailable"; }
intake_tmp_guard() {
  perl "$PRIVATE_TMP_HELPER" guard "$tmpdir" "$tmpdir_id" >/dev/null 2>&1
}
INTAKE_LOCK1_NAME=""; INTAKE_LOCK1_ROOT_ID=""; INTAKE_LOCK1_ID=""; INTAKE_LOCK1_OWNER_ID=""
INTAKE_LOCK1_NONCE=""; INTAKE_LOCK1_PID=""; INTAKE_LOCK1_STARTED=""; INTAKE_LOCK1_BIRTH=""
INTAKE_LOCK2_NAME=""; INTAKE_LOCK2_ROOT_ID=""; INTAKE_LOCK2_ID=""; INTAKE_LOCK2_OWNER_ID=""
INTAKE_LOCK2_NONCE=""; INTAKE_LOCK2_PID=""; INTAKE_LOCK2_STARTED=""; INTAKE_LOCK2_BIRTH=""
INTAKE_LOCK_TEST_PAUSED=0
release_intake_lock() {
  local name="$1" root_id="$2" lock_id="$3" owner_id="$4" nonce="$5" pid="$6" started="$7" birth="$8"
  [ -z "$name" ] && return 0
  [ -n "$lock_id" ] && [ -n "$owner_id" ] && [ -n "$nonce" ] || return 1
  GITDIR="$INTAKE_GIT_DIR" GITDIR_ID="$INTAKE_GIT_DIR_ID" LOCK_NAME="$name" \
      ROOT_ID="$root_id" LOCK_ID="$lock_id" OWNER_ID="$owner_id" \
      LOCK_NONCE="$nonce" LOCK_PID="$pid" LOCK_STARTED="$started" LOCK_BIRTH="$birth" \
      perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
        use strict; use warnings; sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
        sysopen(my $git,$ENV{GITDIR},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @g=stat($git);
        exit 1 unless @g && S_ISDIR($g[2]) && did(@g) eq $ENV{GITDIR_ID}; chdir($git) or exit 1;
        my $root=q{agent-harness-intake-locks}; my @rn=lstat($root);
        exit 1 unless @rn && !S_ISLNK($rn[2]) && S_ISDIR($rn[2]) && did(@rn) eq $ENV{ROOT_ID};
        sysopen(my $rf,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @ro=stat($rf);
        exit 1 unless @ro && did(@ro) eq $ENV{ROOT_ID}; chdir($rf) or exit 1;
        my $lock=$ENV{LOCK_NAME}; my @d=lstat($lock); exit 1 unless @d && !S_ISLNK($d[2])
          && S_ISDIR($d[2]) && did(@d) eq $ENV{LOCK_ID};
        sysopen(my $df,$lock,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($df);
        exit 1 unless @opened && did(@opened) eq $ENV{LOCK_ID}; chdir($df) or exit 1;
        sysopen(my $fh,q{owner},O_RDONLY|O_NOFOLLOW) or exit 1; my @o=stat($fh); my @n=lstat(q{owner});
        exit 1 unless @o && @n && S_ISREG($o[2]) && $o[3]==1
          && ($o[0].q{:}.$o[1]) eq $ENV{OWNER_ID} && $o[0]==$n[0] && $o[1]==$n[1];
        local $/; my $raw=<$fh>//q{}; close $fh or exit 1;
        my $want="pid=$ENV{LOCK_PID}\nstarted=$ENV{LOCK_STARTED}\nbirth=$ENV{LOCK_BIRTH}\nnonce=$ENV{LOCK_NONCE}\n";
        exit 1 unless $raw eq $want;
        unlink(q{owner}) or exit 1; chdir($rf) or exit 1; rmdir($lock) or exit 1;
      ' >/dev/null 2>&1
}
cleanup() {
  local cleanup_rc=0
  release_intake_lock "$INTAKE_LOCK2_NAME" "$INTAKE_LOCK2_ROOT_ID" "$INTAKE_LOCK2_ID" \
    "$INTAKE_LOCK2_OWNER_ID" "$INTAKE_LOCK2_NONCE" "$INTAKE_LOCK2_PID" \
    "$INTAKE_LOCK2_STARTED" "$INTAKE_LOCK2_BIRTH" || cleanup_rc=1
  release_intake_lock "$INTAKE_LOCK1_NAME" "$INTAKE_LOCK1_ROOT_ID" "$INTAKE_LOCK1_ID" \
    "$INTAKE_LOCK1_OWNER_ID" "$INTAKE_LOCK1_NONCE" "$INTAKE_LOCK1_PID" \
    "$INTAKE_LOCK1_STARTED" "$INTAKE_LOCK1_BIRTH" || cleanup_rc=1
  perl "$PRIVATE_TMP_HELPER" cleanup "$tmpdir" "$tmpdir_id" >/dev/null 2>&1 || cleanup_rc=1
  return "$cleanup_rc"
}
cleanup_on_exit() {
  local rc="$?"
  trap - EXIT
  if ! cleanup; then
    printf 'intake: private temp cleanup failed\n' >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap cleanup_on_exit EXIT

if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = "1" ]; then
  printf 'ready\n' >&9 || early_error "test-gate-unavailable"
  kill -STOP "$$" 2>/dev/null || early_error "test-gate-unavailable"
  intake_tmp_guard || early_error "tmp-unavailable"
fi

finish_private_cleanup() {
  trap - EXIT
  if cleanup; then return 0; fi
  printf 'intake: private temp cleanup failed\n' >&2
  printf 'error:private-cleanup-failed\n'
  exit 1
}

intake_snapshot_write() { # <safe leaf>; stdin bytes -> identity|sha256|length
  perl "$PRIVATE_TMP_HELPER" write "$tmpdir" "$tmpdir_id" "$1" 2>/dev/null
}
intake_snapshot_read() { # <safe leaf> <record>; emits bytes only after full identity/digest check
  perl "$PRIVATE_TMP_HELPER" read "$tmpdir" "$tmpdir_id" "$1" "$2" 2>/dev/null
}
bounded_capture() { # authority responses are JSON/URL text; never materialize mutable temp leaves
  MAX_BYTES="${1:-16777216}" perl -e '
    use strict; use warnings; my $raw=q{};
    while (1) { my $n=sysread(STDIN,my $buf,65536); exit 1 unless defined $n; last unless $n;
      $raw.=$buf; exit 1 if length($raw)>$ENV{MAX_BYTES} }
    exit 1 if $raw=~/\x00/; print $raw;
  '
}

# Pin the shared provider boundary exactly once.  Provider children execute these verified bytes
# from memory; neither a live companion swap nor a station HOME/XDG store becomes issue authority.
freeze_provider_env() {
  POLICY_DIR="$INTAKE_SCRIPT_DIR" POLICY_DIR_ID="$INTAKE_SCRIPT_DIR_ID" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISREG -e '
      use strict; use warnings; my ($dir,$want)=@ENV{qw(POLICY_DIR POLICY_DIR_ID)};
      sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
      sysopen(my $root,$dir,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @root=stat($root);
      exit 1 unless @root && S_ISDIR($root[2]) && ($root[0].q{:}.$root[1]) eq $want;
      chdir($root) or exit 1; my $leaf=q{provider-env.pl}; my @named=lstat($leaf);
      exit 1 unless @named && !-l _ && S_ISREG($named[2]) && $named[3]==1;
      sysopen(my $fh,$leaf,O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($fh);
      exit 1 unless @opened && ident(@opened) eq ident(@named);
      my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $raw.=$buf; exit 1 if length($raw)>1048576 }
      exit 1 if $raw eq q{} || $raw=~/\x00/; sysseek($fh,0,0)>=0 or exit 1; my $again=q{};
      while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $again.=$buf; exit 1 if length($again)>1048576 }
      my @after=stat($fh); close($fh) or exit 1; @named=lstat($leaf);
      exit 1 unless $again eq $raw && @after && @named && !-l _
        && ident(@after) eq ident(@opened) && ident(@named) eq ident(@opened);
      print $raw;
    ' 2>/dev/null
}
PROVIDER_ENV_RECORD="$(freeze_provider_env | intake_snapshot_write provider-env.pl)" \
  || early_error "provider-env-invalid"
PROVIDER_ENV_SCRIPT="$(intake_snapshot_read provider-env.pl "$PROVIDER_ENV_RECORD")" \
  || early_error "provider-env-invalid"
[ -n "$PROVIDER_ENV_SCRIPT" ] || early_error "provider-env-invalid"
printf '%s' "$PROVIDER_ENV_SCRIPT" | perl -c - >/dev/null 2>&1 \
  || early_error "provider-env-invalid"
intake_tmp_guard || early_error "tmp-unavailable"

# Freeze local repository config from the pinned common git-dir.  GitHub origin authority is parsed
# from this private copy once and never rediscovered through a potentially replaced `.git` path
# after the transaction lock has been acquired.
freeze_git_config() {
  GITDIR="$INTAKE_GIT_DIR" GITDIR_ID="$INTAKE_GIT_DIR_ID" \
    perl -MErrno=ENOENT -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISREG -e '
      use strict; use warnings; my ($root,$want)=@ENV{qw(GITDIR GITDIR_ID)};
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
      sysopen(my $dir,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @d=stat($dir);
      exit 1 unless @d && S_ISDIR($d[2]) && did(@d) eq $want; chdir($dir) or exit 1;
      my $common=$dir; my @commondir=lstat(q{commondir});
      if (@commondir) {
        exit 1 unless !-l _ && S_ISREG($commondir[2]) && $commondir[3]==1;
        sysopen(my $cf,q{commondir},O_RDONLY|O_NOFOLLOW) or exit 1; my @co=stat($cf);
        exit 1 unless @co && ident(@co) eq ident(@commondir); local $/; my $rel=<$cf>//q{};
        close $cf or exit 1; my @ca=lstat(q{commondir}); exit 1 unless @ca && ident(@ca) eq ident(@co);
        $rel=~s/\n\z//; exit 1 if $rel eq q{} || $rel=~/[\x00-\x1f\x7f]/;
        if ($rel=~m{\A/}) {
          sysopen(my $absolute,$rel,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
          my @a=stat($absolute); exit 1 unless @a && S_ISDIR($a[2]); $common=$absolute;
        } else {
          my @hold=($dir); chdir($dir) or exit 1;
          for my $part (split m{/},$rel,-1) {
            next if $part eq q{.}; exit 1 if $part eq q{};
            my @named=lstat($part); exit 1 unless @named && !-l _ && S_ISDIR($named[2]);
            sysopen(my $next,$part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($next);
            exit 1 unless @opened && ident(@opened) eq ident(@named); push @hold,$next;
            chdir($next) or exit 1; $common=$next;
          }
        }
      } elsif (!$!{ENOENT}) { exit 1 }
      chdir($common) or exit 1;
      my @named=lstat(q{config}); exit 1 unless @named && !-l _ && S_ISREG($named[2]) && $named[3]==1;
      sysopen(my $fh,q{config},O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($fh);
      exit 1 unless @opened && ident(@opened) eq ident(@named);
      my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
      sysseek($fh,0,0)>=0 or exit 1; my $again=q{};
      while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $again.=$buf; exit 1 if length($again)>16777216 }
      exit 1 if $again ne $raw; my @after=stat($fh); close $fh or exit 1; @named=lstat(q{config});
      exit 1 unless @after && @named && !-l _ && ident(@after) eq ident(@opened)
        && ident(@named) eq ident(@opened);
      print $raw;
    ' 2>/dev/null
}
intake_tmp_guard || early_error "tmp-unavailable"
FROZEN_GIT_CONFIG_RAW="$(freeze_git_config | bounded_capture 1048576)" \
  || early_error "invalid-repository"
FROZEN_ORIGIN_URL="$(printf '%s' "$FROZEN_GIT_CONFIG_RAW" \
  | git config --file - --no-includes --get-all remote.origin.url 2>/dev/null || true)"
intake_tmp_guard || early_error "tmp-unavailable"
spec_guard() {
  ROOT="." REL="$SPEC_DIR" ROOT_ID="$SPEC_ROOT_ID" SPECS_ID="$SPEC_SPECS_ID" \
    DIR_ID="$SPEC_DIR_ID" STATE_ID="$SPEC_STATE_ID" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISREG -e '
      use strict; use warnings;
      sub id { my (@s)=@_; return $s[0].q{:}.$s[1] }
      my ($root,$rel)=@ENV{qw(ROOT REL)}; my @want=@ENV{qw(ROOT_ID SPECS_ID DIR_ID)};
      my @part=split m{/},$rel; sysopen(my $dir,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
      my @opened=stat($dir); exit 1 unless @opened && S_ISDIR($opened[2]) && id(@opened) eq $want[0]; chdir($dir) or exit 1;
      my @dirs=($dir); my $index=1;
      for my $name (@part) { my @named=lstat($name); exit 1 unless @named && !-l _ && S_ISDIR($named[2]);
        sysopen(my $next,$name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; @opened=stat($next);
        exit 1 unless @opened && id(@opened) eq id(@named) && id(@opened) eq $want[$index++]; push @dirs,$next; chdir($next) or exit 1 }
      sysopen(my $state,"state.md",O_RDONLY|O_NOFOLLOW) or exit 1; my @state=stat($state); my @named=lstat("state.md");
      exit 1 unless @state && @named && S_ISREG($state[2]) && $state[3]==1 && !-l _
        && id(@state) eq id(@named) && id(@state) eq $ENV{STATE_ID};
      for my $name (qw(audit.md spec.md)) { my @s=lstat($name); next unless @s; exit 1 if -l _ || !S_ISREG($s[2]) || $s[3]!=1 }
    ' >/dev/null 2>&1
}

spec_ticket_read() { # [allow-replaced-state=0] [with-id=0]
  ROOT="." REL="$SPEC_DIR" ROOT_ID="$SPEC_ROOT_ID" SPECS_ID="$SPEC_SPECS_ID" \
    DIR_ID="$SPEC_DIR_ID" STATE_ID="$SPEC_STATE_ID" ALLOW_REPLACED="${1:-0}" WITH_ID="${2:-0}" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISREG -e '
      use strict; use warnings;
      sub id { my (@s)=@_; return $s[0].q{:}.$s[1] }
      sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
      my ($root,$rel)=@ENV{qw(ROOT REL)}; my @want=@ENV{qw(ROOT_ID SPECS_ID DIR_ID)};
      my @part=split m{/},$rel; sysopen(my $dir,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
      my @opened=stat($dir); exit 1 unless @opened && S_ISDIR($opened[2]) && id(@opened) eq $want[0];
      chdir($dir) or exit 1; my @dirs=($dir); my $index=1;
      for my $name (@part) {
        my @named=lstat($name); exit 1 unless @named && !-l _ && S_ISDIR($named[2]);
        sysopen(my $next,$name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; @opened=stat($next);
        exit 1 unless @opened && id(@opened) eq id(@named) && id(@opened) eq $want[$index++];
        push @dirs,$next; chdir($next) or exit 1;
      }
      my @named=lstat(q{state.md}); exit 1 unless @named && !-l _ && S_ISREG($named[2]) && $named[3]==1;
      sysopen(my $fh,q{state.md},O_RDONLY|O_NOFOLLOW) or exit 1; @opened=stat($fh);
      exit 1 unless @opened && ident(@opened) eq ident(@named);
      exit 1 unless $ENV{ALLOW_REPLACED} eq q{0} || $ENV{ALLOW_REPLACED} eq q{1};
      exit 1 if $ENV{ALLOW_REPLACED} eq q{0} && id(@opened) ne $ENV{STATE_ID};
      my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
      exit 1 if $raw=~/\x00/; sysseek($fh,0,0)>=0 or exit 1; my $again=q{};
      while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n;
        last unless $n; $again.=$buf; exit 1 if length($again)>16777216 }
      my @after=stat($fh); close $fh or exit 1; @named=lstat(q{state.md});
      exit 1 unless $again eq $raw && @after && @named && !-l _
        && ident(@after) eq ident(@opened) && ident(@named) eq ident(@opened);
      my @ticket=($raw=~/^- Ticket: ([^\r\n]+)$/mg); exit 1 unless @ticket==1;
      exit 1 if $ticket[0]=~/[\x00-\x1f\x7f|]/;
      exit 1 unless $ENV{WITH_ID} eq q{0} || $ENV{WITH_ID} eq q{1};
      print id(@opened),q{|} if $ENV{WITH_ID} eq q{1}; print $ticket[0];
    ' 2>/dev/null
}

# Каждый network process получает отдельную owned session. Shared supervisor enumerates the exact
# SID, so a descendant cannot escape cleanup merely with setpgid(2); only an explicit new session
# crosses the documented trusted boundary. Output is replayed only from digest-bound private leaves.
net() {
  local net_rc=0 meta out_leaf out_record err_leaf err_record extra pipe_rc
  intake_tmp_guard || return 125
  meta="$(perl "$PRIVATE_TMP_HELPER" run-bounded "$tmpdir" "$tmpdir_id" \
    "$ISSUE_PROVIDER_NET_TIMEOUT" - - -- "$@")" || return 125
  IFS=$'\t' read -r net_rc out_leaf out_record err_leaf err_record extra <<EOF
$meta
EOF
  [ -z "${extra:-}" ] && case "$net_rc" in ''|*[!0-9]*) false;; *) [ "$net_rc" -le 255 ];; esac \
    && printf '%s\n' "$out_record" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    && printf '%s\n' "$err_record" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    || return 125
  perl "$PRIVATE_TMP_HELPER" read "$tmpdir" "$tmpdir_id" "$out_leaf" "$out_record" \
    | perl -e '
      use strict; use warnings; my $total=0;
      while (1) { my $n=sysread(STDIN,my $buf,65536); exit 125 unless defined $n; last unless $n;
        $total+=$n; exit 125 if $total>16777216 || index($buf,"\0")>=0;
        my $off=0; while ($off<$n) { my $w=syswrite(STDOUT,$buf,$n-$off,$off);
          exit 125 unless defined($w) && $w>0; $off+=$w }
      }
    '
  pipe_rc=$?
  [ "$pipe_rc" -eq 0 ] || return 125
  intake_tmp_guard || return 125
  return "$net_rc"
}

github_net() {
  [ -n "$PROVIDER_ENV_SCRIPT" ] || return 125
  net perl -e "$PROVIDER_ENV_SCRIPT" github "$tmpdir" "$tmpdir_id" \
    "$ISSUE_PROVIDER_TEST_ENABLED" "$SECRET_RE" -- "$@"
}

INTAKE_AUTHOR_VALUE="${INTAKE_AUTHOR:-Owner}"

safe_author_token() {
  perl -MEncode=decode,FB_CROAK -e '
    my $raw = $ARGV[0];
    my $value = decode("UTF-8", $raw, FB_CROAK);
    exit(($value =~ /\A[\p{L}\p{N}][\p{L}\p{N}_.-]{0,63}\z/) ? 0 : 1);
  ' -- "$1" >/dev/null 2>&1
}
safe_author_token "$INTAKE_AUTHOR_VALUE" || early_error "invalid-intake-author"

SUMMARY="[$INTAKE_AUTHOR_VALUE] $SUMMARY_RAW"
BODY="[$INTAKE_AUTHOR_VALUE] $BODY_RAW

Дата: $(date +%F)
SPEC_DIR: $SPEC_DIR"
printf '%s' "$SUMMARY" | MAX_BYTES="$INTAKE_SUMMARY_MAX_BYTES" perl -0777 -e '
  my $raw=<>//q{}; exit(length($raw)<=$ENV{MAX_BYTES} ? 0 : 1);
' || early_error "invalid-summary"
printf '%s' "$BODY" | MAX_BYTES="$INTAKE_BODY_MAX_BYTES" perl -0777 -e '
  my $raw=<>//q{}; exit(length($raw)<=$ENV{MAX_BYTES} ? 0 : 1);
' || early_error "body-too-large"
PAYLOAD_SECRET_RC=0
payload_secret_free "$SUMMARY" "$BODY" || PAYLOAD_SECRET_RC=$?
case "$PAYLOAD_SECRET_RC" in
  0) ;;
  1) early_error "secret-in-payload" ;;
  *) early_error "secret-policy-invalid" ;;
esac
umask 077
intake_tmp_guard || early_error "tmp-unavailable"
PIPELINE_STATE_RECORD=""
PIPELINE_PRIVATE_TMP_RECORD=""
PIPELINE_READER_RECORD=""
PIPELINE_READER_DIR_ID=""
PIPELINE_STATE_PATH=""
SPEC_TICKET_AT_LOCK=""

pipeline_reader_snapshot_read() {
  perl "$PRIVATE_TMP_HELPER" read "$tmpdir/lib" "$PIPELINE_READER_DIR_ID" \
    pipeline-state-reader-v4.pl "$PIPELINE_READER_RECORD" 2>/dev/null
}

pipeline_state_exec() {
  local rc=0
  [ -n "$PIPELINE_STATE_RECORD" ] && [ -n "$PIPELINE_PRIVATE_TMP_RECORD" ] \
    && [ -n "$PIPELINE_READER_RECORD" ] && [ -n "$PIPELINE_READER_DIR_ID" ] \
    && [ -n "$PIPELINE_STATE_PATH" ] || return 125
  # pipeline-state resolves its private-temp companion from SCRIPT_DIR. Seal and revalidate the
  # exact companion set below one private 0700 root; /dev/fd execution would orphan that authority.
  intake_tmp_guard || return 125
  intake_snapshot_read pipeline-state.sh "$PIPELINE_STATE_RECORD" >/dev/null || return 125
  intake_snapshot_read private-temp-dir.pl "$PIPELINE_PRIVATE_TMP_RECORD" >/dev/null || return 125
  pipeline_reader_snapshot_read >/dev/null || return 125
  bash "$PIPELINE_STATE_PATH" "$@" || rc=$?
  intake_snapshot_read pipeline-state.sh "$PIPELINE_STATE_RECORD" >/dev/null || return 125
  intake_snapshot_read private-temp-dir.pl "$PIPELINE_PRIVATE_TMP_RECORD" >/dev/null || return 125
  pipeline_reader_snapshot_read >/dev/null || return 125
  return "$rc"
}

trace() {
  spec_guard || return 1
  pipeline_state_exec event "$SPEC_DIR" "$1" "${2:-}" >/dev/null 2>&1 || true
}

trace_required() {
  spec_guard || return 1
  pipeline_state_exec event "$SPEC_DIR" "$1" "${2:-}" >/dev/null 2>&1
}

state_ticket_valid() { # exact backend key grammar plus the canonical secret policy
  local ticket="$1" secret_rc=0
  payload_secret_free "$ticket" "" >/dev/null 2>&1 || secret_rc=$?
  [ "$secret_rc" -eq 0 ] || return 1
  [ "$ticket" = "—" ] && return 0
  case "$ISSUE_BACKEND" in
    github) printf '%s' "$ticket" | LC_ALL=C grep -Eq '^#[1-9][0-9]*$' ;;
    *) return 1 ;;
  esac
}

acquire_intake_lock_one() { # exact hashed lane, assigned to slot 1 or 2
  local lock_name="$1.lock" slot="$2" parsed rc test_pause=0
  printf '%s' "$1" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
    || finish_error "intake-lock-unavailable"
  case "$slot" in 1|2) ;; *) finish_error "intake-lock-unavailable" ;; esac
  # The containment gate models a fully locked transaction.  With two ordered lanes it must
  # pause only after slot 2 is acquired; pausing between lanes would test a partial transaction
  # and can strand slot 1 when a gitdir ABA fixture intentionally replaces the visible path.
  if [ "${HARNESS_ISSUE_TEST_LOCK_PAUSE:-0}" = 1 ] && [ "$slot" -eq 2 ] \
      && [ "$INTAKE_LOCK_TEST_PAUSED" -eq 0 ]; then
    test_pause=1
  fi
  rc=0
  parsed="$(GITDIR="$INTAKE_GIT_DIR" GITDIR_ID="$INTAKE_GIT_DIR_ID" LOCK_NAME="$lock_name" OWNER_PID="$$" \
    HARNESS_ISSUE_TEST_LOCK_PAUSE="$test_pause" \
    perl -MDigest::SHA=sha256_hex -MErrno=EEXIST,ENOENT,ESRCH \
    -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
      use strict; use warnings;
      my ($gitdir,$gitdir_id,$path,$pid)=@ENV{qw(GITDIR GITDIR_ID LOCK_NAME OWNER_PID)};
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      # Kernel birth identity v2: Linux binds boot UUID + /proc stat field 22; Darwin binds the
      # microsecond proc_bsdinfo start timeval.  The serialized owner field remains one SHA-256.
      sub process_birth {
        my ($who)=@_; return q{} unless $who=~/\A[1-9][0-9]*\z/;
        my $identity;
        if ($^O eq q{linux}) {
          open(my $boot_fh,q{<},q{/proc/sys/kernel/random/boot_id}) or return q{};
          my $boot=<$boot_fh>//q{}; close($boot_fh) or return q{}; chomp($boot);
          return q{} unless $boot=~/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/;
          open(my $stat_fh,q{<},qq{/proc/$who/stat}) or return q{};
          local $/; my $stat=<$stat_fh>//q{}; close($stat_fh) or return q{};
          return q{} unless $stat=~/\A\Q$who\E \((.*)\) ([A-Za-z]) (.*)\n?\z/s;
          my @field=split /\s+/, $3;
          return q{} unless @field>=19 && $field[18]=~/\A[0-9]+\z/;
          $identity=join(q{|},q{linux-proc-stat-v1},$boot,$who,$field[18]);
        } elsif ($^O eq q{darwin}) {
          # proc_pidinfo(PROC_PIDTBSDINFO) maps to proc_info syscall 336, call 2, flavor 3.
          my $buf=chr(0) x 136;
          my $size=syscall(336,2,0+$who,3,0,$buf,length($buf));
          return q{} unless defined($size) && $size==136;
          my $embedded=unpack(q{V},substr($buf,12,4));
          my ($sec,$usec)=unpack(q{Q<Q<},substr($buf,120,16));
          return q{} unless $embedded==$who && $sec>0 && $usec<1_000_000;
          $identity=join(q{|},q{darwin-proc-bsdinfo-v1},$who,$sec,$usec);
        } else {
          return q{};
        }
        return sha256_hex($identity);
      }
      sub legacy_birth {
        my ($who)=@_; return q{} unless $who=~/\A[1-9][0-9]*\z/;
        local $ENV{LC_ALL}=q{C}; local $ENV{LANG}=q{C}; local $ENV{TZ}=q{UTC};
        open(my $ps,q{-|},q{/bin/ps},q{-o},q{lstart=},q{-p},$who) or return q{};
        local $/; my $raw=<$ps>//q{}; close($ps) or return q{};
        $raw=~s/^\s+|\s+$//g; $raw=~s/\s+/ /g;
        return length($raw) ? sha256_hex($raw) : q{};
      }
      sysopen(my $git,$gitdir,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @g=stat($git);
      exit 1 unless @g && S_ISDIR($g[2]) && did(@g) eq $gitdir_id; chdir($git) or exit 1;
      my $root=q{agent-harness-intake-locks};
      if (!mkdir($root,0700)) { exit 1 unless $!{EEXIST} }
      my @base=lstat($root); exit 1 unless @base && !S_ISLNK($base[2]) && S_ISDIR($base[2])
        && $base[4]==$< && ($base[2]&0777)==0700;
      sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @root_opened=stat($root_fh);
      exit 1 unless @root_opened && did(@root_opened) eq did(@base); chdir($root_fh) or exit 1;
      sub quarantine {
        my ($expected)=@_; my $q=$path.q{.stale.}.$pid.q{.}.int(rand(1000000000));
        chdir($root_fh) or exit 1; rename($path,$q) or return 0; my @m=lstat($q);
        exit 1 unless @m && !S_ISLNK($m[2]) && S_ISDIR($m[2]) && did(@m) eq $expected;
        sysopen(my $q_fh,$q,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($q_fh);
        exit 1 unless @opened && did(@opened) eq $expected; chdir($q_fh) or exit 1;
        my @o=lstat(q{owner});
        if (@o) {
          exit 1 if S_ISLNK($o[2]) || !S_ISREG($o[2]) || $o[3]!=1;
          sysopen(my $owner_fh,q{owner},O_RDONLY|O_NOFOLLOW) or exit 1; my @oo=stat($owner_fh);
          exit 1 unless @oo && did(@oo) eq did(@o); close $owner_fh or exit 1;
          unlink(q{owner}) or exit 1;
        } elsif (!$!{ENOENT}) { exit 1 }
        chdir($root_fh) or exit 1; my @still=lstat($q);
        exit 1 unless @still && !S_ISLNK($still[2]) && did(@still) eq $expected;
        rmdir($q) or exit 1; return 1;
      }
      my $made=0;
      for (1..5) {
        if (mkdir($path,0700)) { $made=1; last }
        exit 1 unless $!{EEXIST}; my @old=lstat($path);
        exit 1 unless @old && !S_ISLNK($old[2]) && S_ISDIR($old[2]) && $old[4]==$< && ($old[2]&0777)==0700;
        sysopen(my $old_fh,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @old_opened=stat($old_fh);
        exit 1 unless @old_opened && did(@old_opened) eq did(@old); chdir($old_fh) or exit 1;
        my ($active,$stale)=(0,0);
        if (sysopen(my $fh,q{owner},O_RDONLY|O_NOFOLLOW)) {
          my @o=stat($fh); my @n=lstat(q{owner}); local $/; my $raw=<$fh>//q{}; close $fh or exit 1;
          exit 1 unless @o && @n && S_ISREG($o[2]) && $o[3]==1 && ($o[2]&0777)==0600
            && $o[0]==$n[0] && $o[1]==$n[1];
          if ($raw=~/\Apid=([1-9][0-9]*)\nstarted=([1-9][0-9]*)\nbirth=([0-9a-f]{64}|unavailable)\nnonce=[0-9a-f]{64}\n\z/) {
            my ($owner_pid,$started,$birth)=($1,$2,$3);
            if (kill(0,$owner_pid)) {
              my $current=process_birth($owner_pid); my $legacy=legacy_birth($owner_pid);
              if ($birth eq q{unavailable}) { $active=1 }
              elsif ((length($current) && $current eq $birth)
                  || (length($legacy) && $legacy eq $birth)) { $active=1 }
              elsif (length($current) && length($legacy)) { $stale=1 }
              else { $active=1 } # live PID with no comparable kernel view is never reclaimed
            }
            elsif ($!{ESRCH}) { $stale=1 }
            else { $active=1 }
          } else { $active=1 if time-$old[9] < 30; $stale=1 unless $active }
        } elsif ($!{ENOENT}) {
          # mkdir→owner has a tiny legitimate window. Only an old ownerless directory is reclaimable.
          $active=1 if time-$old[9] < 30; $stale=1 unless $active;
        } else { exit 1 }
        chdir($root_fh) or exit 1; my @named_after=lstat($path);
        exit 1 unless @named_after && !S_ISLNK($named_after[2]) && did(@named_after) eq did(@old);
        exit 75 if $active; exit 1 unless $stale && quarantine(did(@old));
      }
      exit 1 unless $made;
      my @lock=lstat($path); exit 1 unless @lock && !S_ISLNK($lock[2]) && S_ISDIR($lock[2])
        && $lock[4]==$< && ($lock[2]&0777)==0700;
      sysopen(my $lock_fh,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @lock_opened=stat($lock_fh);
      exit 1 unless @lock_opened && did(@lock_opened) eq did(@lock); chdir($lock_fh) or exit 1;
      sysopen(my $ur,"/dev/urandom",O_RDONLY) or exit 1; my $random=q{};
      sysread($ur,$random,32)==32 or exit 1; close $ur or exit 1;
      my $started=time; my $birth=process_birth($pid); $birth=q{unavailable} unless length($birth);
      my $nonce=sha256_hex($random.q{:}.$pid.q{:}.$started.q{:}.rand());
      sysopen(my $out,q{owner},O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or exit 1;
      my $raw="pid=$pid\nstarted=$started\nbirth=$birth\nnonce=$nonce\n"; my $off=0;
      while ($off<length($raw)) { my $n=syswrite($out,$raw,length($raw)-$off,$off); exit 1 unless defined($n)&&$n; $off+=$n }
      my @owner_opened=stat($out); close $out or exit 1; my @o=lstat(q{owner});
      exit 1 unless @owner_opened && @o && !S_ISLNK($o[2]) && S_ISREG($o[2]) && $o[3]==1
        && ($o[2]&0777)==0600 && did(@owner_opened) eq did(@o);
      chdir($root_fh) or exit 1; my @named_after=lstat($path);
      exit 1 unless @named_after && !S_ISLNK($named_after[2]) && did(@named_after) eq did(@lock);
      if (($ENV{HARNESS_ISSUE_TEST_LOCK_PAUSE}//q{}) eq q{1}) {
        open(my $gate,q{>&=9}) or exit 1; my $msg=q{pid=}.$$ . "\n";
        syswrite($gate,$msg,length($msg))==length($msg) or exit 1; close $gate or exit 1;
        kill(q{STOP},$$)==1 or exit 1;
      }
      print did(@root_opened).q{|}.did(@lock).q{|}.did(@o).q{|}.$nonce.q{|}.$pid.q{|}.$started.q{|}.$birth;
    ' 2>/dev/null)" || rc=$?
  case "$rc" in
    0)
      if [ "$slot" -eq 1 ]; then
        INTAKE_LOCK1_NAME="$lock_name"; INTAKE_LOCK1_ROOT_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK1_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK1_OWNER_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK1_NONCE="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK1_PID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK1_STARTED="${parsed%%|*}"; INTAKE_LOCK1_BIRTH="${parsed#*|}"
      else
        INTAKE_LOCK2_NAME="$lock_name"; INTAKE_LOCK2_ROOT_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK2_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK2_OWNER_ID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK2_NONCE="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK2_PID="${parsed%%|*}"; parsed="${parsed#*|}"
        INTAKE_LOCK2_STARTED="${parsed%%|*}"; INTAKE_LOCK2_BIRTH="${parsed#*|}"
      fi
      [ "$test_pause" -eq 0 ] || INTAKE_LOCK_TEST_PAUSED=1;;
    75)
      finish_private_cleanup
      printf 'intake: Тикет отложен: intake-busy — занята SPEC или dedup-транзакция этого summary\n' >&2
      printf 'deferred:intake-busy\n'; exit 0;;
    *) finish_error "intake-lock-unavailable";;
  esac
}

acquire_intake_locks() { # every caller takes SPEC first, then backend+summary
  local spec_lock summary_lock
  spec_lock="$(printf '%s\0%s' 'intake-spec-v3' "$SPEC_DIR" \
    | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" \
    || finish_error "intake-lock-unavailable"
  summary_lock="$(printf '%s\0%s\0%s' 'intake-summary-v3' "$ISSUE_BACKEND" "$SUMMARY" \
    | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" \
    || finish_error "intake-lock-unavailable"
  [ "$spec_lock" != "$summary_lock" ] || finish_error "intake-lock-unavailable"
  acquire_intake_lock_one "$spec_lock" 1
  acquire_intake_lock_one "$summary_lock" 2
}

finish_created() { # key, backend, source=create|dedup
  trace "ticket:create:outcome" "outcome=created backend=$2 source=$3 key=$1"
  finish_private_cleanup
  printf 'created:%s\n' "$1"
  exit 0
}

finish_deferred() { # stable reason, optional key
  local reason="$1" key="${2:-}"
  trace "ticket:create:outcome" "outcome=deferred backend=$ISSUE_BACKEND reason=$reason${key:+ key=$key}"
  finish_private_cleanup
  printf 'intake: Тикет отложен: %s — спека стартует без Ticket:, догон: bash scripts/pipeline-state.sh link-ticket %s %s\n' \
    "$reason" "$SPEC_DIR" "${key:-<KEY>}" >&2
  printf 'deferred:%s%s\n' "$reason" "${key:+ KEY=$key}"
  exit 0
}

finish_error() {
  trace "ticket:create:outcome" "outcome=error backend=$ISSUE_BACKEND reason=$1"
  finish_private_cleanup
  printf 'error:%s\n' "$1"
  exit 1
}

github_view_is_exact() { # stdin response, decimal number; expected bytes are bounded shell state
  EXPECTED_NUMBER="$1" EXPECTED_SUMMARY="$SUMMARY" EXPECTED_BODY="$BODY" \
    perl -MJSON::PP -MEncode=decode,FB_CROAK -0777 -e '
    my $raw = <>;
    my $obj = decode_json($raw);
    exit 1 unless ref($obj) eq "HASH" && scalar(keys %$obj) == 4;
    my $want = decode("UTF-8", $ENV{EXPECTED_SUMMARY}, FB_CROAK);
    my $want_body = decode("UTF-8", $ENV{EXPECTED_BODY}, FB_CROAK);
    exit 1 unless defined($obj->{number}) && "$obj->{number}" eq $ENV{EXPECTED_NUMBER};
    exit 1 unless defined($obj->{state}) && !ref($obj->{state}) && $obj->{state} eq "OPEN";
    exit 1 unless defined($obj->{title}) && !ref($obj->{title}) && $obj->{title} eq $want;
    exit 1 unless defined($obj->{body}) && !ref($obj->{body}) && $obj->{body} eq $want_body;
  ' >/dev/null 2>&1
}

verify_and_link() { # key, backend, source, command argv
  local key="$1" backend="$2" source="$3" response current_ticket linked_ticket state_snapshot link_rc=0
  shift 3
  [ "$backend" = github ] || finish_error "verify-backend-invalid"
  if ! response="$(github_net "$@" 2>/dev/null | bounded_capture 16777216)"; then
    finish_deferred "verify-failed" "$key"
  fi
  printf '%s' "$response" | github_view_is_exact "${key#\#}" \
    || finish_deferred "verify-semantic-failed" "$key"
  spec_guard || finish_deferred "spec-authority-changed" "$key"
  current_ticket="$(spec_ticket_read)" || finish_deferred "spec-authority-changed" "$key"
  [ "$current_ticket" = "$SPEC_TICKET_AT_LOCK" ] \
    || finish_deferred "spec-link-conflict" "$key"
  case "$SPEC_TICKET_AT_LOCK" in
    "—"|"$key") ;;
    *) finish_deferred "spec-already-linked" "$SPEC_TICKET_AT_LOCK" ;;
  esac
  pipeline_state_exec link-ticket-cas "$SPEC_DIR" "$SPEC_TICKET_AT_LOCK" "$key" \
    "$SPEC_ROOT_ID" "$SPEC_SPECS_ID" "$SPEC_DIR_ID" "$SPEC_STATE_ID" >/dev/null 2>&1 \
    || link_rc=$?
  if [ "$link_rc" -ne 0 ]; then
    pipeline_state_exec validate-state "$SPEC_DIR" >/dev/null 2>&1 \
      || finish_deferred "link-ticket-failed" "$key"
  fi
  state_snapshot="$(spec_ticket_read 1 1)" \
    || finish_deferred "$([ "$link_rc" -eq 0 ] && printf link-ticket-verify-failed || printf link-ticket-failed)" "$key"
  case "$state_snapshot" in [0-9]*:[0-9]*'|'*) ;; *) finish_deferred "link-ticket-verify-failed" "$key" ;; esac
  SPEC_STATE_ID="${state_snapshot%%|*}"; linked_ticket="${state_snapshot#*|}"
  spec_guard || finish_deferred "link-ticket-verify-failed" "$key"
  [ "$linked_ticket" = "$key" ] \
    || finish_deferred "$([ "$link_rc" -eq 0 ] && printf link-ticket-verify-failed || printf link-ticket-failed)" "$key"
  finish_created "$key" "$backend" "$source"
}

github_repo_is_safe() {
  printf '%s\n' "$1" | grep -Eq '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'
}

github_list_duplicate() { # strict list JSON on stdin; sets GITHUB_DUP
  local parsed rc=0
  parsed="$(EXPECTED_SUMMARY="$SUMMARY" perl -MJSON::PP -MEncode=decode,FB_CROAK -0777 -e '
    my $items = decode_json(<>);
    exit 1 unless ref($items) eq "ARRAY";
    exit 4 if @$items >= 1000; # the requested cap cannot prove an exhaustive negative result
    my $want = decode("UTF-8", $ENV{EXPECTED_SUMMARY}, FB_CROAK);
    my @match;
    for my $item (@$items) {
      exit 1 unless ref($item) eq "HASH" && scalar(keys %$item) == 3;
      exit 1 unless exists($item->{title}) && defined($item->{title}) && !ref($item->{title});
      exit 1 unless exists($item->{number}) && defined($item->{number}) && !ref($item->{number})
        && "$item->{number}" =~ /\A[1-9][0-9]*\z/;
      exit 1 unless exists($item->{state}) && defined($item->{state}) && !ref($item->{state})
        && ($item->{state} eq "OPEN" || $item->{state} eq "CLOSED");
      push @match, "$item->{number}" if $item->{state} eq "OPEN" && $item->{title} eq $want;
    }
    exit 3 if @match > 1;
    print $match[0] if @match == 1;
  ' 2>/dev/null)" || rc=$?
  GITHUB_DUP="$parsed"
  return "$rc"
}

github_search() { # first|second|reconcile; sets GITHUB_DUP, 10=network, 3=ambiguous, 1=invalid
  local phase="$1" rc response
  if ! response="$(github_net gh issue list --repo "$GITHUB_REPO_SPEC" \
    --state all --limit 1000 --json number,title,state 2>/dev/null | bounded_capture 16777216)"; then
    return 10
  fi
  github_list_duplicate <<<"$response"; rc=$?
  return "$rc"
}

github_search_or_finish() { # phase; leaves GITHUB_DUP
  local phase="$1" recovery_key="${2:-}" rc
  github_search "$phase"; rc=$?
  case "$rc" in
    0) ;;
    3) finish_deferred "github-search-ambiguous" "$recovery_key" ;;
    4) finish_deferred "github-search-incomplete" "$recovery_key" ;;
    10) finish_deferred "github-search-unavailable" "$recovery_key" ;;
    *) finish_deferred "github-search-invalid" "$recovery_key" ;;
  esac
}

github_ticket() {
  local configured_repo="" configured_repo_spec="" remote_url="" repo_record="" visibility="" num="" reconcile="" pinned_repo="" response="" current_ticket="" create_rc=0 search_rc=0
  command -v gh >/dev/null 2>&1 || finish_deferred "github-cli-unavailable"

  # GitHub authority comes from the canonical GitHub.com origin, never from ambient gh state.
  # GH_REPO (owner/repo или github.com/owner/repo) may only repeat that value; it cannot select
  # another repository or host.
  remote_url="$FROZEN_ORIGIN_URL"
  case "$remote_url" in *$'\n'*) remote_url="";; esac
  case "$remote_url" in
    https://github.com/*) configured_repo="${remote_url#https://github.com/}"; configured_repo="${configured_repo%.git}";;
    git@github.com:*) configured_repo="${remote_url#git@github.com:}"; configured_repo="${configured_repo%.git}";;
    ssh://git@github.com/*) configured_repo="${remote_url#ssh://git@github.com/}"; configured_repo="${configured_repo%.git}";;
  esac
  [ -n "$configured_repo" ] && github_repo_is_safe "$configured_repo" \
    || finish_error "github-origin-unavailable"
  if [ "${GH_REPO+x}" = x ]; then
    pinned_repo="${GH_REPO#github.com/}"
    github_repo_is_safe "$pinned_repo" || finish_error "github-repo-invalid"
    [ "$pinned_repo" = "$configured_repo" ] || finish_error "github-repo-mismatch"
  fi
  configured_repo_spec="github.com/$configured_repo"

  PROVIDER_METADATA_SECRET_RC=0
  provider_metadata_secret_free "$configured_repo" "$configured_repo_spec" \
    || PROVIDER_METADATA_SECRET_RC=$?
  case "$PROVIDER_METADATA_SECRET_RC" in
    0) ;;
    1) finish_error "secret-in-provider-metadata" ;;
    *) finish_error "secret-policy-invalid" ;;
  esac

  response="$(github_net gh repo view "$configured_repo_spec" \
    --json nameWithOwner,visibility 2>/dev/null | bounded_capture 16777216)" \
    || finish_deferred "github-visibility-unavailable"
  repo_record="$(printf '%s' "$response" | EXPECTED_REPO="$configured_repo" perl -MJSON::PP -0777 -e '
    my $obj=decode_json(<>); exit 1 unless ref($obj) eq "HASH" && scalar(keys %$obj)==2;
    my ($repo,$v)=@$obj{qw(nameWithOwner visibility)};
    exit 1 unless defined($repo) && !ref($repo) && $repo =~ /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/;
    exit 1 if length($ENV{EXPECTED_REPO}) && $repo ne $ENV{EXPECTED_REPO};
    exit 1 unless defined($v) && !ref($v) && ($v eq "PRIVATE" || $v eq "INTERNAL" || $v eq "PUBLIC");
    print $repo,q{|},$v;
  ' 2>/dev/null)" || finish_deferred "github-visibility-invalid"
  GITHUB_REPO="${repo_record%%|*}"; visibility="${repo_record#*|}"
  GITHUB_REPO_SPEC="github.com/$GITHUB_REPO"
  if [ "$visibility" = "PUBLIC" ] && [ "${INTAKE_ALLOW_PUBLIC:-0}" != "1" ]; then
    printf '%s\n' 'intake: репозиторий PUBLIC — после явного confirm повтори с INTAKE_ALLOW_PUBLIC=1' >&2
    finish_deferred "public-repo"
  fi

  github_search_or_finish first
  if [ -n "$GITHUB_DUP" ]; then
    case "$SPEC_TICKET_AT_LOCK" in "—"|"#$GITHUB_DUP") :;;
      *) finish_deferred "spec-already-linked" "$SPEC_TICKET_AT_LOCK";; esac
    trace "ticket:create:attempt" "backend=github phase=dedup result=hit key=#$GITHUB_DUP"
    verify_and_link "#$GITHUB_DUP" github dedup gh issue view "$GITHUB_DUP" \
      --repo "$GITHUB_REPO_SPEC" --json number,title,body,state
  fi
  [ "$SPEC_TICKET_AT_LOCK" = "—" ] \
    || finish_deferred "spec-already-linked" "$SPEC_TICKET_AT_LOCK"

  # Recheck under the local transaction lock immediately before mutation.
  github_search_or_finish second
  if [ -n "$GITHUB_DUP" ]; then
    trace "ticket:create:attempt" "backend=github phase=dedup result=late-hit key=#$GITHUB_DUP"
    verify_and_link "#$GITHUB_DUP" github dedup gh issue view "$GITHUB_DUP" \
      --repo "$GITHUB_REPO_SPEC" --json number,title,body,state
  fi

  current_ticket="$(spec_ticket_read)" || finish_deferred "spec-authority-changed"
  [ "$current_ticket" = "$SPEC_TICKET_AT_LOCK" ] \
    || finish_deferred "spec-link-conflict" "$current_ticket"
  trace "ticket:create:attempt" "backend=github phase=create"
  response="$(printf '%s' "$BODY" | github_net gh issue create \
    --repo "$GITHUB_REPO_SPEC" --title "$SUMMARY" --body-file - 2>/dev/null \
    | bounded_capture 16777216)" || create_rc=$?
  num="$(printf '%s' "$response" | EXPECTED_REPO="$GITHUB_REPO" perl -0777 -ne '
    my $repo=quotemeta($ENV{EXPECTED_REPO});
    if (m{\Ahttps://github\.com/$repo/issues/([1-9][0-9]*)\s*\z}) { print $1 }
  ' 2>/dev/null)"
  github_search reconcile; search_rc=$?
  [ "$search_rc" -eq 0 ] && [ -n "$GITHUB_DUP" ] \
    || finish_deferred "mutation-ambiguous" "${num:+#$num}"
  reconcile="$GITHUB_DUP"
  [ -z "$num" ] || [ "$reconcile" = "$num" ] \
    || finish_deferred "mutation-ambiguous" "#$num"
  num="$reconcile"
  verify_and_link "#$num" github create gh issue view "$num" --repo "$GITHUB_REPO_SPEC" --json number,title,body,state
}

freeze_repo_file() { # validated repo-relative source bytes on stdout; caller seals them with helper write
  ROOT="." REL="$1" perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISREG,S_ISDIR -e '
    use strict; use warnings;
    my ($root,$rel)=@ENV{qw(ROOT REL)};
    sub ident { my (@s)=@_; return join(q{:},@s[0,1,2,3,7,9,10]) }
    exit 1 if !defined($rel) || $rel eq q{} || $rel =~ m{^/};
    my @parts=split m{/},$rel,-1; exit 1 unless @parts;
    for my $part (@parts) { exit 1 if $part eq q{} || $part eq q{.} || $part eq q{..} || $part !~ /\A[A-Za-z0-9_.-]+\z/ }
    sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @root=stat($root_fh);
    exit 1 unless @root && S_ISDIR($root[2]); chdir($root_fh) or exit 1; my @dirs=($root_fh);
    for my $i (0..$#parts-1) {
      my $part=$parts[$i]; my @named=lstat($part); exit 1 unless @named && S_ISDIR($named[2]) && !-l _;
      sysopen(my $dir,$part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
      exit 1 unless @opened && ident(@opened) eq ident(@named); push @dirs,$dir; chdir($dir) or exit 1;
    }
    my $leaf=$parts[-1]; sysopen(my $fh,$leaf,O_RDONLY|O_NOFOLLOW) or exit 1;
    my @s=stat($fh); exit 1 unless @s && S_ISREG($s[2]) && $s[3]==1;
    my @named=lstat($leaf); exit 1 unless @named && !-l _ && ident(@named) eq ident(@s);
    my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n; last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
    sysseek($fh,0,0)>=0 or exit 1; my $confirm=q{};
    while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined $n; last unless $n; $confirm.=$buf; exit 1 if length($confirm)>16777216 }
    exit 1 if $raw eq q{} || $raw=~/\x00/ || $confirm ne $raw;
    my @after=stat($fh); close $fh or exit 1;
    @named=lstat($leaf); exit 1 unless @after && @named && !-l _ && ident(@after) eq ident(@s) && ident(@named) eq ident(@s);
    print $raw;
  ' 2>/dev/null
}

# Первый audit event появляется только после local authority validation и локальной сериализации.
# Ни summary, ни body в нём нет.
intake_tmp_guard || early_error "tmp-unavailable"
PIPELINE_STATE_RECORD="$(freeze_repo_file "scripts/pipeline-state.sh" \
  | intake_snapshot_write pipeline-state.sh)" \
  || early_error "invalid-runtime"
intake_tmp_guard || early_error "tmp-unavailable"
PIPELINE_PRIVATE_TMP_RECORD="$(freeze_repo_file "scripts/private-temp-dir.pl" \
  | intake_snapshot_write private-temp-dir.pl)" \
  || early_error "invalid-runtime"
intake_tmp_guard || early_error "tmp-unavailable"
PIPELINE_READER_DIR_ID="$(perl "$PRIVATE_TMP_HELPER" make-dir "$tmpdir" "$tmpdir_id" lib 2>/dev/null)" \
  || early_error "invalid-runtime"
PIPELINE_READER_RECORD="$(freeze_repo_file "scripts/lib/pipeline-state-reader-v4.pl" \
  | perl "$PRIVATE_TMP_HELPER" write "$tmpdir/lib" "$PIPELINE_READER_DIR_ID" \
      pipeline-state-reader-v4.pl 2>/dev/null)" \
  || early_error "invalid-runtime"
intake_tmp_guard || early_error "tmp-unavailable"
PIPELINE_STATE_PATH="$tmpdir/pipeline-state.sh"
intake_snapshot_read pipeline-state.sh "$PIPELINE_STATE_RECORD" >/dev/null \
  || early_error "invalid-runtime"
intake_snapshot_read private-temp-dir.pl "$PIPELINE_PRIVATE_TMP_RECORD" >/dev/null \
  || early_error "invalid-runtime"
pipeline_reader_snapshot_read >/dev/null || early_error "invalid-runtime"
spec_guard || early_error "spec-authority-changed"
acquire_intake_locks
pipeline_state_exec validate-state "$SPEC_DIR" >/dev/null 2>&1 \
  || finish_error "invalid-pipeline-state"
SPEC_TICKET_AT_LOCK="$(spec_ticket_read)" || finish_error "spec-authority-changed"
[ -n "$SPEC_TICKET_AT_LOCK" ] || finish_error "spec-authority-changed"
state_ticket_valid "$SPEC_TICKET_AT_LOCK" || finish_error "invalid-state-ticket"
if [ "$SPEC_TICKET_AT_LOCK" != "—" ]; then
  finish_deferred "spec-already-linked" "$SPEC_TICKET_AT_LOCK"
fi
trace_required "ticket:create:attempt" "backend=$ISSUE_BACKEND phase=start" \
  || finish_error "audit-unavailable"
case "$ISSUE_BACKEND" in
  github) github_ticket ;;
  *) finish_error "invalid-issue-backend" ;;
esac
finish_error "unreachable"
