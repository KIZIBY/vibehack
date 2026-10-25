#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EACCES EAGAIN ECHILD EINTR ENOENT ESRCH EWOULDBLOCK);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW O_NONBLOCK FD_CLOEXEC F_GETFD F_GETFL F_SETFD F_SETFL S_ISDIR S_ISLNK S_ISREG SEEK_SET);
use File::Basename qw(dirname);
use File::Path qw(remove_tree);
use File::Temp qw(tempdir tempfile);
use IO::Handle;
use IO::Select;
use POSIX qw(SA_NOCLDSTOP SIGALRM SIGCHLD SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK SIG_UNBLOCK setpgid sigaction sigprocmask);
use Time::HiRes qw(alarm clock_gettime CLOCK_MONOTONIC sleep);

# Trusted-host producer for the complete immutable performance workload manifest.  It introduces
# no audit event grammar: the pipeline owns the CAS append of the returned start/finish details.
# One aggregate PASS artifact is written only after every workload has run against exact,
# mutation-evident Git materializations and every measured series satisfies its declared budget.
# This is trusted-host evidence, not an OS sandbox or protection from a malicious same-owner process.

my $MAX_FILE       = 16 * 1024 * 1024;
my $MAX_DERIVED_ARTIFACT = $MAX_FILE;
my $MAX_TREE       = 128 * 1024 * 1024;
my $MAX_GIT_OUTPUT = 256 * 1024 * 1024;
my $MAX_STREAM     = 4 * 1024 * 1024;
my $MAX_LOOKUP_PATHS = 8192;
my $MAX_LOOKUP_ARG_BYTES = 64 * 1024;
my $MAX_LOOKUP_BATCH = 128;
my $MAX_ARGC       = 128;
my $MAX_ARG_BYTES  = 64 * 1024;
my $MAX_WORKLOADS  = 64;
my $MAX_MEASURED_RUNS = 256;
my $MAX_MANIFEST_ROWS = 4096;
my $MAX_DATASET_ROWS = 4096;
my $MAX_TEST_MANIFEST_ROWS = 4096;
my $TIMEOUT        = 30;
my $AGGREGATE_TIMEOUT = 600;
my $PROGRAM_STARTED = clock_gettime(CLOCK_MONOTONIC);
my $AGGREGATE_DEADLINE = $PROGRAM_STARTED + $AGGREGATE_TIMEOUT;
my $MAX_UINT       = 9_007_199_254_740_991;

my $OID_RE     = qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my $ROOT_RE    = qr/[0-9a-f]{64}/;
my $ATTEMPT_RE = qr/[0-9a-f]{64}/;
my $ACTOR_RE   = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $UINT_RE    = qr/(?:0|[1-9][0-9]*)/;
my $WORKLOAD_RE = qr/W-[A-Z0-9][A-Z0-9-]{1,63}/;
my $IMPACT_CLASS_RE = qr/(?:product-runtime|verification-runtime|control-plane-runtime)/;
my $REASON_CLASS_RE = qr/(?:non-executed-content|test-support-only|delivery-evidence-only|outside-declared-performance-objective)/;
my $REQ_RE = qr/(?:FR|NFR)-[0-9]{3}/;
my $TEST_RE = qr/T-[A-Z0-9][A-Z0-9-]{1,63}/;
my %SYSTEM_INTERPRETER = map { $_ => 1 } qw(
  /usr/bin/perl
  /bin/bash
  /bin/sh
);
my $MODERN_HEADER = encode(q{UTF-8},
  "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n"
  . "| ts (UTC) | event | detail |\n|---|---|---|\n");
my $LEGACY_HEADER =
  "# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $ENV_MANIFEST = join(q{},
  "HARNESS-PERFORMANCE-ENV-V1\n",
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin\n",
  "LC_ALL=C\nLANG=C\nTZ=UTC\nHOME=<isolated>\nTMPDIR=<isolated>\n");
my $SCRIPT_DIR = abs_path(dirname(__FILE__));
my $INTERNAL_GIT_CONTEXT = delete $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1};
our $ACTIVE_PROCESS_GROUP;
our $ARTIFACT_TEMP_GUARD;
our $DEDICATED_DONE_WRITE;

END {
  cleanup_artifact_temp() if defined($ARTIFACT_TEMP_GUARD);
  notify_dedicated_guard();
}

sub fatal { print STDERR "performance-process-v1: FATAL: $_[0]\n"; exit 2 }
sub monotonic_now { return clock_gettime(CLOCK_MONOTONIC) }
sub arm_aggregate_deadline {
  my $remaining = $AGGREGATE_DEADLINE - monotonic_now();
  fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)")
    unless $remaining > 0;
  $SIG{ALRM} = sub {
    stop_process_group($ACTIVE_PROCESS_GROUP) if defined($ACTIVE_PROCESS_GROUP);
    if (defined($ARTIFACT_TEMP_GUARD) && !cleanup_artifact_temp()) {
      print STDERR "performance-process-v1: FATAL: performance artifact temp cleanup failed\n";
    }
    print STDERR "performance-process-v1: FATAL: aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)\n";
    # Perl's deferred safe-signal handler runs at an opcode boundary.  A normal exit is therefore
    # deliberate here: it preserves process-group termination while allowing our END guard and
    # File::Temp's registered cleanup to remove partially materialized snapshots/run/probe roots.
    # _exit would bypass both registries and strand up to the full bounded closure in TMPDIR.
    alarm(0);
    CORE::exit(2);
  };
  alarm($remaining);
}
sub inode_id { return $_[0][0] . q{:} . $_[0][1] }
sub valid_uint {
  my ($v) = @_;
  return defined($v) && $v =~ /\A$UINT_RE\z/ && length($v) <= 16 && $v <= $MAX_UINT;
}

sub producer_identity {
  my ($root, $candidate) = @_;
  my $path = "$SCRIPT_DIR/performance-process-v1.pl";
  my @named = lstat($path);
  fatal('performance producer source is unavailable')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1
      && ($named[2] & 07777) == 0644 && $named[7] <= $MAX_FILE;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW)
    or fatal('performance producer source open failed');
  my @opened = stat($fh);
  fatal('performance producer source identity changed')
    unless @opened && inode_id(\@opened) eq inode_id(\@named);
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('performance producer source read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('performance producer source exceeds size cap') if length($raw) > $MAX_FILE;
  }
  my @after = stat($fh); my @again = lstat($path);
  fatal('performance producer source changed during identity read')
    unless @after && @again && !S_ISLNK($again[2])
      && inode_id(\@after) eq inode_id(\@opened)
      && inode_id(\@again) eq inode_id(\@opened)
      && $after[7] == length($raw) && $again[7] == length($raw)
      && ($after[2] & 07777) == 0644 && ($again[2] & 07777) == 0644;
  close($fh) or fatal('performance producer source close failed');
  my $listing = git_capture($root, 8192, 'ls-tree', '-z', $candidate, '--',
    'scripts/performance-process-v1.pl');
  my ($mode, $type, $oid, $found) =
    $listing =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t([^\x00]+)\x00\z/s;
  fatal('performance producer is absent from checkpoint C')
    unless defined($found) && $found eq 'scripts/performance-process-v1.pl';
  fatal('checkpoint performance producer must be a 100644 blob')
    unless $type eq 'blob' && $mode eq '100644';
  my $checkpoint_raw = git_capture($root, $MAX_FILE + 1, 'cat-file', 'blob', $oid);
  fatal('checkpoint performance producer exceeds size cap') if length($checkpoint_raw) > $MAX_FILE;
  fatal('live performance producer differs from exact checkpoint C') unless $raw eq $checkpoint_raw;
  return sha256_hex($checkpoint_raw);
}

sub safe_rel {
  my ($raw, $label) = @_;
  fatal("empty repo-relative path: $label") unless defined($raw) && length($raw);
  fatal("unsafe repo-relative path: $label") if $raw =~ m{\A/} || $raw =~ /[\x00-\x1f\x7f]/;
  fatal("repo-relative path contains Markdown table delimiter: $label") if $raw =~ /\|/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("repo-relative path is not UTF-8: $label");
  fatal("Unicode control in repo-relative path: $label") if $text =~ /\p{Cc}/;
  fatal("Unicode format or line separator in repo-relative path: $label")
    if $text =~ /[\p{Cf}\p{Zl}\p{Zp}]/;
  my @part = split m{/}, $raw, -1;
  fatal("unsafe repo-relative path segment: $label")
    if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  return @part;
}

sub canonical_rel_candidate {
  my ($raw) = @_;
  return 0 unless defined($raw) && length($raw);
  return 0 if $raw =~ m{\A/} || $raw =~ /[\x00-\x1f\x7f|]/;
  my $text;
  return 0 unless eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 };
  return 0 if $text =~ /\p{Cc}/ || $text =~ /[\p{Cf}\p{Zl}\p{Zp}]/;
  my @part = split m{/}, $raw, -1;
  return 0 if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  return 1;
}

sub open_root {
  my ($arg) = @_;
  my @named = lstat($arg);
  fatal('repo root must be a real directory')
    unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
  my $abs = abs_path($arg);
  fatal('repo root unavailable') unless defined($abs);
  sysopen(my $fh, $abs, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('repo root open failed');
  my @opened = stat($fh);
  my @canonical = lstat($abs);
  fatal('repo root identity changed')
    unless @opened && @canonical && !S_ISLNK($canonical[2])
      && S_ISDIR($opened[2]) && S_ISDIR($canonical[2])
      && inode_id(\@opened) eq inode_id(\@canonical)
      && inode_id(\@opened) eq inode_id(\@named);
  return { abs => $abs, fh => $fh, id => inode_id(\@opened) };
}

sub check_root {
  my ($root) = @_;
  my @opened = stat($root->{fh});
  my @named = lstat($root->{abs});
  fatal('repo root identity changed')
    unless @opened && @named && !S_ISLNK($named[2])
      && S_ISDIR($opened[2]) && S_ISDIR($named[2])
      && inode_id(\@opened) eq $root->{id} && inode_id(\@named) eq $root->{id};
}

sub open_leaf {
  my ($root, $rel, $limit, $mode) = @_;
  my @part = safe_rel($rel, $rel);
  check_root($root);
  chdir($root->{fh}) or fatal('repo root traversal failed');
  my $dir = $root->{fh};
  my @hold = ($dir);
  if (@part > 1) {
    for my $component (@part[0 .. $#part - 1]) {
      chdir($dir) or fatal('directory traversal failed');
      my @named = lstat($component);
      fatal("unsafe parent for $rel")
        unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
      sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        or fatal("cannot open parent for $rel");
      my @opened = stat($next);
      fatal("parent identity changed for $rel")
        unless @opened && inode_id(\@opened) eq inode_id(\@named);
      push @hold, $next;
      $dir = $next;
    }
  }
  chdir($dir) or fatal("artifact directory unavailable: $rel");
  my $leaf = $part[-1];
  my @named = lstat($leaf);
  fatal("$rel must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$rel mode must be 100644") unless ($named[2] & 07777) == $mode;
  fatal("$rel exceeds size limit") if $named[7] > $limit;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $rel");
  my @opened = stat($fh);
  fatal("$rel identity changed")
    unless @opened && inode_id(\@opened) eq inode_id(\@named)
      && S_ISREG($opened[2]) && $opened[3] == 1 && ($opened[2] & 07777) == $mode;
  return { fh => $fh, dir => $dir, leaf => $leaf, opened => \@opened,
    hold => \@hold, limit => $limit, mode => $mode, rel => $rel };
}

sub read_from_start {
  my ($leaf) = @_;
  defined(sysseek($leaf->{fh}, 0, SEEK_SET)) or fatal('file seek failed');
  my $raw = q{};
  while (1) {
    my $n = sysread($leaf->{fh}, my $buf, 65_536);
    fatal('file read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal("$leaf->{rel} exceeds size limit") if length($raw) > $leaf->{limit};
  }
  return $raw;
}

sub check_leaf {
  my ($leaf, $length) = @_;
  my @opened = stat($leaf->{fh});
  chdir($leaf->{dir}) or fatal('artifact directory unavailable');
  my @named = lstat($leaf->{leaf});
  fatal("$leaf->{rel} changed during read")
    unless @opened && @named && !S_ISLNK($named[2])
      && S_ISREG($opened[2]) && S_ISREG($named[2])
      && $opened[3] == 1 && $named[3] == 1
      && inode_id(\@opened) eq inode_id($leaf->{opened})
      && inode_id(\@named) eq inode_id($leaf->{opened})
      && ($opened[2] & 07777) == $leaf->{mode}
      && ($named[2] & 07777) == $leaf->{mode}
      && $opened[7] == $length && $named[7] == $length;
}

sub read_repo_file {
  my ($root, $rel) = @_;
  my $first = open_leaf($root, $rel, $MAX_FILE, 0644);
  my $raw = read_from_start($first);
  check_leaf($first, length($raw));
  fatal("$rel changed between descriptor reads") unless read_from_start($first) eq $raw;
  check_leaf($first, length($raw));
  my $second = open_leaf($root, $rel, $MAX_FILE, 0644);
  fatal("$rel identity changed after canonical re-resolution")
    unless inode_id($second->{opened}) eq inode_id($first->{opened});
  fatal("$rel bytes changed after canonical re-resolution")
    unless read_from_start($second) eq $raw;
  check_leaf($second, length($raw));
  check_leaf($first, length($raw));
  check_root($root);
  return $raw;
}

sub sanitize_environment {
  delete @ENV{qw(
    CDPATH ENV BASH_ENV PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC
    GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OBJECT_DIRECTORY
    GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_COMMON_DIR GIT_NAMESPACE
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0
    GIT_CONFIG_PARAMETERS GIT_CONFIG_SYSTEM GIT_EXEC_PATH GIT_TEMPLATE_DIR
    GIT_ATTR_NOSYSTEM GIT_EXTERNAL_DIFF GIT_DIFF_OPTS GIT_SSH GIT_SSH_COMMAND
    GIT_REPLACE_REF_BASE GIT_LITERAL_PATHSPECS GIT_GLOB_PATHSPECS
    GIT_NOGLOB_PATHSPECS GIT_ICASE_PATHSPECS
  )};
  for my $key (keys %ENV) {
    delete $ENV{$key} if $key =~ /\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z/;
  }
  $ENV{PATH} = '/usr/bin:/bin:/usr/sbin:/sbin';
  $ENV{LC_ALL} = 'C'; $ENV{LANG} = 'C'; $ENV{TZ} = 'UTC';
  $ENV{GIT_OPTIONAL_LOCKS} = '0'; $ENV{GIT_NO_REPLACE_OBJECTS} = '1';
  $ENV{GIT_CONFIG_NOSYSTEM} = '1'; $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  $ENV{GIT_CONFIG_SYSTEM} = '/dev/null'; $ENV{GIT_PAGER} = 'cat';
}

sub context_path {
  my ($hex, $label) = @_;
  fatal("internal Git context $label malformed")
    unless defined($hex) && $hex =~ /\A(?:[0-9a-f]{2})+\z/;
  return pack(q{H*}, $hex);
}

sub canonical_existing_path {
  my ($root, $raw, $label) = @_;
  my $path = $raw =~ m{\A/} ? $raw : "$root->{abs}/$raw";
  my $canonical = abs_path($path);
  fatal("internal Git context $label unavailable") unless defined($canonical);
  return $canonical;
}

sub configure_internal_git_context {
  my ($root) = @_;
  return unless defined($INTERNAL_GIT_CONTEXT) && length($INTERNAL_GIT_CONTEXT);
  my @v = split /:/, $INTERNAL_GIT_CONTEXT, -1;
  fatal('internal Git context record malformed') unless @v == 11 && shift(@v) eq '1';
  my ($worktree_hex, $gitdir_hex, $common_hex, $index_hex,
      $head, $tree, $dev, $ino, $size, $digest) = @v;
  my $worktree = context_path($worktree_hex, 'worktree');
  my $gitdir = context_path($gitdir_hex, 'gitdir');
  my $common = context_path($common_hex, 'common-dir');
  my $index = context_path($index_hex, 'index');
  fatal('internal Git context identity malformed')
    unless $head =~ /\A$OID_RE\z/ && $tree =~ /\A$OID_RE\z/
      && $dev =~ /\A[0-9]+\z/ && $ino =~ /\A[0-9]+\z/
      && $size =~ /\A(?:0|[1-9][0-9]*)\z/ && $digest =~ /\A$ROOT_RE\z/;
  fatal('internal Git context worktree mismatch')
    unless canonical_existing_path($root, $worktree, 'worktree') eq $root->{abs};
  $gitdir = canonical_existing_path($root, $gitdir, 'gitdir');
  $common = canonical_existing_path($root, $common, 'common-dir');
  my $index_parent = canonical_existing_path($root, dirname($index), 'index parent');
  (my $index_leaf = $index) =~ s{.*/}{};
  $index = "$index_parent/$index_leaf";
  my @named = lstat($index);
  fatal('internal Git context index is unsafe')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1
      && $named[0] eq $dev && $named[1] eq $ino && $named[7] eq $size;
  sysopen(my $fh, $index, O_RDONLY | O_NOFOLLOW)
    or fatal('internal Git context index open failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('internal Git context index read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('internal Git context index exceeds safety limit')
      if length($raw) > $MAX_GIT_OUTPUT;
  }
  my @opened = stat($fh); my @again = lstat($index);
  close($fh) or fatal('internal Git context index close failed');
  fatal('internal Git context index changed')
    unless @opened && @again && !S_ISLNK($again[2]) && S_ISREG($again[2])
      && $opened[0] eq $dev && $opened[1] eq $ino
      && $again[0] eq $dev && $again[1] eq $ino
      && length($raw) == $size && sha256_hex($raw) eq $digest;
  $ENV{GIT_DIR} = $gitdir;
  $ENV{GIT_WORK_TREE} = $worktree;
  $ENV{GIT_INDEX_FILE} = $index;
  $ENV{GIT_COMMON_DIR} = $common;
  $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1} = $INTERNAL_GIT_CONTEXT;
  my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'),
    'context worktree');
  my $actual_gitdir = exact_line(git_capture($root, 16_384,
    'rev-parse', '--absolute-git-dir'), 'context gitdir');
  my $actual_common = exact_line(git_capture($root, 16_384,
    'rev-parse', '--git-common-dir'), 'context common-dir');
  my $actual_index = exact_line(git_capture($root, 16_384,
    'rev-parse', '--git-path', 'index'), 'context index');
  fatal('internal Git context worktree rediscovery mismatch')
    unless canonical_existing_path($root, $top, 'rediscovered worktree') eq $worktree;
  fatal('internal Git context gitdir rediscovery mismatch')
    unless canonical_existing_path($root, $actual_gitdir, 'rediscovered gitdir') eq $gitdir;
  fatal('internal Git context common-dir rediscovery mismatch')
    unless canonical_existing_path($root, $actual_common, 'rediscovered common-dir') eq $common;
  fatal('internal Git context index rediscovery mismatch')
    unless canonical_existing_path($root, $actual_index, 'rediscovered index') eq $index;
  fatal('internal Git context HEAD changed')
    unless exact_line(git_capture($root, 4096, 'rev-parse', '--verify', 'HEAD^{commit}'),
      'context HEAD') eq $head;
  fatal('internal Git context index tree changed')
    unless exact_line(git_capture($root, 4096, 'write-tree'), 'context tree') eq $tree;
}

sub git_argv {
  my ($root, @args) = @_;
  return ('git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'core.untrackedCache=false', '-c', 'core.trustctime=true',
    '-c', 'core.checkStat=default', '-c', 'core.ignoreStat=false',
    '-C', $root->{abs}, @args);
}

sub stop_process_group {
  my ($pid) = @_;
  return unless defined($pid);
  kill 'TERM', -$pid;
  kill 'TERM', $pid;
  sleep 0.02;
  kill 'KILL', -$pid;
  kill 'KILL', $pid;
  # Signals were sent while the leader still pinned the numeric identity.  Drop async authority
  # before reap so an alarm/error interleaving cannot target a recycled PID/PGID.
  $ACTIVE_PROCESS_GROUP = undef
    if defined($ACTIVE_PROCESS_GROUP) && $ACTIVE_PROCESS_GROUP == $pid;
  while (1) {
    my $got = waitpid($pid, 0);
    return if $got == $pid || ($got == -1 && $! == ECHILD);
    next if $got == -1 && $! == EINTR;
    return;
  }
}

sub block_launch_alarm {
  my ($label) = @_;
  # Deadline, child-exit and cancellation signals are blocked across
  # fork -> setpgid -> ACTIVE_PROCESS_GROUP registration.  Cancellation therefore cannot arrive
  # while a newly created child group exists but is not yet reachable by the runtime handler.
  my $blocked = POSIX::SigSet->new(SIGALRM, SIGCHLD, SIGHUP, SIGINT, SIGTERM);
  my $prior = POSIX::SigSet->new();
  sigprocmask(SIG_BLOCK, $blocked, $prior)
    or fatal("$label alarm-mask block failed");
  return $prior;
}

sub restore_launch_alarm {
  my ($prior, $pid, $label) = @_;
  return if sigprocmask(SIG_SETMASK, $prior);
  stop_process_group($pid) if defined($pid);
  fatal("$label alarm-mask restore failed");
}

sub enter_monitor_signal_window {
  my ($pid, $label) = @_;
  # The caller may have inherited any monitor signal blocked.  Once the owned PGID is registered,
  # monitoring explicitly enables the deadline, non-reaping exit notice and cancellation.  The
  # exact inherited mask is restored only after cleanup and final waitpid.
  my $monitor = POSIX::SigSet->new(SIGALRM, SIGCHLD, SIGHUP, SIGINT, SIGTERM);
  return if sigprocmask(SIG_UNBLOCK, $monitor);
  stop_process_group($pid) if defined($pid);
  fatal("$label monitor signal-mask activation failed");
}

sub install_child_exit_notification {
  my ($label, $flag) = @_;
  my $old = POSIX::SigAction->new();
  my $action = POSIX::SigAction->new(
    sub { $$flag = 1 }, POSIX::SigSet->new(), SA_NOCLDSTOP);
  $action->safe(1);
  sigaction(SIGCHLD, $action, $old)
    or fatal("$label SIGCHLD action install failed");
  return ($old, $action);
}

sub notify_dedicated_guard {
  return unless defined($DEDICATED_DONE_WRITE);
  my $fh = $DEDICATED_DONE_WRITE;
  $DEDICATED_DONE_WRITE = undef;
  while (1) {
    my $n = syswrite($fh, 'D', 1);
    last if defined($n) && $n == 1;
    next if !defined($n) && $! == EINTR;
    last;
  }
  close($fh);
}

sub re_raise_runtime_signal {
  my ($signal) = @_;
  my $default = POSIX::SigAction->new(
    POSIX::SIG_DFL(), POSIX::SigSet->new(), 0);
  sigaction($signal, $default)
    or POSIX::_exit(128 + $signal);
  my $one = POSIX::SigSet->new($signal);
  sigprocmask(SIG_UNBLOCK, $one)
    or POSIX::_exit(128 + $signal);
  kill $signal, $$;
  POSIX::_exit(128 + $signal);
}

sub enter_dedicated_runtime {
  # An exec caller may retain live children and pending SIGCHLD.  The isolated runtime inherits
  # neither.  A sibling guard owns cancellation forwarding through pipes, never a post-reap PID:
  # runtime completion is announced before the wrapper can reap, while HUP/INT/TERM are blocked
  # across both forks and handler registration.
  $SIG{CHLD} = 'DEFAULT';
  my $cancel_set = POSIX::SigSet->new(SIGHUP, SIGINT, SIGTERM);
  my $prior_cancel = POSIX::SigSet->new();
  sigprocmask(SIG_BLOCK, $cancel_set, $prior_cancel)
    or fatal('dedicated performance cancellation-mask block failed');
  pipe(my $cancel_read, my $cancel_write)
    or fatal('dedicated performance cancellation pipe failed');
  pipe(my $done_read, my $done_write)
    or fatal('dedicated performance completion pipe failed');

  my $pid = fork();
  unless (defined($pid)) {
    close($cancel_read); close($cancel_write); close($done_read); close($done_write);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated performance runtime fork failed');
  }
  if ($pid == 0) {
    close($cancel_read); close($cancel_write); close($done_read);
    $DEDICATED_DONE_WRITE = $done_write;
    my $flags = fcntl($done_write, F_GETFD, 0);
    defined($flags) && defined(fcntl($done_write, F_SETFD, $flags | FD_CLOEXEC))
      or fatal('dedicated performance completion CLOEXEC failed');
    my $cancelling = 0;
    for my $pair ([HUP => SIGHUP], [INT => SIGINT], [TERM => SIGTERM]) {
      my ($name, $number) = @$pair;
      $SIG{$name} = sub {
        return if $cancelling++;
        stop_process_group($ACTIVE_PROCESS_GROUP) if defined($ACTIVE_PROCESS_GROUP);
        alarm(0);
        CORE::exit(128 + $number);
      };
    }
    my $signals = POSIX::SigSet->new(SIGALRM, SIGCHLD, SIGHUP, SIGINT, SIGTERM);
    sigprocmask(SIG_UNBLOCK, $signals)
      or fatal('dedicated performance runtime signal-mask activation failed');
    return;
  }
  close($done_write);

  my $guard = fork();
  unless (defined($guard)) {
    kill SIGTERM, $pid;
    close($cancel_read); close($cancel_write);
    while (waitpid($pid, 0) == -1 && $! == EINTR) { }
    close($done_read);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated performance cancellation guard fork failed');
  }
  if ($guard == 0) {
    close($cancel_write);
    my $selector = IO::Select->new($cancel_read, $done_read);
    while (1) {
      my @ready = $selector->can_read();
      my %ready = map { fileno($_) => $_ } @ready;
      if (exists($ready{fileno($done_read)})) {
        my $n = sysread($done_read, my $buf, 1);
        next if !defined($n) && $! == EINTR;
        POSIX::_exit(0);
      }
      if (exists($ready{fileno($cancel_read)})) {
        my $n = sysread($cancel_read, my $code, 1);
        next if !defined($n) && $! == EINTR;
        my $signal = defined($n) && $n == 1
          ? ($code eq 'H' ? SIGHUP : $code eq 'I' ? SIGINT : SIGTERM)
          : SIGTERM;
        kill $signal, $pid;
        POSIX::_exit(0);
      }
    }
  }
  # Keep one local reader for each notification pipe until handlers are disabled.  This prevents
  # a peer exit from turning a late cancellation/completion write into SIGPIPE without globally
  # changing SIGPIPE semantics for either the wrapper or the runtime.

  my ($cancel_open, $cancel_signal) = (1, undef);
  my %old_signal = map { $_ => $SIG{$_} } qw(HUP INT TERM);
  for my $pair ([HUP => SIGHUP, 'H'], [INT => SIGINT, 'I'], [TERM => SIGTERM, 'T']) {
    my ($name, $number, $code) = @$pair;
    $SIG{$name} = sub {
      $cancel_signal //= $number;
      return unless $cancel_open;
      while (1) {
        my $n = syswrite($cancel_write, $code, 1);
        last if defined($n) && $n == 1;
        next if !defined($n) && $! == EINTR;
        last;
      }
      close($cancel_write);
      $cancel_open = 0;
    };
  }
  sigprocmask(SIG_UNBLOCK, $cancel_set)
    or fatal('dedicated performance cancellation-mask activation failed');

  # Reap the guard first: it is the only process allowed to signal the numeric runtime PID.  Once
  # it has exited, that authority is gone and the runtime can be reaped without a PID-reuse race.
  while (1) {
    my $got = waitpid($guard, 0);
    last if $got == $guard;
    next if $got == -1 && $! == EINTR;
    fatal('dedicated performance cancellation guard wait failed');
  }
  my $status;
  while (1) {
    my $got = waitpid($pid, 0);
    if ($got == $pid) { $status = $?; last }
    next if $got == -1 && $! == EINTR;
    fatal('dedicated performance runtime wait failed');
  }
  sigprocmask(SIG_BLOCK, $cancel_set)
    or fatal('dedicated performance cancellation-mask shutdown failed');
  @SIG{qw(HUP INT TERM)} = @old_signal{qw(HUP INT TERM)};
  if ($cancel_open) { close($cancel_write); $cancel_open = 0 }
  close($cancel_read); close($done_read);
  sigprocmask(SIG_SETMASK, $prior_cancel)
    or fatal('dedicated performance cancellation-mask restore failed');
  re_raise_runtime_signal($cancel_signal) if defined($cancel_signal);
  re_raise_runtime_signal($status & 127) if $status & 127;
  my $exit = ($status >> 8) & 255;
  re_raise_runtime_signal($exit - 128)
    if $exit == 128 + SIGHUP || $exit == 128 + SIGINT || $exit == 128 + SIGTERM;
  exit $exit;
}

sub deadline_capture {
  my ($deadline, $label, $limit, $quiet, @cmd) = @_;
  aggregate_deadline_guard($deadline);
  pipe(my $read, my $write) or fatal("$label pipe failed");
  my $child_exited = 0;
  my ($old_chld, $exit_action) =
    install_child_exit_notification($label, \$child_exited);
  my $prior_alarm_mask = block_launch_alarm($label);
  my $pid = fork();
  unless (defined($pid)) {
    sigaction(SIGCHLD, $old_chld)
      or fatal("$label SIGCHLD action restore failed");
    restore_launch_alarm($prior_alarm_mask, undef, $label);
    fatal("$label fork failed");
  }
  if ($pid == 0) {
    sigaction(SIGCHLD, $old_chld) or POSIX::_exit(125);
    close($read);
    my $child_pg = setpgid(0, 0);
    defined($child_pg) && $child_pg == 0 or POSIX::_exit(125);
    sigprocmask(SIG_SETMASK, $prior_alarm_mask) or POSIX::_exit(125);
    open(STDIN, '<', '/dev/null') or POSIX::_exit(125);
    if ($quiet) {
      open(STDOUT, '>', '/dev/null') or POSIX::_exit(125);
      open(STDERR, '>', '/dev/null') or POSIX::_exit(125);
    } else {
      open(STDOUT, '>&', $write) or POSIX::_exit(125);
    }
    close($write);
    chdir(q{/}) or POSIX::_exit(125);
    exec { $cmd[0] } @cmd or POSIX::_exit(125);
  }
  my $pg_ok = setpgid($pid, $pid);
  if ((!defined($pg_ok) || $pg_ok != 0) && $! != EACCES && $! != ESRCH) {
    stop_process_group($pid);
    restore_launch_alarm($prior_alarm_mask, undef, $label);
    fatal("$label process-group setup failed");
  }
  local $ACTIVE_PROCESS_GROUP = $pid;
  if (monotonic_now() >= $deadline) {
    stop_process_group($pid);
    $ACTIVE_PROCESS_GROUP = undef;
    restore_launch_alarm($prior_alarm_mask, undef, $label);
    fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)");
  }
  enter_monitor_signal_window($pid, $label);
  close($write);
  my $flags = fcntl($read, F_GETFL, 0);
  unless (defined($flags)) {
    stop_process_group($pid);
    fatal("$label pipe flag read failed");
  }
  unless (fcntl($read, F_SETFL, $flags | O_NONBLOCK)) {
    stop_process_group($pid);
    fatal("$label pipe nonblocking setup failed");
  }
  my $selector = IO::Select->new($read);
  my ($raw, $done, $status, $drain_deadline) = (q{}, 0, 0, undef);
  while (!$done || $selector->count) {
    if (monotonic_now() >= $deadline) {
      stop_process_group($pid);
      fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)");
    }
    my $remaining = $deadline - monotonic_now();
    my $poll = $remaining < 0.05 ? $remaining : 0.05;
    $poll = 0 if $poll < 0;
    for my $fh ($selector->can_read($poll)) {
      my $n = sysread($fh, my $buf, 65_536);
      if (!defined($n)) {
        next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        stop_process_group($pid);
        fatal("$label output read failed");
      }
      if (!$n) { $selector->remove($fh); close($fh); next }
      $raw .= $buf unless $quiet;
      if (length($raw) > $limit) {
        stop_process_group($pid);
        fatal("$label output exceeds safety limit");
      }
    }
    if (!$done) {
      if ($child_exited) {
        # The unreaped group leader pins PID/PGID ownership until cleanup signals are sent.
        kill 'KILL', -$pid;
        my $reap_mask = block_launch_alarm($label);
        $ACTIVE_PROCESS_GROUP = undef;
        while (1) {
          my $got = waitpid($pid, 0);
          if ($got == $pid) { $status = $?; last }
          next if $got == -1 && $! == EINTR;
          sigaction(SIGCHLD, $old_chld)
            or fatal("$label SIGCHLD action restore failed");
          restore_launch_alarm($prior_alarm_mask, undef, $label);
          fatal("$label wait failed");
        }
        $done = 1;
        $pid = undef;
        sigaction(SIGCHLD, $old_chld)
          or fatal("$label SIGCHLD action restore failed");
        restore_launch_alarm($prior_alarm_mask, undef, $label);
        if ($selector->count) {
          # A descendant retaining stdout must not extend a completed foreground command.
          $drain_deadline = monotonic_now() + 1;
          $drain_deadline = $deadline if $drain_deadline > $deadline;
        }
      }
    } elsif ($selector->count && monotonic_now() >= $drain_deadline) {
      for my $fh ($selector->handles) { $selector->remove($fh); close($fh) }
      fatal("$label retained output descriptors after parent exit");
    }
  }
  $ACTIVE_PROCESS_GROUP = undef;
  return ($raw, $status);
}

sub git_capture {
  my ($root, $limit, @args) = @_;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  my @cmd = git_argv($root, @args);
  my ($raw, $status) = deadline_capture(
    $AGGREGATE_DEADLINE, 'git command', $limit, 0, @cmd);
  fatal('git command terminated by signal') if $status & 127;
  fatal('git command failed') unless (($status >> 8) & 255) == 0;
  return $raw;
}

sub exact_line {
  my ($raw, $label) = @_;
  $raw =~ /\A([^\r\n]+)\n\z/ or fatal("$label output malformed");
  return $1;
}

sub audit_rows {
  my ($raw) = @_;
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('audit.md is not UTF-8');
  my $header;
  if (index($raw, $MODERN_HEADER) == 0) { $header = $MODERN_HEADER }
  elsif (index($raw, $LEGACY_HEADER) == 0) { $header = $LEGACY_HEADER }
  else { fatal('audit.md header is not canonical') }
  my $body = substr($raw, length($header));
  my @row;
  while (length($body)) {
    $body =~ s/\A\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
      or fatal('audit.md row is not canonical');
    push @row, [$2, $3];
  }
  return \@row;
}

sub open_performance_receipt {
  my ($raw, $attempt, $candidate) = @_;
  my $rows = audit_rows($raw);
  my ($generation, $receipt) = (0, undef);
  for my $row (@$rows) {
    my ($event, $detail) = @$row;
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=($UINT_RE);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      my ($next, $scopes) = ($1, $2);
      fatal('receipt generation is not monotonic') unless $next == $generation + 1;
      $generation = $next;
      $receipt = undef if grep { $_ eq 'quality' } split /,/, $scopes;
      next;
    }
    if ($event eq 'review-start:performance') {
      $detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=performance-review-v1\z/
        or fatal('non-canonical performance review-start detail');
      next unless $1 eq $attempt;
      fatal('performance attempt duplicated') if defined($receipt);
      fatal('performance start is not in current generation') unless $2 == $generation;
      $receipt = { attempt => $1, generation => $2, actor => $3, subject => $4,
        status => 'open' };
      next;
    }
    if ($event eq 'performance-run-start' || $event eq 'performance-run-finish') {
      my $kind = $event eq 'performance-run-start' ? 'start' : 'finish';
      my @value = $kind eq 'start'
        ? ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=performance-process-v1;workloads=($UINT_RE);manifest=($ROOT_RE);producer=($ROOT_RE)\z/)
        : ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=performance-process-v1;workloads=($UINT_RE);manifest=($ROOT_RE);producer=($ROOT_RE);raw-samples=($ROOT_RE);artifact=([^;\r\n]+);sha256=($ROOT_RE)\z/);
      fatal("non-canonical $event detail")
        unless @value == ($kind eq 'start' ? 7 : 10);
      next unless $value[0] eq $attempt;
      fatal('performance process event has no matching review start') unless defined($receipt);
      fatal('performance process event is not in current generation')
        unless $value[1] == $generation;
      fatal('performance process identity mismatches review start')
        unless $value[1] eq $receipt->{generation}
          && $value[2] eq $receipt->{actor} && $value[3] eq $receipt->{subject};
      fatal('performance process workload count outside cap')
        unless $value[4] > 0 && $value[4] <= $MAX_WORKLOADS;
      if ($kind eq 'start') {
        fatal('performance process lifecycle duplicated') unless $receipt->{status} eq 'open';
        $receipt->{status} = 'process-running';
        $receipt->{process} = {
          workloads => $value[4], manifest => $value[5], producer => $value[6],
        };
      } else {
        fatal('performance process finish has no exact start')
          unless $receipt->{status} eq 'process-running';
        for my $pair ([workloads => $value[4]], [manifest => $value[5]],
            [producer => $value[6]]) {
          fatal("performance process finish $pair->[0] mismatch")
            unless $receipt->{process}{$pair->[0]} eq $pair->[1];
        }
        safe_rel($value[8], 'performance process artifact');
        $receipt->{status} = 'finished-process';
      }
      next;
    }
    if ($event =~ /\Areview-(blocked|finish):performance\z/) {
      my $kind = $1;
      next unless $detail =~ /\Aattempt=($ATTEMPT_RE);/ && $1 eq $attempt;
      fatal('performance terminal has no matching start') unless defined($receipt);
      fatal('performance attempt already terminal') unless $receipt->{status} eq 'open';
      my $prefix = join(q{;}, "attempt=$receipt->{attempt}",
        "generation=$receipt->{generation}", "actor=$receipt->{actor}",
        "subject=$receipt->{subject}", 'capability=performance-review-v1');
      fatal('performance terminal identity mismatch') unless index($detail, "$prefix;") == 0;
      $receipt->{status} = $kind;
    }
  }
  fatal('performance review-start attempt absent') unless defined($receipt);
  fatal('performance receipt is not open') unless $receipt->{status} eq 'open';
  fatal('performance receipt subject is not exact checkpoint C')
    unless $receipt->{subject} eq $candidate;
  fatal('performance receipt is not in current generation')
    unless $receipt->{generation} == $generation;
  return $receipt;
}

sub commit_tree {
  my ($root, $oid, $label) = @_;
  fatal("$label GitOid malformed") unless $oid =~ /\A$OID_RE\z/;
  my $resolved = exact_line(git_capture($root, 4096, 'rev-parse', '--verify', "$oid^{commit}"), $label);
  fatal("$label does not name its exact commit") unless $resolved eq $oid;
  my $tree = exact_line(git_capture($root, 4096, 'rev-parse', "$oid^{tree}"), "$label tree");
  fatal("$label tree GitOid malformed") unless $tree =~ /\A$OID_RE\z/;
  return $tree;
}

sub tree_pathspec_prefix_conflict {
  my ($left, $right) = @_;
  use bytes;
  return index($left, "$right/") == 0
    || index($right, "$left/") == 0;
}

sub exact_tree_entries {
  my ($root, $commit, $paths, $label) = @_;
  fatal("$label commit malformed") unless $commit =~ /\A$OID_RE\z/;
  fatal("$label path count exceeds cap") if @$paths > $MAX_LOOKUP_PATHS;
  my (%wanted, @wanted);
  for my $path (@$paths) {
    safe_rel($path, "$label path");
    next if $wanted{$path}++;
    fatal("$label path exceeds lookup byte cap: $path")
      if length($path) + 1 > $MAX_LOOKUP_ARG_BYTES;
    push @wanted, $path;
  }
  @wanted = sort { use bytes; $a cmp $b } @wanted;

  my %entry;
  while (@wanted) {
    my @batch;
    my $bytes = 0;
    while (@wanted && @batch < $MAX_LOOKUP_BATCH) {
      my $path = $wanted[0];
      my $next = length($path) + 1;
      my $prefix_conflict = grep {
        tree_pathspec_prefix_conflict($path, $_)
      } @batch;
      last if @batch && $prefix_conflict;
      last if @batch && $bytes + $next > $MAX_LOOKUP_ARG_BYTES;
      $bytes += $next;
      push @batch, shift @wanted;
    }
    fatal("$label lookup batching failed") unless @batch;
    my $raw = git_capture($root,
      $MAX_LOOKUP_ARG_BYTES + $MAX_LOOKUP_BATCH * 128 + 1,
      '--literal-pathspecs', 'ls-tree', '-z', '--full-tree', $commit, '--', @batch);
    my @record;
    if (length($raw)) {
      @record = split /\x00/, $raw, -1;
      fatal("$label Git tree listing is not NUL terminated") unless pop(@record) eq q{};
    }
    my %batch = map { $_ => 1 } @batch;
    for my $record (@record) {
      my ($mode, $type, $oid, $path) =
        $record =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t(.*)\z/s;
      fatal("$label Git tree record malformed") unless defined($path);
      fatal("$label Git tree returned an unrequested path") unless $batch{$path};
      fatal("$label Git tree entry type/mode tuple unsupported: $path")
        unless ($type eq 'blob'
            && ($mode eq '100644' || $mode eq '100755' || $mode eq '120000'))
          || ($type eq 'commit' && $mode eq '160000')
          || ($type eq 'tree' && $mode eq '040000');
      fatal("$label Git tree path duplicated: $path") if exists($entry{$path});
      $entry{$path} = { mode => $mode, type => $type, oid => $oid };
    }
  }
  return \%entry;
}

sub select_regular_entries {
  my ($entries, $paths, $label) = @_;
  my (%selected, %seen);
  for my $path (sort { use bytes; $a cmp $b } @$paths) {
    fatal("$label path duplicated: $path") if $seen{$path}++;
    fatal("$label path absent from checkpoint: $path") unless exists($entries->{$path});
    my $entry = $entries->{$path};
    fatal("$label path is not a regular executable/data blob: $path")
      unless $entry->{type} eq 'blob'
        && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
    $selected{$path} = $entry;
  }
  return \%selected;
}

sub cat_blobs {
  my ($root, $entries, $total_limit, $label) = @_;
  my %wanted = map { $entries->{$_}{oid} => 1 } keys %$entries;
  my (%blob, %size);
  for my $oid (sort keys %wanted) {
    my $type = exact_line(git_capture($root, 128, 'cat-file', '-t', $oid), 'blob type');
    fatal('tree entry does not name a blob') unless $type eq 'blob';
    my $bytes = exact_line(git_capture($root, 128, 'cat-file', '-s', $oid), 'blob size');
    fatal('tree entry blob size malformed') unless valid_uint($bytes);
    fatal('snapshot blob exceeds 16 MiB') if $bytes > $MAX_FILE;
    $size{$oid} = $bytes;
  }
  my $total = 0;
  for my $path (sort { use bytes; $a cmp $b } keys %$entries) {
    $total += $size{$entries->{$path}{oid}};
    fatal("$label exceeds 128 MiB") if $total > $total_limit;
  }
  for my $oid (sort keys %wanted) {
    my $raw = git_capture($root, $size{$oid} + 1, 'cat-file', 'blob', $oid);
    fatal('tree entry blob size changed') unless length($raw) == $size{$oid};
    $blob{$oid} = $raw;
  }
  return \%blob;
}

sub dataset_manifest {
  my ($paths, $entries, $blobs) = @_;
  my $manifest = "HARNESS-PERFORMANCE-DATASET-V1\n";
  my @rows;
  for my $path (@$paths) {
    fatal("dataset path absent from snapshot: $path") unless exists($entries->{$path});
    my $raw = $blobs->{$entries->{$path}{oid}};
    fatal("dataset bytes absent from snapshot: $path") unless defined($raw);
    my $row = { path => $path, mode => $entries->{$path}{mode},
      size => length($raw), sha => sha256_hex($raw) };
    push @rows, $row;
    $manifest .= join("\t", 'F', @$row{qw(path mode size sha)}) . "\n";
  }
  return (sha256_hex($manifest), \@rows);
}

sub performance_manifest {
  my ($spec, $entries, $blobs) = @_;
  my $path = "$spec/performance-manifest-v1.tsv";
  fatal('performance manifest is absent from checkpoint C') unless exists($entries->{$path});
  fatal('performance manifest must be a 100644 checkpoint blob')
    unless $entries->{$path}{mode} eq '100644';
  my $raw = $blobs->{$entries->{$path}{oid}};
  fatal('performance manifest blob unavailable') unless defined($raw);
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('performance manifest is not UTF-8');
  fatal('performance manifest contains control bytes')
    if $raw =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
  # Paths stay canonical UTF-8 bytes after validation.  Git tree keys and all scope digests are
  # byte authorities; upgrading only the manifest side to Perl characters would split identity.
  my @line = split /\n/, $raw, -1;
  fatal('performance manifest must end with one LF') unless pop(@line) eq q{};
  fatal('performance manifest schema line mismatch')
    unless @line && shift(@line) eq "schema\tperformance-manifest-v1";
  fatal('performance manifest row count exceeds cap') if @line > $MAX_MANIFEST_ROWS;
  my (%workload, %nonimpact, %seen);
  my $dataset_rows = 0;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('performance manifest empty/malformed row') unless @c >= 3;
    my $kind = $c[0];
    if ($kind eq 'N') {
      fatal('performance non-measured scope row malformed') unless @c == 3;
      my (undef, $scope_path, $reason_class) = @c;
      safe_rel($scope_path, 'performance non-measured scope path');
      fatal("performance non-measured scope reason class malformed: $scope_path")
        unless $reason_class =~ /\A$REASON_CLASS_RE\z/;
      fatal("performance non-measured scope path duplicated: $scope_path")
        if exists($nonimpact{$scope_path});
      $nonimpact{$scope_path} = $reason_class;
      next;
    }
    my $id = $c[1];
    fatal('performance manifest workload ID malformed') unless $id =~ /\A$WORKLOAD_RE\z/;
    if ($kind eq 'W') {
      fatal("performance workload duplicated: $id") if $seen{"W\0$id"}++;
      fatal("performance workload row malformed: $id") unless @c == 12;
      my (undef, undef, $requirement, $test, $mode, $repetitions, $variance,
        $absolute, $regression, $metric, $unit, $environment) = @c;
      fatal("performance workload requirement/test malformed: $id")
        unless $requirement =~ /\A$REQ_RE\z/ && $test =~ /\A$TEST_RE\z/;
      fatal("performance workload mode malformed: $id")
        unless $mode eq 'comparative' || $mode eq 'new-component';
      valid_uint($repetitions) && $repetitions >= 3 && $repetitions <= 21
        && $repetitions % 2 == 1 or fatal("performance repetitions malformed: $id");
      valid_uint($variance) && $variance <= 1_000_000
        or fatal("performance variance budget malformed: $id");
      valid_uint($absolute) && $absolute > 0 && $absolute <= $TIMEOUT * 1_000_000
        or fatal("performance absolute budget malformed: $id");
      if ($mode eq 'comparative') {
        valid_uint($regression) && $regression <= 1_000_000
          or fatal("performance regression budget malformed: $id");
      } else {
        fatal("new-component regression budget must be -: $id") unless $regression eq q{-};
      }
      fatal("performance metric/unit/environment mismatch: $id")
        unless $metric eq 'wall-clock' && $unit eq 'us'
          && $environment eq 'trusted-host-process-v1';
      $workload{$id}{meta} = {
        requirement => $requirement, test => $test, mode => $mode,
        repetitions => $repetitions, variance => $variance, absolute => $absolute,
        regression => $regression, metric => $metric, unit => $unit,
        environment => $environment,
      };
      next;
    }
    if ($kind eq 'C') {
      fatal("performance measured-scope C row malformed: $id") unless @c == 4;
      my ($covered_path, $impact_class) = @c[2,3];
      safe_rel($covered_path, 'performance covered path');
      fatal("performance impact class malformed: $id/$covered_path")
        unless $impact_class =~ /\A$IMPACT_CLASS_RE\z/;
      fatal('performance manifest cannot cover its own authority blob')
        if $covered_path eq $path;
      fatal("performance covered path duplicated: $id/$covered_path")
        if $seen{"C\0$id\0$covered_path"}++;
      push @{$workload{$id}{coverage}}, $covered_path;
      $workload{$id}{impact}{$covered_path} = $impact_class;
      next;
    }
    if ($kind eq 'A') {
      fatal("performance argv row malformed: $id") unless @c == 5;
      my ($index, $size, $hex) = @c[2,3,4];
      valid_uint($index) && valid_uint($size) or fatal("performance argv integer malformed: $id");
      fatal("performance argv index exceeds cap: $id/$index") if $index >= $MAX_ARGC;
      fatal("performance argv hex malformed: $id") unless $hex =~ /\A(?:[0-9a-f]{2})*\z/;
      my $arg = pack('H*', $hex);
      fatal("performance argv size/control mismatch: $id")
        unless length($arg) == $size && $arg !~ /[\x00-\x1f\x7f]/;
      fatal("performance argv index duplicated: $id/$index") if $seen{"A\0$id\0$index"}++;
      $workload{$id}{argv}[$index] = { index => $index, size => $size, hex => $hex, raw => $arg };
      next;
    }
    if ($kind eq 'D') {
      fatal('performance manifest dataset row count exceeds cap')
        if ++$dataset_rows > $MAX_DATASET_ROWS;
      fatal("performance dataset row malformed: $id") unless @c == 6;
      my ($dataset, $mode, $size, $sha) = @c[2,3,4,5];
      safe_rel($dataset, 'performance dataset path');
      fatal('performance manifest cannot dataset-bind its own authority blob')
        if $dataset eq $path;
      fatal("performance dataset mode/integer/digest malformed: $id/$dataset")
        unless ($mode eq '100644' || $mode eq '100755') && valid_uint($size)
          && $sha =~ /\A$ROOT_RE\z/;
      fatal("performance dataset duplicated: $id/$dataset") if $seen{"D\0$id\0$dataset"}++;
      push @{$workload{$id}{dataset}}, {
        path => $dataset, mode => $mode, size => $size, sha => $sha,
      };
      next;
    }
    fatal("unknown performance manifest record kind: $kind");
  }
  fatal('performance manifest has no workloads') unless keys %workload;
  fatal('performance manifest workload count exceeds cap')
    if keys(%workload) > $MAX_WORKLOADS;
  my $canonical = "schema\tperformance-manifest-v1\n";
  my $measured_runs = 0;
  for my $id (sort keys %workload) {
    my $w = $workload{$id};
    fatal("performance workload definition missing: $id") unless $w->{meta};
    fatal("performance workload measured C path missing: $id") unless @{$w->{coverage} // []};
    fatal("performance workload argv missing: $id") unless @{$w->{argv} // []};
    fatal("performance workload dataset missing: $id") unless @{$w->{dataset} // []};
    for my $i (0 .. $#{$w->{argv}}) {
      fatal("performance argv index is not contiguous: $id/$i")
        unless defined($w->{argv}[$i]) && $w->{argv}[$i]{index} == $i;
    }
    my $m = $w->{meta};
    $measured_runs += $m->{repetitions} * ($m->{mode} eq 'comparative' ? 2 : 1)
      + scalar(@{$w->{coverage}});
    fatal('performance manifest measured-run count exceeds cap')
      if $measured_runs > $MAX_MEASURED_RUNS;
    $canonical .= join("\t", 'W', $id, @$m{qw(requirement test mode repetitions variance
      absolute regression metric unit environment)}) . "\n";
    for my $covered (sort { use bytes; $a cmp $b } @{$w->{coverage}}) {
      $canonical .= join("\t", 'C', $id, $covered, $w->{impact}{$covered}) . "\n";
    }
    for my $a (@{$w->{argv}}) {
      $canonical .= join("\t", 'A', $id, @$a{qw(index size hex)}) . "\n";
    }
    for my $d (sort { use bytes; $a->{path} cmp $b->{path} } @{$w->{dataset}}) {
      $canonical .= join("\t", 'D', $id, @$d{qw(path mode size sha)}) . "\n";
    }
    $w->{id} = $id;
  }
  for my $scope_path (sort { use bytes; $a cmp $b } keys %nonimpact) {
    $canonical .= join("\t", 'N', $scope_path, $nonimpact{$scope_path}) . "\n";
  }
  fatal('performance manifest rows are not in canonical order') unless $canonical eq $raw;
  my $scope_preimage = "HARNESS-PERFORMANCE-SCOPE-V1\n";
  my $c_count = 0;
  for my $id (sort { use bytes; $a cmp $b } keys %workload) {
    for my $covered (sort { use bytes; $a cmp $b } @{$workload{$id}{coverage}}) {
      $scope_preimage .= join("\t", 'C', $id, $covered,
        $workload{$id}{impact}{$covered}) . "\n";
      ++$c_count;
    }
  }
  $scope_preimage .= join("\t", 'N', $_, $nonimpact{$_}) . "\n"
    for sort { use bytes; $a cmp $b } keys %nonimpact;
  return {
    manifest_sha => sha256_hex($raw),
    all_workloads => \%workload,
    nonimpact => \%nonimpact,
    scope_root => sha256_hex($scope_preimage),
    c_count => $c_count,
    n_count => scalar(keys %nonimpact),
  };
}

sub performance_execution_paths {
  my ($manifest, $mode) = @_;
  my %path;
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    my $workload = $manifest->{all_workloads}{$id};
    next if defined($mode) && $workload->{meta}{mode} ne $mode;
    $path{$_->{path}} = 1 for @{$workload->{dataset}};
  }
  return [sort { use bytes; $a cmp $b } keys %path];
}

sub performance_coverage_paths {
  my ($manifest) = @_;
  my %path;
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    $path{$_} = 1 for @{$manifest->{all_workloads}{$id}{coverage}};
  }
  return [sort { use bytes; $a cmp $b } keys %path];
}

sub performance_argv_lookup_paths {
  my ($manifest) = @_;
  my %path;
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    for my $arg (@{$manifest->{all_workloads}{$id}{argv}}) {
      my $raw = $arg->{raw};
      next unless canonical_rel_candidate($raw);
      $path{$raw} = 1;
    }
  }
  return [sort { use bytes; $a cmp $b } keys %path];
}

sub validate_performance_dataset_entries {
  my ($manifest, $entries) = @_;
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    for my $dataset (@{$manifest->{all_workloads}{$id}{dataset}}) {
      my $path = $dataset->{path};
      fatal("performance dataset absent from checkpoint: $path")
        unless exists($entries->{$path});
      my $entry = $entries->{$path};
      fatal("performance dataset is not a regular blob: $path")
        unless $entry->{type} eq 'blob'
          && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
      fatal("performance dataset checkpoint mode mismatch: $path")
        unless $entry->{mode} eq $dataset->{mode};
    }
  }
}

sub bind_performance_datasets {
  my ($manifest, $entries, $blobs) = @_;
  validate_performance_dataset_entries($manifest, $entries);
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    for my $dataset (@{$manifest->{all_workloads}{$id}{dataset}}) {
      my $path = $dataset->{path};
      fatal("performance dataset absent from checkpoint: $path")
        unless exists($entries->{$path})
          && $entries->{$path}{type} eq 'blob'
          && $entries->{$path}{mode} eq $dataset->{mode};
      my $bytes = $blobs->{$entries->{$path}{oid}};
      fatal("performance dataset bytes unavailable: $path") unless defined($bytes);
      fatal("performance dataset checkpoint digest mismatch: $path")
        unless length($bytes) == $dataset->{size}
          && sha256_hex($bytes) eq $dataset->{sha};
    }
  }
}

sub bind_workload_test_manifest {
  my ($spec, $workload, $entries, $blobs) = @_;
  my $path = "$spec/test-manifest-v2.tsv";
  fatal('performance workload requires test-manifest-v2.tsv in checkpoint C')
    unless exists($entries->{$path}) && $entries->{$path}{mode} eq '100644';
  my $raw = $blobs->{$entries->{$path}{oid}};
  fatal('test-manifest-v2 blob unavailable') unless defined($raw);
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('test-manifest-v2 is not UTF-8');
  my @line = split /\n/, $raw, -1;
  fatal('test-manifest-v2 must end with one LF') unless pop(@line) eq q{};
  fatal('test-manifest-v2 header mismatch') unless shift(@line) eq "test\trole\tpath";
  fatal('test-manifest-v2 row count exceeds cap')
    if @line > $MAX_TEST_MANIFEST_ROWS;
  my %input;
  for my $line (@line) {
    my ($test, $role, $repo_path) = split /\t/, $line, -1;
    fatal('test-manifest-v2 row malformed')
      unless defined($repo_path) && $test =~ /\A$TEST_RE\z/
        && $role =~ /\A(?:test-logic|sut|fixture|transitive)\z/;
    safe_rel($repo_path, 'test manifest input');
    next unless $test eq $workload->{meta}{test};
    fatal("test manifest input has conflicting roles: $repo_path")
      if exists($input{$repo_path}) && $input{$repo_path} ne $role;
    $input{$repo_path} = $role;
  }
  fatal('performance workload test has no manifest inputs') unless keys %input;
  my %dataset = map { $_->{path} => 1 } @{$workload->{dataset}};
  my @argv = map { $_->{raw} } @{$workload->{argv}};
  fatal('performance workload argv is empty') unless @argv;
  my $id = $workload->{id};
  my $first_operand;
  if ($argv[0] =~ m{\A/}) {
    fatal('unsupported performance system interpreter; use repo-local 100755 declared test-logic wrapper')
      unless $SYSTEM_INTERPRETER{$argv[0]};
    fatal("performance system interpreter requires canonical repo test-logic script: $id")
      unless @argv > 1;
    fatal("performance system interpreter options/command-string before script are forbidden: $id")
      if $argv[1] =~ /\A-/;
    fatal("absolute performance system interpreter script is forbidden: $id/argv[1]")
      if $argv[1] =~ m{\A/};
    safe_rel($argv[1], "performance system interpreter script: $id/argv[1]");
    my $entry = $entries->{$argv[1]};
    fatal("performance system interpreter script is not a regular checkpoint blob: $id/$argv[1]")
      unless defined($entry) && $entry->{type} eq 'blob'
        && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
    fatal("performance repo-relative argv lacks exact D binding: $argv[1]")
      unless $dataset{$argv[1]};
    fatal("performance argv code path is not same-TestId test-logic: $id/$argv[1]")
      unless ($input{$argv[1]} // q{}) eq 'test-logic';
    $first_operand = 2;
  } else {
    safe_rel($argv[0], "performance repo executable: $id/argv[0]");
    my $entry = $entries->{$argv[0]};
    fatal("repo performance executable is not a 100755 checkpoint blob: $id/$argv[0]")
      unless defined($entry) && $entry->{type} eq 'blob' && $entry->{mode} eq '100755';
    fatal("performance repo-relative argv lacks exact D binding: $argv[0]")
      unless $dataset{$argv[0]};
    fatal("performance argv code path is not same-TestId test-logic: $id/$argv[0]")
      unless ($input{$argv[0]} // q{}) eq 'test-logic';
    $first_operand = 1;
  }
  for my $i ($first_operand .. $#argv) {
    my $repo_path = $argv[$i];
    fatal("absolute performance argv operand is forbidden: $id/argv[$i]")
      if $repo_path =~ m{\A/};
    my $entry;
    if (index($repo_path, q{/}) >= 0) {
      safe_rel($repo_path, "performance slash-bearing argv operand: $id/argv[$i]");
      $entry = $entries->{$repo_path};
      fatal("performance slash-bearing argv operand is not a regular checkpoint blob: $id/$repo_path")
        unless defined($entry) && $entry->{type} eq 'blob'
          && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
    } elsif (exists($entries->{$repo_path})) {
      safe_rel($repo_path, "performance checkpoint argv operand: $id/argv[$i]");
      $entry = $entries->{$repo_path};
      fatal("performance argv operand is not a regular checkpoint blob: $id/$repo_path")
        unless $entry->{type} eq 'blob'
          && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
    } else {
      next;
    }
    fatal("performance repo-relative argv lacks exact D binding: $repo_path")
      unless $dataset{$repo_path};
    fatal("performance argv path is not declared under the workload TestId: $id/$repo_path")
      unless exists($input{$repo_path});
  }
  for my $d (@{$workload->{dataset}}) {
    fatal("performance dataset is not declared under the workload TestId: $d->{path}")
      unless exists($input{$d->{path}});
  }
  for my $path (@{$workload->{coverage}}) {
    fatal("performance C path is not declared under the workload TestId: $path")
      unless exists($input{$path});
    fatal("performance C path is not a same-TestId SUT: $path")
      unless $input{$path} eq 'sut';
    fatal("performance C path lacks exact D binding: $path")
      unless $dataset{$path};
  }
}

sub validate_workload_partition {
  my ($spec, $all, $nonimpact, $entries, $blobs) = @_;
  my $path = "$spec/implementation-map.tsv";
  fatal('performance workloads require implementation-map.tsv in checkpoint C')
    unless exists($entries->{$path}) && $entries->{$path}{mode} eq '100644';
  my $raw = $blobs->{$entries->{$path}{oid}};
  fatal('implementation map blob unavailable') unless defined($raw);
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('implementation map is not UTF-8');
  my @line = split /\n/, $raw, -1;
  fatal('implementation map must end with one LF') unless pop(@line) eq q{};
  fatal('implementation map header mismatch')
    unless @line && shift(@line) eq "requirement\tdecision\ttest\tpath";
  my %mapped;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('implementation map row malformed')
      unless @c == 4 && $c[0] =~ /\A$REQ_RE\z/
        && $c[1] =~ /\AAD-[0-9]{3}\z/ && $c[2] =~ /\A$TEST_RE\z/;
    safe_rel($c[3], 'implementation map path');
    fatal("implementation map path duplicated: $c[3]") if exists($mapped{$c[3]});
    $mapped{$c[3]} = { requirement => $c[0], test => $c[2] };
  }
  fatal('implementation map has no paths') unless keys %mapped;

  my (%covered, %assigned);
  for my $id (sort keys %$all) {
    my $workload = $all->{$id};
    for my $covered_path (@{$workload->{coverage}}) {
      fatal("performance measured C scope overlaps: $covered_path")
        if exists($covered{$covered_path}) || exists($nonimpact->{$covered_path});
      fatal("performance workload covers path outside implementation map: $covered_path")
        unless exists($mapped{$covered_path});
      fatal("performance workload requirement/test does not own covered path: $id/$covered_path")
        unless $mapped{$covered_path}{requirement} eq $workload->{meta}{requirement}
          && $mapped{$covered_path}{test} eq $workload->{meta}{test};
      $covered{$covered_path} = $id;
      $assigned{$covered_path} = 'C';
    }
  }
  for my $scope_path (keys %$nonimpact) {
    fatal("performance non-measured scope path is outside implementation map: $scope_path")
      unless exists($mapped{$scope_path});
    fatal("performance C/N scope overlaps: $scope_path") if exists($assigned{$scope_path});
    $assigned{$scope_path} = 'N';
  }
  my $self = "$spec/performance-manifest-v1.tsv";
  fatal('performance manifest self-authority must be N delivery-evidence-only')
    unless exists($nonimpact->{$self})
      && $nonimpact->{$self} eq 'delivery-evidence-only';
  fatal('performance C/N scope does not exactly partition the implementation map')
    unless keys(%assigned) == keys(%mapped)
      && !grep { !exists($assigned{$_}) } keys %mapped;
}

sub validate_workload_modes {
  my ($all, $base_entries) = @_;
  for my $id (sort { use bytes; $a cmp $b } keys %$all) {
    my $workload = $all->{$id};
    my $mode = $workload->{meta}{mode};
    for my $path (sort { use bytes; $a cmp $b } @{$workload->{coverage}}) {
      my $exists_in_base = exists($base_entries->{$path});
      fatal("new-component performance C path exists in implementation base: $id/$path")
        if $mode eq 'new-component' && $exists_in_base;
      fatal("comparative performance C path is absent from implementation base: $id/$path")
        if $mode eq 'comparative' && !$exists_in_base;
    }
  }
}

sub materialize_snapshot {
  my ($entries, $blobs) = @_;
  my $path = tempdir('harness-performance-snapshot.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $path) or fatal('cannot protect performance snapshot');
  my %made;
  my @dirs;
  for my $rel (sort { use bytes; $a cmp $b } keys %$entries) {
    fatal("snapshot closure contains a non-regular entry: $rel")
      unless $entries->{$rel}{type} eq 'blob'
        && ($entries->{$rel}{mode} eq '100644' || $entries->{$rel}{mode} eq '100755');
    my @part = safe_rel($rel, 'snapshot path');
    my $leaf = pop @part;
    my $dir = $path;
    my $prefix = q{};
    for my $component (@part) {
      $prefix = length($prefix) ? "$prefix/$component" : $component;
      $dir .= "/$component";
      next if $made{$prefix};
      mkdir($dir, 0700) or fatal('snapshot directory creation failed');
      $made{$prefix} = 1;
      push @dirs, $dir;
    }
    my $target = "$dir/$leaf";
    sysopen(my $fh, $target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
      or fatal('snapshot file creation failed');
    binmode($fh, q{:raw});
    my $raw = $blobs->{$entries->{$rel}{oid}};
    fatal("snapshot closure bytes unavailable: $rel") unless defined($raw);
    my $off = 0;
    while ($off < length($raw)) {
      my $n = syswrite($fh, $raw, length($raw) - $off, $off);
      fatal('snapshot file write failed') unless defined($n) && $n;
      $off += $n;
    }
    my $runtime_mode = $entries->{$rel}{mode} eq '100755' ? 0555 : 0444;
    chmod($runtime_mode, $fh) == 1 or fatal('snapshot file chmod failed');
    $fh->sync or fatal('snapshot file sync failed');
    close($fh) or fatal('snapshot file close failed');
  }
  chmod(0555, $_) or fatal('snapshot directory chmod failed') for reverse @dirs;
  chmod(0555, $path) or fatal('snapshot root chmod failed');
  return $path;
}

sub snapshot_digest {
  my ($root_path) = @_;
  my @root_named = lstat($root_path);
  fatal('performance snapshot root is unsafe')
    unless @root_named && !S_ISLNK($root_named[2]) && S_ISDIR($root_named[2])
      && ($root_named[2] & 07777) == 0555;
  sysopen(my $root_fh, $root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('performance snapshot root open failed');
  my @root_opened = stat($root_fh);
  fatal('performance snapshot root identity changed')
    unless @root_opened && inode_id(\@root_opened) eq inode_id(\@root_named);
  my (@row, $total);
  my $walk;
  $walk = sub {
    my ($dir, $rel_dir) = @_;
    chdir($dir) or fatal('snapshot directory traversal failed');
    opendir(my $dh, q{.}) or fatal('snapshot directory unreadable');
    my @name = sort { use bytes; $a cmp $b }
      grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
    closedir($dh) or fatal('snapshot directory close failed');
    for my $name (@name) {
      fatal('unsafe snapshot entry name') if $name =~ /[\/\x00-\x1f\x7f]/;
      my $rel = length($rel_dir) ? "$rel_dir/$name" : $name;
      safe_rel($rel, 'materialized snapshot path');
      chdir($dir) or fatal('snapshot directory traversal failed');
      my @named = lstat($name);
      fatal('snapshot entry vanished') unless @named;
      fatal('snapshot contains symlink') if S_ISLNK($named[2]);
      if (S_ISDIR($named[2])) {
        fatal('snapshot directory mode changed') unless ($named[2] & 07777) == 0555;
        sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
          or fatal('snapshot directory open failed');
        my @opened = stat($child);
        fatal('snapshot directory identity changed')
          unless @opened && inode_id(\@opened) eq inode_id(\@named)
            && ($opened[2] & 07777) == 0555;
        push @row, "D\t$rel\t0555\n";
        $walk->($child, $rel);
        chdir($dir) or fatal('snapshot directory traversal failed');
        my @after = stat($child); my @again = lstat($name);
        fatal('snapshot directory changed during descriptor scan')
          unless @after && @again && !S_ISLNK($again[2])
            && inode_id(\@after) eq inode_id(\@opened)
            && inode_id(\@again) eq inode_id(\@opened)
            && ($after[2] & 07777) == 0555 && ($again[2] & 07777) == 0555;
        close($child) or fatal('snapshot directory close failed');
        next;
      }
      fatal('snapshot contains non-regular or linked entry')
        unless S_ISREG($named[2]) && $named[3] == 1;
      my $mode = $named[2] & 07777;
      fatal('snapshot file mode changed') unless $mode == 0444 || $mode == 0555;
      fatal('snapshot file exceeds 16 MiB') if $named[7] > $MAX_FILE;
      sysopen(my $fh, $name, O_RDONLY | O_NOFOLLOW) or fatal('snapshot file open failed');
      my @opened = stat($fh);
      fatal('snapshot file identity changed')
        unless @opened && inode_id(\@opened) eq inode_id(\@named)
          && S_ISREG($opened[2]) && $opened[3] == 1;
      binmode($fh, q{:raw});
      my $raw = q{};
      while (1) {
        my $n = sysread($fh, my $buf, 65_536);
        fatal('snapshot file read failed') unless defined($n);
        last unless $n;
        $raw .= $buf;
        fatal('snapshot file exceeds 16 MiB') if length($raw) > $MAX_FILE;
      }
      chdir($dir) or fatal('snapshot directory traversal failed');
      my @after = stat($fh); my @again = lstat($name);
      fatal('snapshot file changed during descriptor scan')
        unless @after && @again && !S_ISLNK($again[2])
          && inode_id(\@after) eq inode_id(\@opened)
          && inode_id(\@again) eq inode_id(\@opened)
          && $after[7] == length($raw) && $again[7] == length($raw)
          && ($after[2] & 07777) == $mode && ($again[2] & 07777) == $mode;
      close($fh) or fatal('snapshot file close failed');
      $total += length($raw);
      fatal('snapshot exceeds 128 MiB') if $total > $MAX_TREE;
      push @row, join("\t", 'F', $rel, sprintf('%04o', $mode),
        length($raw), sha256_hex($raw)) . "\n";
    }
  };
  $walk->($root_fh, q{});
  my @root_after = stat($root_fh); my @root_again = lstat($root_path);
  fatal('performance snapshot root changed during descriptor scan')
    unless @root_after && @root_again && !S_ISLNK($root_again[2])
      && inode_id(\@root_after) eq inode_id(\@root_opened)
      && inode_id(\@root_again) eq inode_id(\@root_opened)
      && ($root_after[2] & 07777) == 0555 && ($root_again[2] & 07777) == 0555;
  close($root_fh) or fatal('performance snapshot root close failed');
  return sha256_hex("HARNESS-PERFORMANCE-SNAPSHOT-V1\n"
    . join(q{}, sort { use bytes; $a cmp $b } @row));
}

sub closure_identity {
  my ($entries) = @_;
  my $raw = "HARNESS-PERFORMANCE-CLOSURE-V1\n";
  for my $path (sort { use bytes; $a cmp $b } keys %$entries) {
    my $entry = $entries->{$path};
    $raw .= join("\t", 'F', $path, $entry->{mode}, $entry->{type}, $entry->{oid}) . "\n";
    fatal('performance closure identity exceeds safety cap') if length($raw) > $MAX_TREE;
  }
  return (sha256_hex($raw), $raw);
}

sub cached_snapshot {
  my ($entries, $blobs, $cache, $label) = @_;
  my ($key, $identity) = closure_identity($entries);
  if (exists($cache->{$key})) {
    fatal("$label closure digest collision") unless $cache->{$key}{identity} eq $identity;
    return $cache->{$key};
  }
  my $snapshot = materialize_snapshot($entries, $blobs);
  my $record = {
    identity => $identity,
    path => $snapshot,
    digest => snapshot_digest($snapshot),
  };
  $cache->{$key} = $record;
  return $record;
}

sub cleanup_snapshot {
  my ($path, $expected_digest) = @_;
  fatal('performance snapshot changed before cleanup')
    unless snapshot_digest($path) eq $expected_digest;
  my @root_named = lstat($path);
  fatal('performance snapshot cleanup root is unsafe')
    unless @root_named && !S_ISLNK($root_named[2]) && S_ISDIR($root_named[2])
      && ($root_named[2] & 07777) == 0555;
  sysopen(my $root_fh, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('performance snapshot cleanup root open failed');
  my @root_opened = stat($root_fh);
  fatal('performance snapshot cleanup root identity changed')
    unless @root_opened && inode_id(\@root_opened) eq inode_id(\@root_named);

  my $unlock;
  $unlock = sub {
    my ($dir) = @_;
    chdir($dir) or fatal('performance snapshot cleanup traversal failed');
    opendir(my $dh, q{.}) or fatal('performance snapshot cleanup directory unreadable');
    my @name = grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
    closedir($dh) or fatal('performance snapshot cleanup directory close failed');
    for my $name (@name) {
      fatal('unsafe performance snapshot cleanup entry name')
        if $name =~ /[\/\x00-\x1f\x7f]/;
      chdir($dir) or fatal('performance snapshot cleanup traversal failed');
      my @named = lstat($name);
      fatal('performance snapshot cleanup entry vanished') unless @named;
      fatal('performance snapshot cleanup encountered symlink') if S_ISLNK($named[2]);
      if (S_ISDIR($named[2])) {
        fatal('performance snapshot cleanup directory mode changed')
          unless ($named[2] & 07777) == 0555;
        sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
          or fatal('performance snapshot cleanup directory open failed');
        my @opened = stat($child);
        fatal('performance snapshot cleanup directory identity changed')
          unless @opened && inode_id(\@opened) eq inode_id(\@named);
        $unlock->($child);
        close($child) or fatal('performance snapshot cleanup directory descriptor close failed');
        next;
      }
      fatal('performance snapshot cleanup encountered unsafe file')
        unless S_ISREG($named[2]) && $named[3] == 1
          && (($named[2] & 07777) == 0444 || ($named[2] & 07777) == 0555);
      sysopen(my $file, $name, O_RDONLY | O_NOFOLLOW)
        or fatal('performance snapshot cleanup file open failed');
      my @opened = stat($file);
      fatal('performance snapshot cleanup file identity changed')
        unless @opened && inode_id(\@opened) eq inode_id(\@named)
          && S_ISREG($opened[2]) && $opened[3] == 1;
      chmod(0600, $file) == 1 or fatal('performance snapshot cleanup file unlock failed');
      close($file) or fatal('performance snapshot cleanup file close failed');
    }
    chmod(0700, $dir) == 1 or fatal('performance snapshot cleanup unlock failed');
  };
  $unlock->($root_fh);
  close($root_fh) or fatal('performance snapshot cleanup root close failed');
  my @unlocked = lstat($path);
  fatal('performance snapshot cleanup root changed before removal')
    unless @unlocked && !S_ISLNK($unlocked[2]) && S_ISDIR($unlocked[2])
      && inode_id(\@unlocked) eq inode_id(\@root_opened)
      && ($unlocked[2] & 07777) == 0700;
  chdir(q{/}) or fatal('performance snapshot cleanup cannot leave snapshot tree');
  my $errors;
  remove_tree($path, { safe => 1, error => \$errors });
  fatal('performance snapshot cleanup failed')
    if (defined($errors) && @$errors) || lstat($path);
}

sub close_inherited_fds {
  my ($keep) = @_;
  for my $directory (qw(/proc/self/fd /dev/fd)) {
    next unless opendir(my $dh, $directory);
    my $scanner = fileno($dh);
    my @fd = grep { /\A[0-9]+\z/ && $_ > 2 && $_ != $scanner && $_ != $keep } readdir($dh);
    closedir($dh) or return 0;
    POSIX::close($_) for @fd;
    return 1;
  }
  my $maximum = POSIX::sysconf(POSIX::_SC_OPEN_MAX());
  return 0 unless defined($maximum) && $maximum >= 3 && $maximum <= 16_777_216;
  POSIX::close($_) for grep { $_ != $keep } 3 .. $maximum - 1;
  return 1;
}

sub normalize_command {
  my ($entries, @argv) = @_;
  fatal('performance command argv is empty') unless @argv;
  fatal('performance argv count exceeds cap') if @argv > $MAX_ARGC;
  my $total = 0;
  for my $arg (@argv) {
    fatal('performance argv contains control bytes')
      if !defined($arg) || $arg =~ /[\x00-\x1f\x7f]/;
    $total += length($arg);
    fatal('performance argv exceeds byte cap') if $total > $MAX_ARG_BYTES;
  }
  if ($argv[0] =~ m{\A/}) {
    fatal('absolute performance executable is not in the portable allowlist')
      unless $SYSTEM_INTERPRETER{$argv[0]};
  } else {
    safe_rel($argv[0], 'performance executable');
    fatal('repo performance executable absent from candidate tree')
      unless exists($entries->{$argv[0]})
        && $entries->{$argv[0]}{type} eq 'blob'
        && $entries->{$argv[0]}{mode} eq '100755';
    $argv[0] = "./$argv[0]";
  }
  my $manifest = "HARNESS-PERFORMANCE-ARGV-V1\n";
  my @row;
  for my $i (0 .. $#argv) {
    my $hex = unpack('H*', $argv[$i]);
    push @row, { index => $i, size => length($argv[$i]), hex => $hex };
    $manifest .= join("\t", 'A', $i, length($argv[$i]), $hex) . "\n";
  }
  return (sha256_hex($manifest), \@row, \@argv);
}

sub aggregate_deadline_guard {
  my ($deadline) = @_;
  fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)")
    if monotonic_now() >= $deadline;
}

sub cleanup_scratch {
  my ($scratch, $scratch_fh, $opened) = @_;
  my @named = lstat($scratch);
  my @held = stat($scratch_fh);
  fatal('performance scratch identity changed before cleanup')
    unless @named && @held && !S_ISLNK($named[2]) && S_ISDIR($named[2])
      && inode_id(\@named) eq inode_id($opened) && inode_id(\@held) eq inode_id($opened)
      && $named[4] == $< && $held[4] == $<;
  chmod(0700, $scratch_fh) == 1 or fatal('performance scratch chmod before cleanup failed');
  close($scratch_fh) or fatal('performance scratch descriptor close failed');
  my @again = lstat($scratch);
  fatal('performance scratch identity changed at cleanup boundary')
    unless @again && !S_ISLNK($again[2]) && S_ISDIR($again[2])
      && inode_id(\@again) eq inode_id($opened) && ($again[2] & 07777) == 0700;
  my $errors;
  remove_tree($scratch, { safe => 1, error => \$errors });
  fatal('performance scratch cleanup failed')
    if (defined($errors) && @$errors) || lstat($scratch);
}

sub run_command {
  my ($snapshot, $argv, $aggregate_deadline, $allow_nonzero) = @_;
  aggregate_deadline_guard($aggregate_deadline);
  my $scratch = tempdir('harness-performance-run.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $scratch) or fatal('cannot protect performance scratch directory');
  sysopen(my $scratch_fh, $scratch, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('performance scratch descriptor open failed');
  my @scratch_opened = stat($scratch_fh);
  fatal('performance scratch descriptor is unsafe')
    unless @scratch_opened && S_ISDIR($scratch_opened[2])
      && ($scratch_opened[2] & 07777) == 0700 && $scratch_opened[4] == $<;
  pipe(my $out_r, my $out_w) or fatal('stdout pipe failed');
  pipe(my $err_r, my $err_w) or fatal('stderr pipe failed');
  pipe(my $setup_r, my $setup_w) or fatal('setup-status pipe failed');
  my $setup_flags = fcntl($setup_w, F_GETFD, 0);
  defined($setup_flags) && defined(fcntl($setup_w, F_SETFD, $setup_flags | FD_CLOEXEC))
    or fatal('setup-status CLOEXEC failed');
  my $started = monotonic_now();
  my $child_exited = 0;
  my ($old_chld, $exit_action) =
    install_child_exit_notification('performance process', \$child_exited);
  my $prior_alarm_mask = block_launch_alarm('performance process');
  my $pid = fork();
  unless (defined($pid)) {
    sigaction(SIGCHLD, $old_chld)
      or fatal('performance process SIGCHLD action restore failed');
    restore_launch_alarm($prior_alarm_mask, undef, 'performance process');
    fatal('performance process fork failed');
  }
  if ($pid == 0) {
    my $setup_fail = sub {
      # A one-byte record is written before every pre-exec failure.  The descriptor is CLOEXEC,
      # so a successful exec produces a clean EOF and a real workload exit 125 remains distinct.
      while (1) {
        my $written = syswrite($setup_w, "F", 1);
        last if defined($written) && $written == 1;
        next if !defined($written) && $! == EINTR;
        POSIX::_exit(125);
      }
      POSIX::_exit(125);
    };
    sigaction(SIGCHLD, $old_chld) or $setup_fail->();
    close($out_r); close($err_r); close($setup_r);
    my $child_pg = setpgid(0, 0);
    defined($child_pg) && $child_pg == 0 or $setup_fail->();
    sigprocmask(SIG_SETMASK, $prior_alarm_mask) or $setup_fail->();
    open(STDIN, '<', '/dev/null') or $setup_fail->();
    open(STDOUT, '>&', $out_w) or $setup_fail->();
    open(STDERR, '>&', $err_w) or $setup_fail->();
    close($out_w) && close($err_w) or $setup_fail->();
    %ENV = (PATH => '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL => 'C', LANG => 'C',
      TZ => 'UTC', HOME => $scratch, TMPDIR => $scratch);
    chdir($snapshot) or $setup_fail->();
    close_inherited_fds(fileno($setup_w)) or $setup_fail->();
    exec { $argv->[0] } @$argv or $setup_fail->();
  }
  my $pg_ok = setpgid($pid, $pid);
  if ((!defined($pg_ok) || $pg_ok != 0) && $! != EACCES && $! != ESRCH) {
    stop_process_group($pid);
    restore_launch_alarm($prior_alarm_mask, undef, 'performance process');
    fatal('performance process-group setup failed');
  }
  local $ACTIVE_PROCESS_GROUP = $pid;
  if (monotonic_now() >= $aggregate_deadline) {
    stop_process_group($pid);
    $ACTIVE_PROCESS_GROUP = undef;
    restore_launch_alarm($prior_alarm_mask, undef, 'performance process');
    fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)");
  }
  enter_monitor_signal_window($pid, 'performance process');
  close($out_w); close($err_w); close($setup_w);
  for my $fh ($out_r, $err_r, $setup_r) {
    my $flags = fcntl($fh, F_GETFL, 0);
    unless (defined($flags)) {
      stop_process_group($pid); $ACTIVE_PROCESS_GROUP = undef;
      fatal('pipe flag read failed');
    }
    unless (fcntl($fh, F_SETFL, $flags | O_NONBLOCK)) {
      stop_process_group($pid); $ACTIVE_PROCESS_GROUP = undef;
      fatal('pipe nonblocking setup failed');
    }
  }
  my $selector = IO::Select->new($out_r, $err_r, $setup_r);
  my %kind = (fileno($out_r) => 'stdout', fileno($err_r) => 'stderr',
    fileno($setup_r) => 'setup');
  my %data = (stdout => q{}, stderr => q{}, setup => q{});
  my ($done, $status, $timed_out, $overflow, $terminating, $descriptor_poison) =
    (0, 0, 0, 0, 0, 0);
  my $aggregate_timed_out = 0;
  my ($drain_deadline, $finished) = (0, undef);
  my $run_deadline = $started + $TIMEOUT;
  $run_deadline = $aggregate_deadline if $aggregate_deadline < $run_deadline;
  while (!$done || $selector->count) {
    if (!$done && !$terminating && monotonic_now() >= $run_deadline) {
      $aggregate_timed_out = 1 if $aggregate_deadline <= $started + $TIMEOUT;
      $timed_out = 1; kill 'TERM', -$pid; sleep 0.05; kill 'KILL', -$pid;
      $terminating = 1; $drain_deadline = monotonic_now() + 1;
    }
    if ($terminating && $selector->count && monotonic_now() >= $drain_deadline) {
      $descriptor_poison = 1;
      for my $fh ($selector->handles) { $selector->remove($fh); close($fh) }
    }
    for my $fh ($selector->can_read(0.02)) {
      my $n = sysread($fh, my $buf, 65_536);
      if (!defined($n)) {
        next if $! == EAGAIN || $! == EWOULDBLOCK || $! == EINTR;
        stop_process_group($pid); $ACTIVE_PROCESS_GROUP = undef;
        fatal('performance process output read failed');
      }
      if (!$n) { $selector->remove($fh); close($fh); next }
      my $stream = $kind{fileno($fh)};
      $data{$stream} .= $buf;
      if ($stream eq 'setup') {
        if (length($data{setup}) > 1) {
          stop_process_group($pid); $ACTIVE_PROCESS_GROUP = undef;
          fatal('performance setup-status framing invalid');
        }
        next;
      }
      if (length($data{$stream}) > $MAX_STREAM) {
        $overflow = 1; $data{$stream} = substr($data{$stream}, 0, $MAX_STREAM);
        if (!$terminating) {
          kill 'TERM', -$pid; sleep 0.05; kill 'KILL', -$pid;
          $terminating = 1; $drain_deadline = monotonic_now() + 1;
        }
      }
    }
    if (!$done && $child_exited) {
      # The foreground process has ended, but descendants may still retain its output pipes.
      # The unreaped group leader pins PID/PGID ownership until cleanup signals are sent.
      # A detached same-host descendant is outside this trusted-host runner's containment claim,
      # yet it must never be able to hang the verifier by keeping inherited descriptors open.
      $finished = monotonic_now();
      if (!$terminating) {
        kill 'TERM', -$pid; sleep 0.02; kill 'KILL', -$pid;
        $terminating = 1; $drain_deadline = monotonic_now() + 1;
      }
      my $reap_mask = block_launch_alarm('performance process');
      $ACTIVE_PROCESS_GROUP = undef;
      while (1) {
        my $got = waitpid($pid, 0);
        if ($got == $pid) { $status = $?; last }
        next if $got == -1 && $! == EINTR;
        sigaction(SIGCHLD, $old_chld)
          or fatal('performance process SIGCHLD action restore failed');
        restore_launch_alarm($prior_alarm_mask, undef, 'performance process');
        fatal('performance process wait failed');
      }
      $done = 1;
      $pid = undef;
      sigaction(SIGCHLD, $old_chld)
        or fatal('performance process SIGCHLD action restore failed');
      restore_launch_alarm($prior_alarm_mask, undef, 'performance process');
    }
  }
  $ACTIVE_PROCESS_GROUP = undef;
  $finished //= monotonic_now();
  my $duration = int(($finished - $started) * 1_000_000 + 0.5);
  $duration = 1 if $duration < 1;
  fatal("aggregate performance deadline exceeded (${AGGREGATE_TIMEOUT}s)")
    if $aggregate_timed_out;
  fatal('performance process timed out') if $timed_out;
  fatal('performance process output exceeded cap') if $overflow;
  fatal('performance process retained output descriptors after parent exit')
    if $descriptor_poison;
  fatal('performance process child setup/exec failed') if $data{setup} eq 'F';
  fatal('performance setup-status framing invalid') if length($data{setup});
  fatal('performance process terminated by signal') if $status & 127;
  my $exit = ($status >> 8) & 255;
  fatal("performance process exited nonzero: $exit") unless $exit == 0 || $allow_nonzero;
  my $result = { duration => $duration, exit => $exit, stdout => sha256_hex($data{stdout}),
    stderr => sha256_hex($data{stderr}) };
  cleanup_scratch($scratch, $scratch_fh, \@scratch_opened);
  return $result;
}

sub measured_run {
  my ($snapshot, $expected_digest, $argv, $aggregate_deadline) = @_;
  aggregate_deadline_guard($aggregate_deadline);
  fatal('performance snapshot changed before measured run')
    unless snapshot_digest($snapshot) eq $expected_digest;
  my $result = run_command($snapshot, $argv, $aggregate_deadline, 0);
  fatal('performance command changed its mutation-evident Git materialization')
    unless snapshot_digest($snapshot) eq $expected_digest;
  aggregate_deadline_guard($aggregate_deadline);
  return $result;
}

sub snapshot_parent_for {
  my ($snapshot, $path) = @_;
  my @part = safe_rel($path, 'dependency probe path');
  my $leaf = pop @part;
  sysopen(my $dir, $snapshot, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('dependency probe snapshot root open failed');
  for my $component (@part) {
    chdir($dir) or fatal('dependency probe snapshot traversal failed');
    my @named = lstat($component);
    fatal('dependency probe snapshot parent is unsafe')
      unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2])
        && ($named[2] & 07777) == 0555;
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal('dependency probe snapshot parent open failed');
    my @opened = stat($next);
    fatal('dependency probe snapshot parent identity changed')
      unless @opened && inode_id(\@opened) eq inode_id(\@named);
    close($dir) or fatal('dependency probe snapshot parent close failed');
    $dir = $next;
  }
  chdir($dir) or fatal('dependency probe snapshot parent traversal failed');
  my @target = lstat($leaf);
  fatal('dependency probe C path is not a single regular snapshot file')
    unless @target && !S_ISLNK($target[2]) && S_ISREG($target[2]) && $target[3] == 1
      && (($target[2] & 07777) == 0444 || ($target[2] & 07777) == 0555);
  return ($dir, $leaf, \@target);
}

sub sensitivity_probe {
  my ($snapshot, $expected_digest, $path, $argv, $candidate_reference,
    $aggregate_deadline) = @_;
  aggregate_deadline_guard($aggregate_deadline);
  fatal('performance snapshot changed before dependency probe')
    unless snapshot_digest($snapshot) eq $expected_digest;
  my ($parent, $leaf, $target_stat) = snapshot_parent_for($snapshot, $path);
  my @parent_stat = stat($parent);
  fatal('dependency probe snapshot parent descriptor is unsafe')
    unless @parent_stat && S_ISDIR($parent_stat[2]) && ($parent_stat[2] & 07777) == 0555;

  my $quarantine = tempdir('harness-performance-probe.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $quarantine) or fatal('cannot protect dependency probe quarantine');
  sysopen(my $quarantine_fh, $quarantine, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('dependency probe quarantine descriptor open failed');
  my @quarantine_stat = stat($quarantine_fh);
  fatal('dependency probe quarantine descriptor is unsafe')
    unless @quarantine_stat && S_ISDIR($quarantine_stat[2])
      && ($quarantine_stat[2] & 07777) == 0700 && $quarantine_stat[4] == $<
      && $quarantine_stat[0] == $target_stat->[0];
  my $quarantined = "$quarantine/covered";

  chdir($parent) or fatal('dependency probe snapshot parent traversal failed');
  chmod(0755, $parent) == 1 or fatal('dependency probe snapshot parent unlock failed');
  rename($leaf, $quarantined) or fatal('dependency probe C path quarantine failed');
  chmod(0555, $parent) == 1 or fatal('dependency probe snapshot parent relock failed');
  my $result = run_command($snapshot, $argv, $aggregate_deadline, 1);

  chdir($parent) or fatal('dependency probe snapshot restore traversal failed');
  fatal('dependency probe command recreated removed C path') if lstat($leaf);
  my @parent_after = stat($parent);
  fatal('dependency probe snapshot parent changed during probe')
    unless @parent_after && inode_id(\@parent_after) eq inode_id(\@parent_stat)
      && ($parent_after[2] & 07777) == 0555;
  chmod(0755, $parent) == 1 or fatal('dependency probe snapshot parent restore unlock failed');
  rename($quarantined, $leaf) or fatal('dependency probe C path restore failed');
  chmod(0555, $parent) == 1 or fatal('dependency probe snapshot parent restore relock failed');
  my @restored = lstat($leaf);
  fatal('dependency probe C path identity changed after restore')
    unless @restored && inode_id(\@restored) eq inode_id($target_stat)
      && ($restored[2] & 07777) == ($target_stat->[2] & 07777);
  close($parent) or fatal('dependency probe snapshot parent descriptor close failed');
  cleanup_scratch($quarantine, $quarantine_fh, \@quarantine_stat);
  fatal('performance snapshot did not restore after dependency probe')
    unless snapshot_digest($snapshot) eq $expected_digest;
  aggregate_deadline_guard($aggregate_deadline);

  fatal("performance execution dependency is unproven for path: $path")
    if $result->{exit} == 0
      && $result->{stdout} eq $candidate_reference->{stdout}
      && $result->{stderr} eq $candidate_reference->{stderr};
  return { path => $path, %$result };
}

sub median {
  my (@value) = sort { $a <=> $b } @_;
  return $value[int(@value / 2)];
}

sub range_bps {
  my (@value) = sort { $a <=> $b } @_;
  my $mid = median(@value);
  fatal('performance median must be positive') unless $mid > 0;
  my $num = ($value[-1] - $value[0]) * 10_000;
  return int(($num + $mid - 1) / $mid);
}

sub raw_samples {
  my ($mode, $base_samples, $candidate_samples, $probes) = @_;
  my $raw = "HARNESS-PERFORMANCE-SAMPLES-V1\n";
  for my $series (qw(base candidate)) {
    next if $series eq 'base' && $mode ne 'comparative';
    my $samples = $series eq 'base' ? $base_samples : $candidate_samples;
    my $i = 0;
    for my $sample (@$samples) {
      ++$i;
      $raw .= join("\t", 'S', $series, $i, @$sample{qw(duration exit stdout stderr)}) . "\n";
    }
  }
  for my $probe (@$probes) {
    $raw .= join("\t", 'P', @$probe{qw(path duration exit stdout stderr)}) . "\n";
  }
  return ($raw, sha256_hex($raw));
}

sub workload_artifact {
  my (%v) = @_;
  my $base = $v{mode} eq 'comparative' ? $v{base} : q{-};
  my $base_tree = $v{mode} eq 'comparative' ? $v{base_tree} : q{-};
  my $regression = $v{mode} eq 'comparative' ? $v{regression} : q{-};
  my $base_median = $v{mode} eq 'comparative' ? $v{base_median} : q{-};
  my $base_variance = $v{mode} eq 'comparative' ? $v{base_variance} : q{-};
  my $raw = q{};
  my @meta = (
    ['Schema', 'performance-workload-result-v1'], ['Producer', 'performance-process-v1'],
    ['Producer-Version', '1'], ['Producer-SHA256', $v{producer_sha}],
    ['Workload-ID', $v{workload_id}], ['Manifest-SHA256', $v{manifest_sha}],
    ['Requirement', $v{requirement}], ['Test-ID', $v{test_id}],
    ['Mode', $v{mode}], ['Metric', 'wall-clock-us'], ['Checkpoint-C', $v{candidate}],
    ['Unit', 'us'], ['Raw-Samples-SHA256', $v{raw_samples_sha}],
    ['Scope-Root', $v{scope_root}], ['C-Path-Count', $v{c_count}],
    ['N-Path-Count', $v{n_count}],
    ['Dependency-Probe-Policy', 'execution-dependency-probe-v1'],
    ['Dependency-Probe-Count', scalar(@{$v{probes}})],
    ['Base', $base], ['Candidate-Tree', $v{candidate_tree}], ['Base-Tree', $base_tree],
    ['Implementation-Root', $v{implementation_root}],
    ['Implementation-Actor', $v{implementation_actor}],
    ['Implementation-Attempt', $v{implementation_attempt}],
    ['Reviewer-Actor', $v{review_actor}], ['Reviewer-Attempt', $v{review_attempt}],
    ['Snapshot-Policy', 'mutation-evident-git-materialization-v1'],
    ['Environment-Class', 'trusted-host-process-v1'],
    ['Environment-SHA256', sha256_hex($ENV_MANIFEST)], ['Command-SHA256', $v{command_sha}],
    ['Dataset-SHA256', $v{dataset_sha}], ['Repetitions', $v{repetitions}],
    ['Timeout-Seconds', $TIMEOUT], ['Variance-Budget-BPS', $v{variance_budget}],
    ['Absolute-Budget-Us', $v{absolute_budget}], ['Regression-Budget-BPS', $regression],
    ['Base-Median-Us', $base_median], ['Candidate-Median-Us', $v{candidate_median}],
    ['Base-Variance-BPS', $base_variance],
    ['Candidate-Variance-BPS', $v{candidate_variance}], ['Verdict', 'PASS'],
  );
  $raw .= "- $_->[0]: $_->[1]\n" for @meta;
  $raw .= "\n## Command argv\n\n| index | byte-size | hex |\n|---:|---:|---|\n";
  $raw .= "| $_->{index} | $_->{size} | $_->{hex} |\n" for @{$v{argv_rows}};
  $raw .= "\n## Dataset\n\n| path | mode | byte-size | sha256 |\n|---|---:|---:|---|\n";
  $raw .= "| $_->{path} | $_->{mode} | $_->{size} | $_->{sha} |\n"
    for @{$v{dataset_rows}};
  $raw .= "\n## Machine samples\n\n" . (q{`} x 3) . "text\n"
    . $v{raw_samples} . (q{`} x 3) . "\n";
  fatal('performance workload artifact exceeds derived-artifact hard cap')
    if length($raw) > $MAX_DERIVED_ARTIFACT;
  return $raw;
}

sub aggregate_samples_sha {
  my ($result) = @_;
  my $manifest = "HARNESS-PERFORMANCE-AGGREGATE-SAMPLES-V1\n";
  for my $row (@$result) {
    $manifest .= join("\t", 'W', $row->{workload_id}, $row->{raw_samples_sha}) . "\n";
  }
  return sha256_hex($manifest);
}

sub aggregate_artifact {
  my (%v) = @_;
  my $raw = "# Performance process review v1\n\n";
  my @meta = (
    ['Schema', 'performance-process-review-v1'], ['Producer', 'performance-process-v1'],
    ['Producer-Version', '1'], ['Producer-SHA256', $v{producer_sha}],
    ['Manifest-SHA256', $v{manifest_sha}], ['Workload-Count', scalar(@{$v{result}})],
    ['Raw-Samples-SHA256', $v{raw_samples_sha}], ['Checkpoint-C', $v{candidate}],
    ['Scope-Root', $v{scope_root}], ['C-Path-Count', $v{c_count}],
    ['N-Path-Count', $v{n_count}],
    ['Aggregate-Timeout-Seconds', $AGGREGATE_TIMEOUT],
    ['Dependency-Probe-Policy', 'execution-dependency-probe-v1'],
    ['Candidate-Tree', $v{candidate_tree}],
    ['Implementation-Root', $v{implementation_root}],
    ['Implementation-Actor', $v{implementation_actor}],
    ['Implementation-Attempt', $v{implementation_attempt}],
    ['Reviewer-Actor', $v{review_actor}], ['Reviewer-Attempt', $v{review_attempt}],
    ['Snapshot-Policy', 'mutation-evident-git-materialization-v1'],
    ['Environment-Class', 'trusted-host-process-v1'],
    ['Environment-SHA256', sha256_hex($ENV_MANIFEST)], ['Verdict', 'PASS'],
  );
  $raw .= "- $_->[0]: $_->[1]\n" for @meta;
  $raw .= "\n";
  for my $row (@{$v{result}}) {
    $raw .= "## Workload $row->{workload_id}\n\n" . $row->{artifact};
    fatal('performance aggregate artifact exceeds derived-artifact hard cap')
      if length($raw) > $MAX_DERIVED_ARTIFACT;
  }
  return $raw;
}

sub run_workload {
  my (%v) = @_;
  my $workload = $v{workload};
  my $meta = $workload->{meta};
  my $mode = $meta->{mode};
  my $base = $mode eq 'comparative' ? $v{implementation}{base} : q{-};
  my $repetitions = $meta->{repetitions};
  my $variance_budget = $meta->{variance};
  my $absolute_budget = $meta->{absolute};
  my $regression_budget = $meta->{regression};
  my $datasets = [map { $_->{path} } @{$workload->{dataset}}];
  my $candidate_closure_entries = select_regular_entries(
    $v{candidate_entries}, $datasets,
    "performance candidate execution closure for $v{workload_id}");
  my %snapshot_cache;
  my $candidate_materialization = cached_snapshot(
    $candidate_closure_entries, $v{candidate_blobs}, \%snapshot_cache,
    "performance candidate execution closure for $v{workload_id}");
  my ($base_tree, $base_entries, $base_blobs, $base_snapshot, $base_snapshot_digest) =
    (q{-}, undef, undef, undef, undef);
  if ($mode eq 'comparative') {
    aggregate_deadline_guard($v{aggregate_deadline});
    $base_tree = $v{base_tree};
    $base_entries = $v{base_entries};
    $base_blobs = $v{base_blobs};
    my $base_closure_entries = select_regular_entries(
      $base_entries, $datasets,
      "performance base execution closure for $v{workload_id}");
    my $base_materialization = cached_snapshot(
      $base_closure_entries, $base_blobs, \%snapshot_cache,
      "performance base execution closure for $v{workload_id}");
    $base_snapshot = $base_materialization->{path};
    $base_snapshot_digest = $base_materialization->{digest};
    aggregate_deadline_guard($v{aggregate_deadline});
  }

  my ($candidate_dataset_sha, $dataset_rows) =
    dataset_manifest($datasets, $v{candidate_entries}, $v{candidate_blobs});
  my @argv_input = map { $_->{raw} } @{$workload->{argv}};
  my ($command_sha, $argv_rows, $argv) =
    normalize_command($v{candidate_entries}, @argv_input);
  if ($mode eq 'comparative') {
    my %covered = map { $_ => 1 } @{$workload->{coverage}};
    my $stable_datasets = [grep { !$covered{$_} } @$datasets];
    my ($candidate_stable_dataset_sha) =
      dataset_manifest($stable_datasets, $v{candidate_entries}, $v{candidate_blobs});
    my ($base_dataset_sha) = dataset_manifest($stable_datasets, $base_entries, $base_blobs);
    fatal("comparative base and candidate datasets differ: $v{workload_id}")
      unless $base_dataset_sha eq $candidate_stable_dataset_sha;
    if ($argv_input[0] !~ m{\A/}) {
      fatal("repo performance executable absent from base tree: $v{workload_id}")
        unless exists($base_entries->{$argv_input[0]})
          && $base_entries->{$argv_input[0]}{mode} eq '100755';
    }
  }

  my (@base_samples, @candidate_samples);
  for my $i (1 .. $repetitions) {
    my @series = $mode eq 'comparative'
      ? ($i % 2 ? qw(base candidate) : qw(candidate base))
      : qw(candidate);
    for my $series (@series) {
      my $sample = $series eq 'base'
        ? measured_run($base_snapshot, $base_snapshot_digest, $argv,
            $v{aggregate_deadline})
        : measured_run($candidate_materialization->{path},
            $candidate_materialization->{digest}, $argv,
            $v{aggregate_deadline});
      push @{$series eq 'base' ? \@base_samples : \@candidate_samples}, $sample;
    }
  }
  for my $series ([$mode eq 'comparative' ? \@base_samples : (), 'base'],
      [\@candidate_samples, 'candidate']) {
    next unless ref($series->[0]);
    my ($samples, $label) = @$series;
    fatal("$v{workload_id} $label sample count mismatch") unless @$samples == $repetitions;
    my $stdout = $samples->[0]{stdout}; my $stderr = $samples->[0]{stderr};
    for my $sample (@$samples) {
      fatal("$v{workload_id} $label output is not stable across repetitions")
        unless $sample->{stdout} eq $stdout && $sample->{stderr} eq $stderr;
      fatal("$v{workload_id} $label sample exceeds absolute performance budget")
        if $sample->{duration} > $absolute_budget;
    }
  }
  if ($mode eq 'comparative') {
    fatal("comparative base and candidate outputs differ: $v{workload_id}")
      unless $base_samples[0]{stdout} eq $candidate_samples[0]{stdout}
        && $base_samples[0]{stderr} eq $candidate_samples[0]{stderr};
  }
  my @probes;
  for my $path (sort { use bytes; $a cmp $b } @{$workload->{coverage}}) {
    my $probe = sensitivity_probe(
      $candidate_materialization->{path}, $candidate_materialization->{digest}, $path, $argv,
      $candidate_samples[0], $v{aggregate_deadline});
    fatal("$v{workload_id} dependency probe exceeds absolute performance budget: $path")
      if $probe->{duration} > $absolute_budget;
    push @probes, $probe;
  }
  my $candidate_median = median(map { $_->{duration} } @candidate_samples);
  my $candidate_variance = range_bps(map { $_->{duration} } @candidate_samples);
  fatal("candidate variance exceeds declared budget: $v{workload_id}")
    if $candidate_variance > $variance_budget;
  fatal("candidate median exceeds absolute performance budget: $v{workload_id}")
    if $candidate_median > $absolute_budget;
  my ($base_median, $base_variance) = (q{-}, q{-});
  if ($mode eq 'comparative') {
    $base_median = median(map { $_->{duration} } @base_samples);
    $base_variance = range_bps(map { $_->{duration} } @base_samples);
    fatal("base variance exceeds declared budget: $v{workload_id}")
      if $base_variance > $variance_budget;
    fatal("candidate regression exceeds declared budget: $v{workload_id}")
      if $candidate_median > $base_median
        && ($candidate_median - $base_median) * 10_000
          > $base_median * $regression_budget;
  }

  my ($raw_samples, $raw_samples_sha) =
    raw_samples($mode, \@base_samples, \@candidate_samples, \@probes);
  my $artifact = workload_artifact(
    mode => $mode, candidate => $v{candidate}, base => $base,
    candidate_tree => $v{candidate_tree}, base_tree => $base_tree,
    implementation_root => $v{implementation}{root},
    implementation_actor => $v{implementation}{actor},
    implementation_attempt => $v{implementation}{attempt},
    review_actor => $v{receipt}{actor}, review_attempt => $v{receipt}{attempt},
    producer_sha => $v{producer_sha}, workload_id => $v{workload_id},
    manifest_sha => $v{manifest_sha}, requirement => $meta->{requirement},
    scope_root => $v{scope_root}, c_count => $v{c_count}, n_count => $v{n_count},
    test_id => $meta->{test}, raw_samples => $raw_samples,
    raw_samples_sha => $raw_samples_sha,
    command_sha => $command_sha, argv_rows => $argv_rows,
    dataset_sha => $candidate_dataset_sha, dataset_rows => $dataset_rows,
    repetitions => $repetitions, variance_budget => $variance_budget,
    absolute_budget => $absolute_budget, regression => $regression_budget,
    base_median => $base_median, candidate_median => $candidate_median,
    base_variance => $base_variance, candidate_variance => $candidate_variance,
    base_samples => \@base_samples, candidate_samples => \@candidate_samples,
    probes => \@probes,
  );
  for my $key (sort keys %snapshot_cache) {
    cleanup_snapshot($snapshot_cache{$key}{path}, $snapshot_cache{$key}{digest});
  }
  aggregate_deadline_guard($v{aggregate_deadline});
  return {
    workload_id => $v{workload_id}, raw_samples_sha => $raw_samples_sha,
    artifact => $artifact,
  };
}

sub parse_implementation_identity {
  my ($rows, $candidate) = @_;
  my ($generation, $active, $bound) = (0, undef, undef);
  for my $row (@$rows) {
    my ($event, $detail) = @$row;
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=($UINT_RE);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      my ($next, $scopes) = ($1, $2);
      fatal('receipt generation is not monotonic') unless $next == $generation + 1;
      $generation = $next;
      if (grep { $_ eq 'implementation' } split /,/, $scopes) { $active = undef; $bound = undef }
      next;
    }
    if ($event eq 'implementation-start') {
      $detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($ROOT_RE);capability=implementation-v1;base=($OID_RE)\z/
        or fatal('non-canonical implementation-start detail');
      fatal('implementation lifecycle already active') if defined($active);
      fatal('implementation-start is not in current generation') unless $2 == $generation;
      $active = { attempt => $1, generation => $2, actor => $3, design => $4, base => $5 };
      next;
    }
    if ($event eq 'implementation-bind') {
      $detail =~ /\Aroot=($ROOT_RE);base=($OID_RE);design=($ROOT_RE);attempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE)\z/
        or fatal('non-canonical implementation-bind detail');
      fatal('implementation-bind has no matching start') unless defined($active);
      my %v = (root => $1, base => $2, design => $3, attempt => $4,
        generation => $5, actor => $6);
      for my $key (qw(base design attempt generation actor)) {
        fatal("implementation-bind $key mismatch") unless $v{$key} eq $active->{$key};
      }
      fatal('implementation-bind duplicated') if defined($bound);
      $bound = \%v;
    }
  }
  fatal('current implementation identity is not bound') unless defined($active) && defined($bound);
  return { %$active, root => $bound->{root} };
}

sub optional_lstat {
  my ($name, $label) = @_;
  local $! = 0;
  my @named = lstat($name);
  return \@named if @named;
  fatal("$label lstat failed") unless $! == ENOENT;
  return undef;
}

sub review_directory_is_canonical {
  my ($root, $part, $expected_id) = @_;
  my @root_opened = stat($root->{fh});
  my @root_named = lstat($root->{abs});
  return 0 unless @root_opened && @root_named && !S_ISLNK($root_named[2])
    && S_ISDIR($root_opened[2]) && S_ISDIR($root_named[2])
    && inode_id(\@root_opened) eq $root->{id}
    && inode_id(\@root_named) eq $root->{id};
  chdir($root->{fh}) or return 0;
  my $dir = $root->{fh};
  my @hold = ($dir);
  for my $component (@$part) {
    chdir($dir) or return 0;
    my @named = lstat($component);
    return 0 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or return 0;
    my @opened = stat($next);
    return 0 unless @opened && S_ISDIR($opened[2])
      && inode_id(\@opened) eq inode_id(\@named);
    push @hold, $next;
    $dir = $next;
  }
  my @final = stat($dir);
  return @final && inode_id(\@final) eq $expected_id;
}

sub cleanup_artifact_temp {
  my $guard = $ARTIFACT_TEMP_GUARD;
  return 1 unless defined($guard);
  my $ok = chdir($guard->{dir});
  if ($ok) {
    local $! = 0;
    my @named = lstat($guard->{leaf});
    if (!@named) {
      $ok = $! == ENOENT;
    } else {
      $ok = !S_ISLNK($named[2]) && S_ISREG($named[2])
        && inode_id(\@named) eq $guard->{id}
        && unlink($guard->{leaf});
    }
  }
  $ARTIFACT_TEMP_GUARD = undef if $ok;
  return $ok ? 1 : 0;
}

sub atomic_write_artifact {
  my ($root, $spec, $artifact, $raw) = @_;
  fatal('performance aggregate artifact exceeds derived-artifact hard cap')
    if length($raw) > $MAX_DERIVED_ARTIFACT;
  aggregate_deadline_guard($AGGREGATE_DEADLINE);
  fatal('performance artifact path must be the profile canonical path')
    unless $artifact eq "$spec/reviews/performance-review.md";
  my @spec_part = safe_rel("$spec/reviews", 'performance review directory');
  check_root($root);
  chdir($root->{fh}) or fatal('repo root traversal failed');
  my $dir = $root->{fh};
  for my $component (@spec_part) {
    chdir($dir) or fatal('review directory traversal failed');
    my @named = lstat($component);
    fatal('review directory must be real')
      unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal('review directory open failed');
    my @opened = stat($next);
    fatal('review directory identity changed')
      unless @opened && inode_id(\@opened) eq inode_id(\@named);
    $dir = $next;
  }
  my @parent_opened = stat($dir);
  fatal('review directory descriptor unavailable') unless @parent_opened;
  my $parent_id = inode_id(\@parent_opened);
  fatal('review directory is no longer canonical')
    unless review_directory_is_canonical($root, \@spec_part, $parent_id);
  chdir($dir) or fatal('review directory traversal failed');
  my $target = 'performance-review.md';
  my ($old_fh, @old_opened, $old_raw);
  my $old = optional_lstat($target, 'existing performance artifact');
  if (defined($old)) {
    fatal('existing performance artifact is unsafe')
      unless !S_ISLNK($old->[2]) && S_ISREG($old->[2]) && $old->[3] == 1
        && ($old->[2] & 07777) == 0644;
    sysopen($old_fh, $target, O_RDONLY | O_NOFOLLOW)
      or fatal('existing performance artifact open failed');
    @old_opened = stat($old_fh);
    fatal('existing performance artifact identity changed')
      unless @old_opened && inode_id(\@old_opened) eq inode_id($old);
    binmode($old_fh, q{:raw});
    $old_raw = q{};
    while (1) {
      my $n = sysread($old_fh, my $buf, 65_536);
      fatal('existing performance artifact read failed') unless defined($n);
      last unless $n;
      $old_raw .= $buf;
      fatal('existing performance artifact exceeds size cap')
        if length($old_raw) > $MAX_DERIVED_ARTIFACT;
    }
  }
  my $prior_temp_alarm = block_launch_alarm('performance artifact tempfile');
  my ($fh, $tmp) = tempfile('.performance-review.XXXXXX', DIR => q{.}, UNLINK => 0);
  my @created = stat($fh); my @temp_named = lstat($tmp);
  my ($tmp_leaf) = $tmp =~ m{\A(?:\./)?(\.performance-review\.[A-Za-z0-9_]{6})\z};
  $ARTIFACT_TEMP_GUARD = {
    dir => $dir, leaf => $tmp_leaf, id => inode_id(\@created),
  } if defined($tmp_leaf) && @created;
  unless (defined($tmp_leaf) && @created && @temp_named && !S_ISLNK($temp_named[2])
      && S_ISREG($created[2]) && $created[3] == 1
      && inode_id(\@created) eq inode_id(\@temp_named)) {
    close($fh);
    if (defined($ARTIFACT_TEMP_GUARD)) {
      cleanup_artifact_temp();
    } else {
      unlink($tmp) if defined($tmp) && length($tmp);
    }
    fatal('performance artifact temp identity invalid');
  }
  restore_launch_alarm($prior_temp_alarm, undef, 'performance artifact tempfile');
  chmod(0644, $fh) == 1 or fatal('performance artifact chmod failed');
  binmode($fh, q{:raw});
  print {$fh} $raw or fatal('performance artifact write failed');
  $fh->flush or fatal('performance artifact flush failed');
  $fh->sync or fatal('performance artifact sync failed');
  defined(sysseek($fh, 0, SEEK_SET)) or fatal('performance artifact temp seek failed');
  my $confirm = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('performance artifact temp read failed') unless defined($n);
    last unless $n;
    $confirm .= $buf;
    fatal('performance artifact temp exceeds size cap')
      if length($confirm) > $MAX_DERIVED_ARTIFACT;
  }
  @temp_named = lstat($tmp);
  fatal('performance artifact temp postcondition failed')
    unless $confirm eq $raw && @temp_named && !S_ISLNK($temp_named[2])
      && S_ISREG($temp_named[2]) && $temp_named[3] == 1
      && ($temp_named[2] & 07777) == 0644
      && inode_id(\@temp_named) eq inode_id(\@created);
  close($fh) or fatal('performance artifact close failed');
  aggregate_deadline_guard($AGGREGATE_DEADLINE);
  chdir($dir) or fatal('review directory traversal failed');
  my @parent_now = stat($dir);
  @temp_named = lstat($tmp);
  fatal('review directory or performance temp changed before publish')
    unless @parent_now && inode_id(\@parent_now) eq $parent_id
      && @temp_named && !S_ISLNK($temp_named[2]) && S_ISREG($temp_named[2])
      && inode_id(\@temp_named) eq inode_id(\@created);
  fatal('review directory is no longer canonical before publish')
    unless review_directory_is_canonical($root, \@spec_part, $parent_id);
  chdir($dir) or fatal('review directory traversal failed');
  my $current = optional_lstat($target, 'performance artifact publish target');
  if (defined($old_raw)) {
    my @old_after = stat($old_fh);
    fatal('existing performance artifact changed before publish')
      unless defined($current) && @old_after && !S_ISLNK($current->[2])
        && S_ISREG($current->[2]) && inode_id($current) eq inode_id(\@old_opened)
        && inode_id(\@old_after) eq inode_id(\@old_opened)
        && $old_after[7] == length($old_raw);
    defined(sysseek($old_fh, 0, SEEK_SET))
      or fatal('existing performance artifact seek failed');
    my $old_confirm = q{};
    while (1) {
      my $n = sysread($old_fh, my $buf, 65_536);
      fatal('existing performance artifact re-read failed') unless defined($n);
      last unless $n;
      $old_confirm .= $buf;
      fatal('existing performance artifact exceeds size cap')
        if length($old_confirm) > $MAX_DERIVED_ARTIFACT;
    }
    fatal('existing performance artifact bytes changed before publish')
      unless $old_confirm eq $old_raw;
    close($old_fh) or fatal('existing performance artifact close failed');
  } else {
    fatal('performance artifact appeared before publish') if defined($current);
  }
  # Rename publishes the bytes atomically, but the authority is not durable until the already
  # descriptor-pinned reviews directory is synced.  Keep the program-start deadline armed across
  # both operations: a post-rename sync failure is an indeterminate publish that must be reconciled
  # before retry, never a terminal performance receipt.
  rename($tmp_leaf, $target) or fatal('performance artifact atomic rename failed');
  $ARTIFACT_TEMP_GUARD = undef;
  $dir->sync or fatal('performance artifact directory sync failed');
  alarm(0);
}

binmode(STDOUT, q{:raw}); binmode(STDERR, q{:raw});
enter_dedicated_runtime();
arm_aggregate_deadline();
sanitize_environment();
my $command = shift // fatal('missing command');
fatal('usage: performance-process-v1.pl run <repo> <SPEC> <attempt> <artifact> <C>')
  unless $command eq 'run' && @ARGV == 5;
my ($root_arg, $spec, $attempt, $artifact, $candidate) = @ARGV;
$spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/ or fatal('SPEC_DIR grammar mismatch');
$attempt =~ /\A$ATTEMPT_RE\z/ or fatal('performance attempt malformed');
$candidate =~ /\A$OID_RE\z/ or fatal('candidate C malformed');

my $root = open_root($root_arg);
aggregate_deadline_guard($AGGREGATE_DEADLINE);
configure_internal_git_context($root);
my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'git root');
fatal('repo root is not canonical git toplevel') unless abs_path($top) eq $root->{abs};
my $head_oid = exact_line(git_capture($root, 4096, 'rev-parse', 'HEAD'), 'HEAD');
fatal('performance candidate must equal exact HEAD checkpoint C') unless $head_oid eq $candidate;
my $candidate_tree = commit_tree($root, $candidate, 'candidate C');
aggregate_deadline_guard($AGGREGATE_DEADLINE);
my $audit_raw = read_repo_file($root, "$spec/audit.md");
my $receipt = open_performance_receipt($audit_raw, $attempt, $candidate);
my $implementation = parse_implementation_identity(audit_rows($audit_raw), $candidate);
fatal('performance reviewer actor must differ from implementation actor')
  if $receipt->{actor} eq $implementation->{actor};
fatal('performance reviewer attempt must differ from implementation attempt')
  if $receipt->{attempt} eq $implementation->{attempt};

my $manifest_path = "$spec/performance-manifest-v1.tsv";
my $manifest_lookup = exact_tree_entries(
  $root, $candidate, [$manifest_path], 'performance manifest authority');
my $manifest_entries = select_regular_entries(
  $manifest_lookup, [$manifest_path], 'performance manifest authority');
my $manifest_blobs = cat_blobs(
  $root, $manifest_entries, $MAX_FILE, 'performance manifest authority');
aggregate_deadline_guard($AGGREGATE_DEADLINE);
my $manifest = performance_manifest($spec, $manifest_entries, $manifest_blobs);
my $candidate_execution_paths = performance_execution_paths($manifest, undef);
my @authority_path = ($manifest_path, "$spec/implementation-map.tsv",
  "$spec/test-manifest-v2.tsv");
my @candidate_lookup_path = (@authority_path, @$candidate_execution_paths,
  @{performance_coverage_paths($manifest)}, @{performance_argv_lookup_paths($manifest)});
my $candidate_entries = exact_tree_entries(
  $root, $candidate, \@candidate_lookup_path, 'performance candidate authority');
my $authority_entries = select_regular_entries(
  $candidate_entries, \@authority_path, 'performance checkpoint authority');
my $authority_blobs = cat_blobs(
  $root, $authority_entries, $MAX_TREE, 'performance checkpoint authority');
validate_performance_dataset_entries($manifest, $candidate_entries);
my $candidate_execution_entries = select_regular_entries(
  $candidate_entries, $candidate_execution_paths, 'performance candidate execution closure');
my $candidate_execution_blobs = cat_blobs($root, $candidate_execution_entries, $MAX_TREE,
  'performance candidate execution closure');
my %candidate_blob = (%$authority_blobs, %$candidate_execution_blobs);
my $candidate_blobs = \%candidate_blob;
bind_performance_datasets($manifest, $candidate_entries, $candidate_blobs);
validate_workload_partition($spec, $manifest->{all_workloads},
  $manifest->{nonimpact}, $candidate_entries, $candidate_blobs);
my $base_tree = commit_tree($root, $implementation->{base}, 'performance base');
my $base_execution_paths = performance_execution_paths($manifest, 'comparative');
my @base_lookup_path = (@$base_execution_paths, @{performance_coverage_paths($manifest)});
my $base_entries = exact_tree_entries(
  $root, $implementation->{base}, \@base_lookup_path, 'performance base authority');
validate_workload_modes($manifest->{all_workloads}, $base_entries);
my $base_execution_entries = select_regular_entries(
  $base_entries, $base_execution_paths, 'performance base execution closure');
my $base_blobs = cat_blobs($root, $base_execution_entries, $MAX_TREE,
  'performance base execution closure');
for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
  aggregate_deadline_guard($AGGREGATE_DEADLINE);
  bind_workload_test_manifest($spec, $manifest->{all_workloads}{$id},
    $candidate_entries, $candidate_blobs);
}
my $producer_sha = producer_identity($root, $candidate);
aggregate_deadline_guard($AGGREGATE_DEADLINE);
my @result;
for my $workload_id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
  push @result, run_workload(
    root => $root, candidate => $candidate, candidate_tree => $candidate_tree,
    candidate_entries => $candidate_entries, candidate_blobs => $candidate_blobs,
    aggregate_deadline => $AGGREGATE_DEADLINE,
    implementation => $implementation, receipt => $receipt,
    base_tree => $base_tree, base_entries => $base_entries, base_blobs => $base_blobs,
    producer_sha => $producer_sha, manifest_sha => $manifest->{manifest_sha},
    scope_root => $manifest->{scope_root}, c_count => $manifest->{c_count},
    n_count => $manifest->{n_count},
    workload_id => $workload_id,
    workload => $manifest->{all_workloads}{$workload_id},
  );
}

fatal('audit changed during performance execution')
  unless read_repo_file($root, "$spec/audit.md") eq $audit_raw;
fatal('checkpoint C changed during performance execution')
  unless exact_line(git_capture($root, 4096, 'rev-parse', 'HEAD'), 'HEAD') eq $candidate;
fatal('performance producer changed during performance execution')
  unless producer_identity($root, $candidate) eq $producer_sha;
aggregate_deadline_guard($AGGREGATE_DEADLINE);
my $raw_samples_sha = aggregate_samples_sha(\@result);
my $artifact_raw = aggregate_artifact(
  candidate => $candidate, candidate_tree => $candidate_tree,
  implementation_root => $implementation->{root},
  implementation_actor => $implementation->{actor},
  implementation_attempt => $implementation->{attempt},
  review_actor => $receipt->{actor}, review_attempt => $receipt->{attempt},
  producer_sha => $producer_sha, manifest_sha => $manifest->{manifest_sha},
  scope_root => $manifest->{scope_root}, c_count => $manifest->{c_count},
  n_count => $manifest->{n_count},
  raw_samples_sha => $raw_samples_sha, result => \@result,
);
fatal('audit changed before performance run receipt')
  unless read_repo_file($root, "$spec/audit.md") eq $audit_raw;
my $run_prefix = join(q{;},
  "attempt=$receipt->{attempt}", "generation=$receipt->{generation}",
  "actor=$receipt->{actor}", "subject=$receipt->{subject}",
  'capability=performance-process-v1', 'workloads=' . scalar(@result),
  "manifest=$manifest->{manifest_sha}", "producer=$producer_sha");
my $artifact_sha = sha256_hex($artifact_raw);
aggregate_deadline_guard($AGGREGATE_DEADLINE);
atomic_write_artifact($root, $spec, $artifact, $artifact_raw);
print "Run-Start-Detail: $run_prefix\n";
print "Run-Finish-Detail: $run_prefix;raw-samples=$raw_samples_sha;artifact=$artifact;sha256=$artifact_sha\n";
print 'Audit-SHA256: ' . sha256_hex($audit_raw) . "\n";
print "Raw-Samples-SHA256: $raw_samples_sha\n";
print "Artifact-SHA256: $artifact_sha\n";
exit 0;
