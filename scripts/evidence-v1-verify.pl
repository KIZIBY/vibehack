#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EACCES EAGAIN ECHILD EINTR ESRCH EWOULDBLOCK);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW O_NONBLOCK FD_CLOEXEC F_GETFD F_GETFL F_SETFD F_SETFL S_ISDIR S_ISLNK S_ISREG SEEK_SET);
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use IO::Handle;
use IO::Select;
use POSIX qw(SA_NOCLDSTOP SIGALRM SIGCHLD SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK SIG_UNBLOCK setpgid sigaction sigprocmask);
use Time::HiRes qw(alarm clock_gettime CLOCK_MONOTONIC sleep);

# Pure architecture-evidence-v1 release-envelope verifier.  It binds the prospective C->H index
# to exact independent receipts, process-ground requirement/performance evidence and a closed
# Markdown-only EvidenceRoot.  Mutation and audit append remain owned by pipeline-state.sh.

my $MAX_FILE       = 16 * 1024 * 1024;
my $MAX_DERIVED_ARTIFACT = $MAX_FILE;
my $MAX_TREE       = 128 * 1024 * 1024;
my $MAX_SET        = 64 * 1024 * 1024;
my $MAX_GIT_OUTPUT = 128 * 1024 * 1024;
my $MAX_PATHS      = 100_000;
my $MAX_ARGC       = 128;
my $MAX_ARG_BYTES  = 64 * 1024;
my $MAX_WORKLOADS  = 64;
my $MAX_MEASURED_RUNS = 256;
my $MAX_MANIFEST_ROWS = 4096;
my $MAX_DATASET_ROWS = 4096;
my $MAX_TEST_MANIFEST_ROWS = 4096;
my $AGGREGATE_TIMEOUT = 600;
my $VERIFIER_TIMEOUT = 120;
my $VERIFIER_STARTED = clock_gettime(CLOCK_MONOTONIC);
my $VERIFIER_DEADLINE = $VERIFIER_STARTED + $VERIFIER_TIMEOUT;
my $MAX_UINT       = 9_007_199_254_740_991;
my $DOMAIN         = "HARNESS-EVIDENCE-ROOT-V1\n";
my $ENV_MANIFEST   = join(q{},
  "HARNESS-PERFORMANCE-ENV-V1\n",
  "PATH=/usr/bin:/bin:/usr/sbin:/sbin\n",
  "LC_ALL=C\nLANG=C\nTZ=UTC\nHOME=<isolated>\nTMPDIR=<isolated>\n");

my $OID_RE     = qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my $ROOT_RE    = qr/[0-9a-f]{64}/;
my $ATTEMPT_RE = qr/[0-9a-f]{64}/;
my $ACTOR_RE   = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $TEST_RE    = qr/T-[A-Z0-9][A-Z0-9-]{1,63}/;
my $REQ_RE     = qr/(?:FR|NFR)-[0-9]{3}/;
my $UINT_RE    = qr/(?:0|[1-9][0-9]*)/;
my $WORKLOAD_RE = qr/W-[A-Z0-9][A-Z0-9-]{1,63}/;
my $IMPACT_CLASS_RE = qr/(?:product-runtime|verification-runtime|control-plane-runtime)/;
my $REASON_CLASS_RE = qr/(?:non-executed-content|test-support-only|delivery-evidence-only|outside-declared-performance-objective)/;
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
my $SCRIPT_DIR = abs_path(dirname(__FILE__));
my $INTERNAL_GIT_CONTEXT = delete $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1};
my (@PINS, @ABS_PINS);
my (%IMMUTABLE_TREE_CACHE, %IMMUTABLE_BLOB_CACHE,
    %IMMUTABLE_TREE_CACHE_HIT, %IMMUTABLE_BLOB_CACHE_HIT);
my $IMMUTABLE_CACHE_BYTES = 0;
my $IMMUTABLE_CACHE_ENTRIES = 0;
our $ACTIVE_PROCESS_GROUP;
our $DEDICATED_DONE_WRITE;

END { notify_dedicated_guard() }

sub fatal { print STDERR "evidence-v1-verify: FATAL: $_[0]\n"; exit 2 }
sub monotonic_now { return clock_gettime(CLOCK_MONOTONIC) }
sub arm_verifier_deadline {
  my $remaining = $VERIFIER_DEADLINE - monotonic_now();
  fatal("evidence verifier deadline exceeded (${VERIFIER_TIMEOUT}s)") unless $remaining > 0;
  $SIG{ALRM} = sub {
    stop_process_group($ACTIVE_PROCESS_GROUP) if defined($ACTIVE_PROCESS_GROUP);
    print STDERR "evidence-v1-verify: FATAL: evidence verifier deadline exceeded (${VERIFIER_TIMEOUT}s)\n";
    # Perl dispatches this handler at a safe opcode boundary.  Normal exit is deliberate: it lets
    # File::Temp remove private index/helper snapshots; _exit would strand them in TMPDIR.
    alarm(0);
    CORE::exit(2);
  };
  alarm($remaining);
}
sub verifier_deadline_guard {
  fatal("evidence verifier deadline exceeded (${VERIFIER_TIMEOUT}s)")
    if monotonic_now() >= $VERIFIER_DEADLINE;
}
sub inode_id { return $_[0][0] . q{:} . $_[0][1] }
sub valid_uint {
  my ($v) = @_;
  return defined($v) && $v =~ /\A$UINT_RE\z/ && length($v) <= 16 && $v <= $MAX_UINT;
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

# A no-slash argv token is an opaque scalar unless it can be an exact canonical root-level Git
# path.  Slash-bearing tokens never use this predicate: their path interpretation is mandatory.
sub canonical_root_path_candidate {
  my ($raw) = @_;
  return 0 unless defined($raw) && length($raw);
  return 0 if $raw =~ /[\x00-\x1f\x7f|]/ || $raw eq q{.} || $raw eq q{..};
  my $text;
  return 0 unless eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 };
  return 0 if $text =~ /[\p{Cc}\p{Cf}\p{Zl}\p{Zp}]/;
  return 1;
}

sub root_abs {
  my ($arg) = @_;
  my @named = lstat($arg);
  fatal('repo root must be a real directory')
    unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
  my $abs = abs_path($arg);
  fatal('repo root unavailable') unless defined($abs);
  my @canonical = lstat($abs);
  fatal('repo root identity changed')
    unless @canonical && !S_ISLNK($canonical[2]) && S_ISDIR($canonical[2])
      && inode_id(\@canonical) eq inode_id(\@named);
  return $abs;
}

sub open_chain {
  my ($root, $parts, $label) = @_;
  my @root_named = lstat($root);
  fatal('repo root identity unavailable')
    unless @root_named && !S_ISLNK($root_named[2]) && S_ISDIR($root_named[2]);
  sysopen(my $dir, $root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('repo root open failed');
  my @root_opened = stat($dir);
  fatal('repo root identity changed')
    unless @root_opened && inode_id(\@root_opened) eq inode_id(\@root_named);
  my @hold = ($dir);
  for my $component (@$parts) {
    chdir($dir) or fatal("unsafe parent for $label");
    my @named = lstat($component);
    fatal("unsafe parent for $label")
      unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal("unsafe parent open for $label");
    my @opened = stat($next);
    fatal("parent identity changed for $label")
      unless @opened && inode_id(\@opened) eq inode_id(\@named);
    push @hold, $next;
    $dir = $next;
  }
  return ($dir, \@hold);
}

sub revalidate_chain {
  my ($root, $parts, $held, $label) = @_;
  my (undef, $opened) = open_chain($root, $parts, $label);
  fatal("directory chain changed for $label") unless @$opened == @$held;
  for my $i (0 .. $#$held) {
    my @a = stat($opened->[$i]); my @b = stat($held->[$i]);
    fatal("directory chain changed for $label")
      unless @a && @b && inode_id(\@a) eq inode_id(\@b);
  }
}

sub read_fd {
  my ($fh, $limit, $label) = @_;
  defined(sysseek($fh, 0, SEEK_SET)) or fatal("seek failed: $label");
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal("read failed: $label") unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal("$label exceeds size limit") if length($raw) > $limit;
  }
  return $raw;
}

sub safe_read {
  my ($root, $rel, $mode) = @_;
  $mode //= 0644;
  my @part = safe_rel($rel, $rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable: $rel");
  my @named = lstat($leaf);
  fatal("$rel must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$rel mode must be 100644") unless ($named[2] & 07777) == $mode;
  fatal("$rel exceeds 16 MiB") if $named[7] > $MAX_FILE;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $rel");
  my @opened = stat($fh);
  fatal("$rel identity changed")
    unless @opened && inode_id(\@opened) eq inode_id(\@named)
      && S_ISREG($opened[2]) && $opened[3] == 1 && ($opened[2] & 07777) == $mode;
  my $raw = read_fd($fh, $MAX_FILE, $rel);
  fatal("$rel changed between descriptor reads") unless read_fd($fh, $MAX_FILE, $rel) eq $raw;
  my @after = stat($fh); my @again = lstat($leaf);
  fatal("$rel changed during read")
    unless @after && @again && !S_ISLNK($again[2])
      && inode_id(\@after) eq inode_id(\@opened)
      && inode_id(\@again) eq inode_id(\@opened)
      && $after[7] == length($raw) && $again[7] == length($raw)
      && ($after[2] & 07777) == $mode && ($again[2] & 07777) == $mode;
  push @PINS, { root => $root, parts => [@part], dirs => $hold, dir => $dir,
    leaf => $leaf, rel => $rel, fh => $fh, opened => [@opened], raw => $raw, mode => $mode };
  return $raw;
}

sub pin_absolute {
  my ($path, $limit, $label) = @_;
  my @named = lstat($path);
  fatal("$label must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$label exceeds size limit") if $named[7] > $limit;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $label");
  my @opened = stat($fh);
  fatal("$label identity changed") unless @opened && inode_id(\@opened) eq inode_id(\@named);
  my $raw = read_fd($fh, $limit, $label);
  fatal("$label changed between reads") unless read_fd($fh, $limit, $label) eq $raw;
  push @ABS_PINS, { path => $path, label => $label, fh => $fh,
    opened => [@opened], raw => $raw, limit => $limit };
  return $raw;
}

sub revalidate_pins {
  for my $pin (@PINS) {
    revalidate_chain($pin->{root}, $pin->{parts}, $pin->{dirs}, $pin->{rel});
    chdir($pin->{dir}) or fatal("artifact directory unavailable: $pin->{rel}");
    my @named = lstat($pin->{leaf}); my @opened = stat($pin->{fh});
    fatal("$pin->{rel} changed before authorization")
      unless @named && @opened && !S_ISLNK($named[2])
        && inode_id(\@named) eq inode_id($pin->{opened})
        && inode_id(\@opened) eq inode_id($pin->{opened})
        && $named[7] == length($pin->{raw}) && $opened[7] == length($pin->{raw})
        && ($named[2] & 07777) == $pin->{mode} && ($opened[2] & 07777) == $pin->{mode}
        && read_fd($pin->{fh}, $MAX_FILE, $pin->{rel}) eq $pin->{raw};
  }
  for my $pin (@ABS_PINS) {
    my @opened = stat($pin->{fh}); my @named = lstat($pin->{path});
    fatal("$pin->{label} changed before authorization")
      unless @opened && @named && !S_ISLNK($named[2])
        && inode_id(\@opened) eq inode_id($pin->{opened})
        && inode_id(\@named) eq inode_id($pin->{opened})
        && read_fd($pin->{fh}, $pin->{limit}, $pin->{label}) eq $pin->{raw};
  }
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
  for my $key (keys %ENV) { delete $ENV{$key} if $key =~ /\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z/ }
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
  my $path = $raw =~ m{\A/} ? $raw : "$root/$raw";
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
    unless canonical_existing_path($root, $worktree, 'worktree') eq $root;
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
  my $raw = read_fd($fh, $MAX_GIT_OUTPUT, 'internal Git context index');
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
    '-c', 'core.checkStat=default', '-c', 'core.ignoreStat=false', '-C', $root, @args);
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
    or fatal('dedicated verifier cancellation-mask block failed');
  pipe(my $cancel_read, my $cancel_write)
    or fatal('dedicated verifier cancellation pipe failed');
  pipe(my $done_read, my $done_write)
    or fatal('dedicated verifier completion pipe failed');

  my $pid = fork();
  unless (defined($pid)) {
    close($cancel_read); close($cancel_write); close($done_read); close($done_write);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated verifier runtime fork failed');
  }
  if ($pid == 0) {
    close($cancel_read); close($cancel_write); close($done_read);
    $DEDICATED_DONE_WRITE = $done_write;
    my $flags = fcntl($done_write, F_GETFD, 0);
    defined($flags) && defined(fcntl($done_write, F_SETFD, $flags | FD_CLOEXEC))
      or fatal('dedicated verifier completion CLOEXEC failed');
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
      or fatal('dedicated verifier runtime signal-mask activation failed');
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
    fatal('dedicated verifier cancellation guard fork failed');
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
    or fatal('dedicated verifier cancellation-mask activation failed');

  # Reap the guard first: it is the only process allowed to signal the numeric runtime PID.  Once
  # it has exited, that authority is gone and the runtime can be reaped without a PID-reuse race.
  while (1) {
    my $got = waitpid($guard, 0);
    last if $got == $guard;
    next if $got == -1 && $! == EINTR;
    fatal('dedicated verifier cancellation guard wait failed');
  }
  my $status;
  while (1) {
    my $got = waitpid($pid, 0);
    if ($got == $pid) { $status = $?; last }
    next if $got == -1 && $! == EINTR;
    fatal('dedicated verifier runtime wait failed');
  }
  sigprocmask(SIG_BLOCK, $cancel_set)
    or fatal('dedicated verifier cancellation-mask shutdown failed');
  @SIG{qw(HUP INT TERM)} = @old_signal{qw(HUP INT TERM)};
  if ($cancel_open) { close($cancel_write); $cancel_open = 0 }
  close($cancel_read); close($done_read);
  sigprocmask(SIG_SETMASK, $prior_cancel)
    or fatal('dedicated verifier cancellation-mask restore failed');
  re_raise_runtime_signal($cancel_signal) if defined($cancel_signal);
  re_raise_runtime_signal($status & 127) if $status & 127;
  my $exit = ($status >> 8) & 255;
  re_raise_runtime_signal($exit - 128)
    if $exit == 128 + SIGHUP || $exit == 128 + SIGINT || $exit == 128 + SIGTERM;
  exit $exit;
}

sub deadline_child {
  my ($label, $limit, $quiet, @cmd) = @_;
  verifier_deadline_guard();
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
  if (monotonic_now() >= $VERIFIER_DEADLINE) {
    stop_process_group($pid);
    $ACTIVE_PROCESS_GROUP = undef;
    restore_launch_alarm($prior_alarm_mask, undef, $label);
    fatal("evidence verifier deadline exceeded (${VERIFIER_TIMEOUT}s)");
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
    if (monotonic_now() >= $VERIFIER_DEADLINE) {
      stop_process_group($pid);
      fatal("evidence verifier deadline exceeded (${VERIFIER_TIMEOUT}s)");
    }
    my $remaining = $VERIFIER_DEADLINE - monotonic_now();
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
        fatal("$label output exceeds cap");
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
          $drain_deadline = monotonic_now() + 1;
          $drain_deadline = $VERIFIER_DEADLINE
            if $drain_deadline > $VERIFIER_DEADLINE;
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
  verifier_deadline_guard();
  chdir(q{/}) or fatal('cannot enter filesystem root');
  my @cmd = git_argv($root, @args);
  my ($raw, $status) = deadline_child('git command', $limit, 0, @cmd);
  fatal('git command terminated by signal') if $status & 127;
  fatal('git command failed') unless (($status >> 8) & 255) == 0;
  return $raw;
}

# Commit/tree/blob objects are content-addressed and immutable for the lifetime of one verifier
# process.  Reuse successful raw reads without moving policy into the cache: every caller still
# applies its own path, mode, ambiguity and size checks.  The shared cap prevents a large valid
# manifest from turning this performance optimization into unbounded resident memory.
sub immutable_cache_store {
  my ($cache, $key, $raw) = @_;
  my $cost = length($key) + length($raw);
  if ($IMMUTABLE_CACHE_ENTRIES < $MAX_MANIFEST_ROWS
      && $cost <= $MAX_FILE - $IMMUTABLE_CACHE_BYTES) {
    $cache->{$key} = $raw;
    $IMMUTABLE_CACHE_BYTES += $cost;
    ++$IMMUTABLE_CACHE_ENTRIES;
  }
  return $raw;
}

sub immutable_cache_clear {
  %IMMUTABLE_TREE_CACHE = ();
  %IMMUTABLE_BLOB_CACHE = ();
  %IMMUTABLE_TREE_CACHE_HIT = ();
  %IMMUTABLE_BLOB_CACHE_HIT = ();
  $IMMUTABLE_CACHE_BYTES = 0;
  $IMMUTABLE_CACHE_ENTRIES = 0;
}

sub immutable_lookup_boundary {
  verifier_deadline_guard();
  chdir(q{/}) or fatal('cannot enter filesystem root');
}

sub cached_tree_listing {
  my ($root, $commit, $path) = @_;
  fatal('immutable tree lookup commit malformed') unless $commit =~ /\A$OID_RE\z/;
  immutable_lookup_boundary();
  my $key = join("\x00", $root, $commit, $path);
  if (exists($IMMUTABLE_TREE_CACHE{$key})) {
    $IMMUTABLE_TREE_CACHE_HIT{$key} = 1;
    return $IMMUTABLE_TREE_CACHE{$key};
  }
  my $raw = git_capture($root, 8192,
    '--literal-pathspecs', 'ls-tree', '-z', '--full-tree', $commit, '--', $path);
  return immutable_cache_store(\%IMMUTABLE_TREE_CACHE, $key, $raw);
}

sub cached_blob_raw {
  my ($root, $oid) = @_;
  fatal('immutable blob lookup OID malformed') unless $oid =~ /\A$OID_RE\z/;
  immutable_lookup_boundary();
  my $key = join("\x00", $root, $oid);
  if (exists($IMMUTABLE_BLOB_CACHE{$key})) {
    $IMMUTABLE_BLOB_CACHE_HIT{$key} = 1;
    return $IMMUTABLE_BLOB_CACHE{$key};
  }
  my $raw = git_capture($root, $MAX_FILE + 1, 'cat-file', 'blob', $oid);
  return immutable_cache_store(\%IMMUTABLE_BLOB_CACHE, $key, $raw);
}

sub revalidate_immutable_cache_hits {
  for my $key (sort keys %IMMUTABLE_TREE_CACHE_HIT) {
    my ($root, $commit, $path) = split /\x00/, $key, 3;
    my $raw = git_capture($root, 8192,
      '--literal-pathspecs', 'ls-tree', '-z', '--full-tree', $commit, '--', $path);
    fatal('immutable Git tree lookup changed during verification')
      unless $raw eq $IMMUTABLE_TREE_CACHE{$key};
  }
  for my $key (sort keys %IMMUTABLE_BLOB_CACHE_HIT) {
    my ($root, $oid) = split /\x00/, $key, 2;
    my $raw = git_capture($root, $MAX_FILE + 1, 'cat-file', 'blob', $oid);
    fatal('immutable Git blob changed during verification')
      unless $raw eq $IMMUTABLE_BLOB_CACHE{$key};
  }
  immutable_cache_clear();
}

sub git_quiet {
  my ($root, @args) = @_;
  verifier_deadline_guard();
  my @cmd = git_argv($root, @args);
  my (undef, $status) = deadline_child('git status', 0, 1, @cmd);
  return $status == 0;
}

sub authority_index_snapshot {
  my ($root) = @_;
  my $raw_path = exact_line(
    git_capture($root, 16_384, 'rev-parse', '--git-path', 'index'), 'index path');
  my $path = $raw_path =~ m{\A/} ? $raw_path : "$root/$raw_path";
  my $raw = pin_absolute($path, $MAX_GIT_OUTPUT, 'git index');

  # Every authority query in a verifier phase must observe one byte-exact index.  Git operates on
  # this private copy while the real index descriptor remains pinned and is revalidated before any
  # authorization result can escape.
  my $dir = tempdir('harness-evidence-index.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $dir) or fatal('cannot protect private index snapshot');
  my $copy = "$dir/index";
  sysopen(my $out, $copy, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
    or fatal('private index snapshot create failed');
  binmode($out, q{:raw});
  my $offset = 0;
  while ($offset < length($raw)) {
    my $n = syswrite($out, $raw, length($raw) - $offset, $offset);
    fatal('private index snapshot write failed') unless defined($n) && $n > 0;
    $offset += $n;
  }
  $out->sync or fatal('private index snapshot sync failed');
  close($out) or fatal('private index snapshot close failed');
  chmod(0600, $copy) or fatal('private index snapshot chmod failed');
  return ($dir, $copy);
}

sub tracked_bytes_match_index {
  my ($root) = @_;
  my ($snapshot_dir, $copy) = authority_index_snapshot($root);

  local $ENV{GIT_INDEX_FILE} = $copy;
  local $ENV{GIT_OPTIONAL_LOCKS} = '1';
  my $clean = git_quiet($root, 'update-index', '--really-refresh')
    && git_quiet($root, 'diff-files', '--quiet', '--no-ext-diff', '--');
  revalidate_pins();
  return $clean;
}

sub exact_line {
  my ($raw, $label) = @_;
  $raw =~ /\A([^\r\n]+)\n\z/ or fatal("$label output malformed");
  return $1;
}

sub commit_exact {
  my ($root, $oid, $label) = @_;
  fatal("$label GitOid malformed") unless $oid =~ /\A$OID_RE\z/;
  my $resolved = exact_line(git_capture($root, 4096, 'rev-parse', '--verify', "$oid^{commit}"), $label);
  fatal("$label does not name its exact commit") unless $resolved eq $oid;
  return exact_line(git_capture($root, 4096, 'rev-parse', "$oid^{tree}"), "$label tree");
}

sub git_blob_at {
  my ($root, $commit, $path) = @_;
  safe_rel($path, 'Git blob path');
  my $listing = cached_tree_listing($root, $commit, $path);
  my ($mode, $type, $oid, $found) =
    $listing =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t([^\x00]+)\x00\z/s;
  fatal("path absent or ambiguous at checkpoint: $path") unless defined($found) && $found eq $path;
  fatal("checkpoint path is not a 100644 blob: $path")
    unless $type eq 'blob' && $mode eq '100644';
  my $raw = cached_blob_raw($root, $oid);
  fatal("checkpoint blob exceeds 16 MiB: $path") if length($raw) > $MAX_FILE;
  return ($raw, $mode, $oid);
}

sub optional_git_entry_at {
  my ($root, $commit, $path, $label) = @_;
  safe_rel($path, $label);
  my $listing = cached_tree_listing($root, $commit, $path);
  return undef if $listing eq q{};
  my ($mode, $type, $oid, $found) =
    $listing =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t([^\x00]+)\x00\z/s;
  fatal("$label path is ambiguous or malformed: $path")
    unless defined($found) && $found eq $path;
  fatal("$label path is not a regular blob: $path") unless $type eq 'blob';
  my $raw = cached_blob_raw($root, $oid);
  fatal("$label blob exceeds 16 MiB: $path") if length($raw) > $MAX_FILE;
  return { raw => $raw, mode => $mode, oid => $oid };
}

sub index_entries {
  my ($root) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT, 'ls-files', '--stage', '-z');
  my @record = split /\x00/, $raw, -1;
  fatal('index listing is not NUL terminated') unless pop(@record) eq q{};
  fatal('index path cap exceeded') if @record > $MAX_PATHS;
  my %entry;
  for my $record (@record) {
    my ($mode, $oid, $stage, $path) = $record =~ /\A([0-7]{6}) ($OID_RE) ([0-3])\t(.*)\z/s;
    fatal('index record malformed') unless defined($path);
    safe_rel($path, 'index path');
    fatal('unmerged index entry blocks evidence binding') unless $stage eq '0';
    fatal('index path duplicated') if exists($entry{$path});
    $entry{$path} = { mode => $mode, oid => $oid };
  }
  return \%entry;
}

sub reject_nonstandard_index_flags {
  my ($root, $index) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT, 'ls-files', '-v', '-z');
  my @record = split /\x00/, $raw, -1;
  fatal('index flag listing is not NUL terminated') unless pop(@record) eq q{};
  my %seen;
  for my $record (@record) {
    my ($tag, $path) = $record =~ /\A(.) (.*)\z/s;
    fatal('index flag record malformed') unless defined($path);
    safe_rel($path, 'index flag path');
    fatal("nonstandard index flag blocks evidence authority: $path") unless $tag eq 'H';
    fatal("index flag path duplicated: $path") if $seen{$path}++;
  }
  fatal('index flag path-set differs from stage-0 index')
    unless keys(%seen) == keys(%$index)
      && !grep { !$seen{$_} } keys %$index;
}

sub staged_delta {
  my ($root, $checkpoint) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT,
    'diff-index', '--cached', '--raw', '-z', '--no-renames', $checkpoint, '--');
  my @part = split /\x00/, $raw, -1;
  fatal('staged delta is not NUL terminated') unless pop(@part) eq q{};
  fatal('staged delta framing malformed') if @part % 2;
  my (%delta, $prior);
  while (@part) {
    my $meta = shift @part; my $path = shift @part;
    my ($oldmode, $newmode, $oldoid, $newoid, $status) =
      $meta =~ /\A:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40,64}) ([0-9a-f]{40,64}) ([AMDT])\z/;
    fatal('staged delta record malformed') unless defined($status);
    safe_rel($path, 'staged delta path');
    fatal('staged delta path duplicated') if exists($delta{$path});
    fatal('staged delta is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $path };
    $delta{$path} = { oldmode => $oldmode, newmode => $newmode,
      oldoid => $oldoid, newoid => $newoid, status => $status };
    $prior = $path;
  }
  return \%delta;
}

sub committed_delta {
  my ($root, $checkpoint, $evidence_head) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT,
    'diff-tree', '--no-commit-id', '--raw', '-z', '--no-renames', '-r',
    $checkpoint, $evidence_head, '--');
  my @part = split /\x00/, $raw, -1;
  fatal('committed evidence delta is not NUL terminated') unless pop(@part) eq q{};
  fatal('committed evidence delta framing malformed') if @part % 2;
  my (%delta, $prior);
  while (@part) {
    my $meta = shift @part; my $path = shift @part;
    my ($oldmode, $newmode, $oldoid, $newoid, $status) =
      $meta =~ /\A:([0-7]{6}) ([0-7]{6}) ([0-9a-f]{40,64}) ([0-9a-f]{40,64}) ([AMDT])\z/;
    fatal('committed evidence delta record malformed') unless defined($status);
    safe_rel($path, 'committed evidence delta path');
    fatal('committed evidence delta path duplicated') if exists($delta{$path});
    fatal('committed evidence delta is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $path };
    $delta{$path} = { oldmode => $oldmode, newmode => $newmode,
      oldoid => $oldoid, newoid => $newoid, status => $status };
    $prior = $path;
  }
  return \%delta;
}

sub committed_bound_worktree_metadata_only {
  my ($root, $state_path, $audit_path) = @_;
  my %allowed = map { $_ => 1 } ($state_path, $audit_path);
  my $raw = git_capture($root, $MAX_GIT_OUTPUT,
    'diff-files', '--raw', '-z', '--no-renames', '--');
  return 1 if $raw eq q{};
  my @part = split /\x00/, $raw, -1;
  fatal('committed-bound worktree delta is not NUL terminated') unless pop(@part) eq q{};
  fatal('committed-bound worktree delta framing malformed') if @part % 2;
  my %seen;
  while (@part) {
    my $meta = shift @part; my $path = shift @part;
    my ($oldmode, $newmode, $status) =
      $meta =~ /\A:([0-7]{6}) ([0-7]{6}) [0-9a-f]{40,64} [0-9a-f]{40,64} ([A-Z])\z/;
    fatal('committed-bound worktree delta record malformed') unless defined($status);
    safe_rel($path, 'committed-bound worktree path');
    fatal("committed-bound worktree changed path outside live metadata: $path")
      unless $allowed{$path};
    fatal("committed-bound live metadata delta malformed: $path")
      unless $status eq 'M' && $oldmode eq '100644' && $newmode eq '100644';
    fatal("committed-bound worktree path duplicated: $path") if $seen{$path}++;
  }
}

sub index_blob {
  my ($root, $entry, $path) = @_;
  fatal("index path absent: $path") unless defined($entry);
  fatal("index path mode must be 100644: $path") unless $entry->{mode} eq '100644';
  my $raw = cached_blob_raw($root, $entry->{oid});
  fatal("index blob exceeds 16 MiB: $path") if length($raw) > $MAX_FILE;
  return $raw;
}

sub audit_rows {
  my ($raw, $where) = @_;
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$where audit is not UTF-8");
  my $header;
  if (index($raw, $MODERN_HEADER) == 0) { $header = $MODERN_HEADER }
  elsif (index($raw, $LEGACY_HEADER) == 0) { $header = $LEGACY_HEADER }
  else { fatal("$where audit header is not canonical") }
  my $body = substr($raw, length($header));
  my @row;
  while (length($body)) {
    $body =~ s/\A(\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n)//
      or fatal("$where audit row is not canonical");
    push @row, { raw => $1, ts => $2, event => $3, detail => $4 };
  }
  return (\@row, $header);
}

sub parse_implementation {
  my ($rows) = @_;
  my ($generation, $active, $bound) = (0, undef, undef);
  my %used;
  for my $row (@$rows) {
    my ($event, $detail) = @$row{qw(event detail)};
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=($UINT_RE);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      my ($next, $scopes) = ($1, $2);
      fatal('receipt generation is not monotonic')
        unless valid_uint($next) && $next == $generation + 1;
      $generation = $next;
      if (grep { $_ eq 'implementation' } split /,/, $scopes) { $active = undef; $bound = undef }
      next;
    }
    fatal('spoofed receipt-invalidate event') if $event =~ /receipt-invalidate/;
    if ($event eq 'implementation-start') {
      $detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($ROOT_RE);capability=implementation-v1;base=($OID_RE)\z/
        or fatal('non-canonical implementation-start detail');
      my %v = (attempt => $1, generation => $2, actor => $3, design => $4, base => $5);
      fatal('implementation-start is not in current generation') unless $v{generation} == $generation;
      fatal('implementation attempt duplicated') if $used{$v{attempt}}++;
      fatal('implementation lifecycle already active') if defined($active);
      $active = \%v; $bound = undef; next;
    }
    if ($event eq 'implementation-bind') {
      $detail =~ /\Aroot=($ROOT_RE);base=($OID_RE);design=($ROOT_RE);attempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE)\z/
        or fatal('non-canonical implementation-bind detail');
      my %v = (root => $1, base => $2, design => $3, attempt => $4,
        generation => $5, actor => $6);
      fatal('implementation-bind has no matching start') unless defined($active);
      fatal('implementation-bind duplicated') if defined($bound);
      for my $key (qw(base design attempt generation actor)) {
        fatal("implementation-bind $key mismatch") unless $v{$key} eq $active->{$key};
      }
      $bound = \%v; next;
    }
    fatal('spoofed or malformed implementation event')
      if $event =~ /implementation-(?:start|bind)/ || $detail =~ /implementation-(?:start|bind)/;
  }
  fatal('checkpoint C has no current bound implementation') unless defined($active) && defined($bound);
  # The implementation receipt can legitimately survive later quality/evidence-only invalidations.
  # Preserve both identities: `generation` is the retained implementation generation, while
  # `receipt_generation` is the global generation at immutable checkpoint C.
  return { %$active, root => $bound->{root}, receipt_generation => $generation };
}

sub parse_review_detail {
  my ($role, $kind, $detail) = @_;
  my @v;
  my $capability = $role eq 'critical-code' ? 'critical-code-review-v1' : 'performance-review-v1';
  if ($kind eq 'start') {
    @v = ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=($ACTOR_RE)\z/);
    fatal("non-canonical review-start:$role detail") unless @v == 5;
  } elsif ($kind eq 'blocked') {
    @v = ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=($ACTOR_RE);reason=(unavailable|lost|invalid-output)\z/);
    fatal("non-canonical review-blocked:$role detail") unless @v == 6;
  } elsif ($kind eq 'finish') {
    @v = ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=($ACTOR_RE);artifact=([^;\r\n]+);sha256=($ROOT_RE)\z/);
    fatal("non-canonical review-finish:$role detail") unless @v == 7;
    safe_rel($v[5], 'review artifact');
  } else { fatal('internal review detail parser error') }
  fatal("review capability mismatch for $role") unless $v[4] eq $capability;
  return { attempt => $v[0], generation => $v[1], actor => $v[2], subject => $v[3],
    capability => $v[4], ($kind eq 'blocked' ? (reason => $v[5]) : ()),
    ($kind eq 'finish' ? (artifact => $v[5], sha256 => $v[6]) : ()) };
}

sub same_review_identity {
  my ($start, $terminal, $role) = @_;
  for my $key (qw(attempt generation actor subject capability)) {
    fatal("$role review terminal $key mismatch") unless $start->{$key} eq $terminal->{$key};
  }
}

sub parse_performance_run_detail {
  my ($kind, $detail) = @_;
  my @v;
  if ($kind eq 'start') {
    @v = ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=performance-process-v1;workloads=($UINT_RE);manifest=($ROOT_RE);producer=($ROOT_RE)\z/);
    fatal('non-canonical performance-run-start detail') unless @v == 7;
  } elsif ($kind eq 'finish') {
    @v = ($detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($OID_RE);capability=performance-process-v1;workloads=($UINT_RE);manifest=($ROOT_RE);producer=($ROOT_RE);raw-samples=($ROOT_RE);artifact=([^;\r\n]+);sha256=($ROOT_RE)\z/);
    fatal('non-canonical performance-run-finish detail') unless @v == 10;
    safe_rel($v[8], 'performance process artifact');
  } else { fatal('internal performance run detail parser error') }
  fatal('performance process workload count outside cap')
    unless $v[4] > 0 && $v[4] <= $MAX_WORKLOADS;
  return {
    attempt => $v[0], generation => $v[1], actor => $v[2], subject => $v[3],
    capability => 'performance-process-v1', workloads => $v[4],
    manifest => $v[5], producer => $v[6],
    ($kind eq 'finish'
      ? (raw_samples => $v[7], artifact => $v[8], sha256 => $v[9]) : ()),
  };
}

sub parse_quality_suffix {
  my ($checkpoint_rows, $live_rows, $checkpoint, $bound_mode,
    $checkpoint_cycle, $checkpoint_generation) = @_;
  fatal('live audit has fewer rows than checkpoint C') if @$live_rows < @$checkpoint_rows;
  for my $i (0 .. $#$checkpoint_rows) {
    fatal('checkpoint C audit is not an exact row prefix of live audit')
      unless $checkpoint_rows->[$i]{raw} eq $live_rows->[$i]{raw};
  }
  my @suffix = @$live_rows[@$checkpoint_rows .. $#$live_rows];
  fatal('C-to-H audit suffix is empty') unless @suffix;
  my $cursor = 0;
  my $review_generation = $checkpoint_generation;
  if ($checkpoint_cycle eq 'reopen') {
    fatal('C-to-H reopen must start with canonical Stage-4 invalidation')
      unless $cursor < @suffix
        && $suffix[$cursor]{event} eq 'stage-4-quality:invalidated'
        && $suffix[$cursor]{detail} eq 'reset from stage-4-quality';
    $cursor++;
    fatal('checkpoint receipt generation exhausted')
      unless valid_uint($checkpoint_generation) && $checkpoint_generation < $MAX_UINT;
    $review_generation = $checkpoint_generation + 1;
    fatal('C-to-H reopen must invalidate exact quality,evidence receipt scopes')
      unless $cursor < @suffix
        && $suffix[$cursor]{event} eq 'receipt-invalidate'
        && $suffix[$cursor]{detail}
          eq "generation=$review_generation;scopes=quality,evidence";
    $cursor++;
  } elsif ($checkpoint_cycle ne 'fresh') {
    fatal('internal checkpoint quality-cycle classifier mismatch');
  }
  fatal('C-to-H event order must start with stage-4-quality:start')
    unless $cursor < @suffix
      && $suffix[$cursor]{event} eq 'stage-4-quality:start'
      && $suffix[$cursor]{detail} eq "checkpoint=$checkpoint";
  $cursor++;
  my %final;
  for my $role (qw(critical-code)) {
    my $finished = 0;
    while (!$finished) {
      fatal("missing review-start:$role in exact C-to-H order")
        unless $cursor < @suffix && $suffix[$cursor]{event} eq "review-start:$role";
      my $start = parse_review_detail($role, 'start', $suffix[$cursor]{detail});
      fatal("$role receipt subject is not exact checkpoint C") unless $start->{subject} eq $checkpoint;
      fatal("$role receipt is not in current Stage-4 generation")
        unless $start->{generation} == $review_generation;
      $cursor++;
      fatal("unmatched review-start:$role") unless $cursor < @suffix;
      if ($suffix[$cursor]{event} eq "review-blocked:$role") {
        my $blocked = parse_review_detail($role, 'blocked', $suffix[$cursor]{detail});
        same_review_identity($start, $blocked, $role);
        $cursor++; next;
      }
      fatal("review role order or terminal mismatch for $role")
        unless $suffix[$cursor]{event} eq "review-finish:$role";
      my $finish = parse_review_detail($role, 'finish', $suffix[$cursor]{detail});
      same_review_identity($start, $finish, $role);
      $final{$role} = $finish;
      $finished = 1; $cursor++;
    }
  }
  my $performance_finished = 0;
  while (!$performance_finished) {
    fatal('missing review-start:performance in exact C-to-H order')
      unless $cursor < @suffix && $suffix[$cursor]{event} eq 'review-start:performance';
    my $start = parse_review_detail('performance', 'start', $suffix[$cursor]{detail});
    fatal('performance receipt subject is not exact checkpoint C')
      unless $start->{subject} eq $checkpoint;
    fatal('performance receipt is not in current Stage-4 generation')
      unless $start->{generation} == $review_generation;
    $cursor++;
    fatal('unmatched review-start:performance') unless $cursor < @suffix;
    if ($suffix[$cursor]{event} eq 'review-blocked:performance') {
      my $blocked = parse_review_detail('performance', 'blocked', $suffix[$cursor]{detail});
      same_review_identity($start, $blocked, 'performance');
      $cursor++; next;
    }
    if ($suffix[$cursor]{event} eq 'review-finish:performance') {
      my $finish = parse_review_detail('performance', 'finish', $suffix[$cursor]{detail});
      same_review_identity($start, $finish, 'performance');
      $finish->{terminal_type} = 'n-a';
      $final{performance} = $finish;
      $performance_finished = 1; $cursor++; next;
    }
    fatal('performance terminal must be typed N/A or reserved process lifecycle')
      unless $suffix[$cursor]{event} eq 'performance-run-start';
    my $run_start = parse_performance_run_detail('start', $suffix[$cursor]{detail});
    for my $key (qw(attempt generation actor subject)) {
      fatal("performance run start $key mismatches independent review start")
        unless $run_start->{$key} eq $start->{$key};
    }
    $cursor++;
    fatal('performance-run-start has no exact finish')
      unless $cursor < @suffix && $suffix[$cursor]{event} eq 'performance-run-finish';
    my $run_finish = parse_performance_run_detail('finish', $suffix[$cursor]{detail});
    for my $key (qw(attempt generation actor subject capability workloads manifest producer)) {
      fatal("performance run finish $key mismatch")
        unless $run_finish->{$key} eq $run_start->{$key};
    }
    $run_finish->{terminal_type} = 'process';
    $final{performance} = $run_finish;
    $performance_finished = 1; $cursor++;
  }
  my $bind;
  if ($bound_mode) {
    fatal('evidence-bind must be the final C-to-H event')
      unless $cursor == $#suffix && $suffix[$cursor]{event} eq 'evidence-bind';
    $suffix[$cursor]{detail} =~ /\Acheckpoint=($OID_RE);root=($ROOT_RE)\z/
      or fatal('non-canonical evidence-bind detail');
    $bind = { checkpoint => $1, root => $2 };
    fatal('evidence-bind checkpoint mismatch') unless $bind->{checkpoint} eq $checkpoint;
    $cursor++;
  }
  fatal('extra or reordered event in exact C-to-H audit suffix') unless $cursor == @suffix;
  fatal('critical and performance review attempts must be distinct')
    if $final{'critical-code'}{attempt} eq $final{performance}{attempt};
  return (\%final, $bind);
}

sub state_field {
  my ($raw, $key, $where) = @_;
  my @v = ($raw =~ /^- \Q$key\E: ([^\r\n]+)$/mg);
  fatal("$where state has non-unique $key") unless @v == 1;
  return $v[0];
}

sub checkpoint_quality_cycle {
  my ($raw, $where) = @_;
  my $text = state_text($raw, $where);
  my @stage = ($text =~ /^- \[([ x-])\] stage-4-quality$/mg);
  fatal("$where state has non-unique stage-4-quality") unless @stage == 1;
  my $evidence = state_field($text, 'Evidence-Root', $where);
  my $quality_head = state_field($text, 'Quality-HEAD', $where);
  my $verdict = state_field($text, 'quality-verdict', $where);
  my $confidence = state_field($text, 'confidence-stage-4-quality', $where);
  my $ts = qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;

  if ($stage[0] eq q{ }) {
    fatal("$where fresh Stage-4 checkpoint contains prior authority")
      unless $evidence eq "\x{2014}" && $quality_head eq "\x{2014}";
    fatal("$where fresh Stage-4 checkpoint has non-pending verdict/confidence")
      unless $verdict eq "\x{2014}" && $confidence eq "\x{2014}";
    return 'fresh';
  }

  fatal("$where Stage-4 checkpoint must be fresh or completed") unless $stage[0] eq 'x';
  my $evidence_ready = $evidence =~ /\A$ROOT_RE\z/;
  my $quality_ready = $quality_head =~ /\A$OID_RE\z/;
  fatal("$where completed Stage-4 authority is partial or malformed")
    unless $evidence_ready && $quality_ready;
  fatal("$where completed Stage-4 verdict is not canonical PASS evidence")
    unless $verdict =~ /\APASS \x{2014} [^\r\n]+ \($ts\)\z/;
  fatal("$where completed Stage-4 confidence is not canonical")
    unless $confidence =~ /\Agreen \($ts\)\z/
      || $confidence =~ /\Agreen \x{2014} [^\r\n]+ \($ts\)\z/
      || $confidence =~ /\A(?:yellow|red) \x{2014} [^\r\n]+ \($ts\) \x{00b7} ack: [^\r\n]+ \($ts\)\z/;
  return 'reopen';
}

sub authenticate_completed_checkpoint {
  my ($root, $spec, $checkpoint, $checkpoint_state, $cycle, $implementation) = @_;
  return if $cycle eq 'fresh';
  fatal('internal completed-checkpoint classifier mismatch') unless $cycle eq 'reopen';
  my $evidence_root = state_field($checkpoint_state, 'Evidence-Root', 'checkpoint C');
  my $quality_head = state_field($checkpoint_state, 'Quality-HEAD', 'checkpoint C');
  # A completed C is eligible for reopen only when it is itself the immutable B of a canonical
  # prior H->B transition.  Lexically plausible roots are not authority: authenticate their
  # parentage, state continuity and strict lifecycle before allowing generation advancement.
  verify_immutable_b_boundary($root, $spec, $quality_head, $checkpoint, $evidence_root,
    $implementation->{root}, $implementation->{design});
}

sub run_helper {
  my ($root, $checkpoint, $label, @argv) = @_;
  verifier_deadline_guard();
  my @name = $label eq 'tdd-receipt-v1.pl'
    ? qw(tdd-receipt-v1.pl implementation-tdd-verify.pl architecture-sdd-verify.pl)
    : ($label);
  my $dir = tempdir('harness-evidence-helper.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $dir) or fatal('cannot protect immutable helper snapshot');
  my @pin;
  for my $name (@name) {
    fatal("helper name outside closed set: $name")
      unless $name =~ /\A(?:receipt-v1|tdd-receipt-v1|implementation-tdd-verify|architecture-sdd-verify)\.pl\z/;
    my ($raw, $mode) = git_entry_at($root, $checkpoint, "scripts/$name");
    fatal("checkpoint helper mode unsupported: $name")
      unless $mode eq '100644' || $mode eq '100755';
    my $path = "$dir/$name";
    sysopen(my $out, $path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
      or fatal("immutable helper snapshot create failed: $name");
    binmode($out, q{:raw});
    my $off = 0;
    while ($off < length($raw)) {
      my $n = syswrite($out, $raw, length($raw) - $off, $off);
      fatal("immutable helper snapshot write failed: $name") unless defined($n) && $n;
      $off += $n;
    }
    $out->sync or fatal("immutable helper snapshot sync failed: $name");
    close($out) or fatal("immutable helper snapshot close failed: $name");
    chmod(0644, $path) or fatal("immutable helper snapshot chmod failed: $name");
    my @named = lstat($path);
    fatal("immutable helper snapshot identity invalid: $name")
      unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
        && $named[3] == 1 && ($named[2] & 07777) == 0644
        && $named[7] == length($raw);
    push @pin, { path => $path, raw => $raw, id => inode_id(\@named) };
  }
  my $path = "$dir/$label";
  my ($out, $status) = deadline_child("immutable helper $label", $MAX_FILE, 0,
    $^X, $path, @argv);
  immutable_cache_clear();
  fatal("helper terminated by signal: $label") if $status & 127;
  fatal("helper rejected evidence: $label") unless (($status >> 8) & 255) == 0;
  for my $pin (@pin) {
    verifier_deadline_guard();
    my @named = lstat($pin->{path});
    fatal("immutable helper snapshot changed: $pin->{path}")
      unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
        && inode_id(\@named) eq $pin->{id} && ($named[2] & 07777) == 0644
        && $named[7] == length($pin->{raw});
    open(my $check, '<:raw', $pin->{path}) or fatal('immutable helper snapshot reopen failed');
    local $/; my $again = <$check> // q{}; close($check) or fatal('immutable helper snapshot close failed');
    fatal('immutable helper snapshot bytes changed') unless $again eq $pin->{raw};
  }
  return $out;
}

sub verify_receipt {
  my ($root, $spec, $checkpoint, $role, $attempt, $audit_sha) = @_;
  my $out = run_helper($root, $checkpoint, 'receipt-v1.pl',
    'verify-finished', $root, $spec, $role, $attempt);
  my @key = qw(attempt generation actor subject capability artifact sha256 auditsha256);
  my %v;
  for my $key (@key) {
    $out =~ s/\A\Q$key\E=([^\r\n]+)\n// or fatal("$role receipt helper output malformed at $key");
    $v{$key} = $1;
  }
  fatal("$role receipt helper returned extra output") if length($out);
  fatal("$role receipt helper observed another audit snapshot") unless $v{auditsha256} eq $audit_sha;
  return \%v;
}

sub trusted_performance_terminal {
  my ($root, $spec, $checkpoint, $implementation, $terminal, $audit_sha,
    $artifact_path, $artifact_raw) = @_;
  fatal('performance terminal type missing')
    unless $terminal->{terminal_type}
      && ($terminal->{terminal_type} eq 'process' || $terminal->{terminal_type} eq 'n-a');
  my $receipt;
  if ($terminal->{terminal_type} eq 'n-a') {
    $receipt = verify_receipt($root, $spec, $checkpoint, 'performance',
      $terminal->{attempt}, $audit_sha);
    $receipt->{terminal_type} = 'n-a';
    for my $key (qw(attempt generation actor subject capability artifact sha256)) {
      fatal("performance N/A helper/tail receipt mismatch: $key")
        unless $receipt->{$key} eq $terminal->{$key};
    }
  } else {
    $receipt = { %$terminal };
    fatal('performance process producer digest mismatches exact C')
      unless $receipt->{producer} eq producer_sha($root, $checkpoint);
    my $manifest = performance_workload_at($root, $spec, $checkpoint, undef);
    fatal('performance process manifest digest mismatch')
      unless $receipt->{manifest} eq $manifest->{manifest_sha};
    fatal('performance process workload count mismatch')
      unless valid_uint($receipt->{workloads}) && $receipt->{workloads} > 0
        && $receipt->{workloads} == keys(%{$manifest->{all_workloads}});
  }
  fatal('performance receipt subject is not exact checkpoint C')
    unless $receipt->{subject} eq $checkpoint;
  fatal('performance reviewer actor equals implementation actor')
    if $receipt->{actor} eq $implementation->{actor};
  fatal('performance reviewer attempt equals implementation attempt')
    if $receipt->{attempt} eq $implementation->{attempt};
  fatal('performance artifact path is non-canonical') unless $receipt->{artifact} eq $artifact_path;
  fatal('performance artifact digest mismatch') unless sha256_hex($artifact_raw) eq $receipt->{sha256};
  return $receipt;
}

sub markdown_text {
  my ($raw, $label) = @_;
  fatal("$label contains NUL or disallowed control bytes") if $raw =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$label is not UTF-8");
  fatal("$label retains an unresolved template placeholder") if $text =~ /\{\{[^\r\n]+\}\}/;
  fatal("$label contains a runner-specific machine path")
    if $text =~ m{(?:/Users/[^/\s]+/|/home/[^/\s]+/|/private/var/|/var/folders/|[A-Za-z]:\\Users\\)}i;
  fatal("$label contains secret-shaped material")
    if $text =~ /(?:AKIA[0-9A-Z]{16}|gh[pousr]_[A-Za-z0-9_]{20,}|sk-[A-Za-z0-9_-]{20,}|-----BEGIN [A-Z ]*PRIVATE KEY-----|Authorization:\s*Bearer\s+\S+|(?:token|password|api[_-]?key|client[_-]?secret)\s*[=:]\s*[^\s|]{8,})/i;
  return $text;
}

sub metadata {
  my ($text, $required, $label) = @_;
  my %value;
  while ($text =~ /^- ([A-Za-z][A-Za-z0-9-]*): ([^\r\n]+)$/mg) {
    fatal("$label metadata duplicated: $1") if exists($value{$1});
    $value{$1} = $2;
  }
  my %allowed = map { $_ => 1 } @$required;
  for my $key (keys %value) { fatal("$label metadata is not in frozen schema: $key") unless $allowed{$key} }
  for my $key (@$required) { fatal("$label metadata missing: $key") unless exists($value{$key}) }
  return \%value;
}

sub canonical_metadata_block {
  my ($prefix, $value, $order) = @_;
  my $raw = $prefix;
  $raw .= "- $_: $value->{$_}\n" for @$order;
  return $raw . "\n";
}

sub canonical_table_block {
  my ($heading, $header, $separator, $rows) = @_;
  my $raw = "## $heading\n\n$header\n$separator\n";
  $raw .= '| ' . join(' | ', @$_) . " |\n" for @$rows;
  return $raw;
}

sub table_after {
  my ($text, $heading, $header, $separator, $label) = @_;
  my $prefix = "## $heading\n\n$header\n$separator\n";
  my $at = index($text, $prefix);
  fatal("$label table missing: $heading") if $at < 0;
  fatal("$label table duplicated: $heading") if index($text, $prefix, $at + 1) >= 0;
  my $body = substr($text, $at + length($prefix));
  $body =~ s/\n## [\s\S]*\z//;
  $body =~ s/\n\z//;
  my @rows;
  for my $line (split /\n/, $body, -1) {
    next if $line eq q{};
    fatal("$label malformed table row in $heading") unless $line =~ /\A\| (.*) \|\z/;
    my @cell = split / \| /, $1, -1;
    push @rows, \@cell;
  }
  return \@rows;
}

my @CRITICAL_AXES = qw(
  correctness simplicity-cleanliness maintainability architecture-conformance security
  testability algorithmic-complexity cpu memory io concurrency performance performance-scope
);

sub verify_critical_review {
  my ($raw, $checkpoint, $implementation, $receipt, $root, $spec) = @_;
  my $text = markdown_text($raw, 'critical code review');
  my @required = qw(Schema Checkpoint-C Implementation-Root Implementation-Actor
    Implementation-Attempt Reviewer-Actor Reviewer-Attempt Verdict P0 P1 P2 P3);
  my $m = metadata($text, \@required, 'critical code review');
  fatal('critical review schema mismatch') unless $m->{Schema} eq 'critical-code-review-v1';
  fatal('critical review checkpoint mismatch') unless $m->{'Checkpoint-C'} eq $checkpoint;
  fatal('critical review Implementation-Root mismatch')
    unless $m->{'Implementation-Root'} eq $implementation->{root};
  fatal('critical review Implementation-Actor mismatch')
    unless $m->{'Implementation-Actor'} eq $implementation->{actor};
  fatal('critical review Implementation-Attempt mismatch')
    unless $m->{'Implementation-Attempt'} eq $implementation->{attempt};
  fatal('critical review actor mismatches trusted receipt')
    unless $m->{'Reviewer-Actor'} eq $receipt->{actor};
  fatal('critical review attempt mismatches trusted receipt')
    unless $m->{'Reviewer-Attempt'} eq $receipt->{attempt};
  fatal('critical reviewer actor equals implementation actor')
    if $receipt->{actor} eq $implementation->{actor};
  fatal('critical reviewer attempt equals implementation attempt')
    if $receipt->{attempt} eq $implementation->{attempt};
  fatal('critical review Verdict must be PASS') unless $m->{Verdict} eq 'PASS';
  for my $severity (qw(P0 P1 P2 P3)) {
    valid_uint($m->{$severity}) or fatal("critical review $severity count malformed");
  }
  fatal('critical review has blocking P0/P1/P2 finding')
    unless $m->{P0} == 0 && $m->{P1} == 0 && $m->{P2} == 0;
  my $axes = table_after($text, 'Review axes',
    '| axis | verdict | evidence |', '|---|---|---|', 'critical code review');
  fatal('critical review axis count mismatch') unless @$axes == @CRITICAL_AXES;
  my %seen;
  for my $i (0 .. $#CRITICAL_AXES) {
    my $row = $axes->[$i];
    fatal('critical review axis row arity mismatch') unless @$row == 3;
    fatal('critical review axes are missing, extra, or reordered')
      unless $row->[0] eq $CRITICAL_AXES[$i];
    fatal("critical review axis duplicated: $row->[0]") if $seen{$row->[0]}++;
    fatal("critical review axis verdict malformed: $row->[0]")
      unless $row->[1] eq 'PASS' || $row->[1] eq 'N/A';
    fatal("critical review axis has no concrete evidence: $row->[0]")
      unless $row->[2] =~ /[^[:space:]]/ && $row->[2] ne q{-};
    fatal("critical review N/A has no explicit reason: $row->[0]")
      if $row->[1] eq 'N/A' && $row->[2] !~ /(?:not-applicable|no |none|non-runtime)/i;
  }
  my $manifest_path = "$spec/performance-manifest-v1.tsv";
  my $scope_entry = optional_git_entry_at(
    $root, $checkpoint, $manifest_path, 'performance scope authority');
  my $performance_row = $axes->[-2];
  my $scope_row = $axes->[-1];
  if (defined($scope_entry)) {
    fatal('performance manifest scope authority mode must be 100644')
      unless $scope_entry->{mode} eq '100644';
    my $scope = performance_workload_at($root, $spec, $checkpoint, undef);
    verify_workload_binding($root, $spec, $checkpoint, $implementation->{base}, $scope);
    my $expected = join(q{;}, "scope-root=$scope->{scope_root}",
      "c-count=$scope->{c_count}", "n-count=$scope->{n_count}",
      'synthetic-preflight=none', 'semantic-relevance=independent-reviewer');
    fatal('critical performance axis must review manifest objective/budgets/scope before execution')
      unless $performance_row->[1] eq 'PASS'
        && $performance_row->[2] eq
          'checked: manifest objective, budgets, and measured/non-measured scope were critically reviewed before performance execution';
    fatal('critical performance-scope axis must be PASS for a process manifest')
      unless $scope_row->[1] eq 'PASS';
    fatal('critical performance-scope evidence does not bind exact C/N authority')
      unless $scope_row->[2] eq $expected;
  } else {
    my $expected = join(q{;}, 'scope-root=n-a', 'c-count=0', 'n-count=0',
      'synthetic-preflight=none', 'semantic-relevance=independent-reviewer',
      'reason=performance-not-applicable');
    fatal('critical performance-scope axis without a process manifest must be N/A')
      unless $scope_row->[1] eq 'N/A';
    fatal('critical performance-scope N/A evidence malformed')
      unless $scope_row->[2] eq $expected;
  }
  if (grep { $_->[1] eq 'N/A' } @$axes) {
    # Axis N/A is not a waiver.  It is available only when the entire implementation payload is
    # mechanically proven narrative-only by the same closed classifier as performance N/A.
    nonruntime_impact_paths($root, $spec, $implementation->{base}, $checkpoint);
  }
  my $follow = table_after($text, 'P3 follow-up',
    '| id | owner | target | action |', '|---|---|---|---|', 'critical code review');
  if ($m->{P3} == 0) {
    fatal('P3=0 requires the canonical none follow-up row')
      unless @$follow == 1 && join("\t", @{$follow->[0]}) eq "none\tnone\tnone\tnone";
  } else {
    fatal('P3 follow-up count mismatch') unless @$follow == $m->{P3};
    my %id;
    for my $row (@$follow) {
      fatal('P3 follow-up row arity mismatch') unless @$row == 4;
      fatal('P3 follow-up id malformed') unless $row->[0] =~ /\AP3-[0-9]{1,6}\z/;
      fatal('P3 follow-up id duplicated') if $id{$row->[0]}++;
      fatal('P3 follow-up owner malformed') unless $row->[1] =~ /\A$ACTOR_RE\z/;
      fatal('P3 follow-up target/action missing')
        unless $row->[2] =~ /[^[:space:]]/ && $row->[3] =~ /[^[:space:]]/;
    }
  }
  return { axes => { map { $_->[0] => $_->[1] } @$axes } };
}

sub parse_spec_requirements {
  my ($raw) = @_;
  my $text = markdown_text($raw, 'checkpoint spec');
  my (%seen, @req);
  while ($text =~ /^- \*\*($REQ_RE) \([^\r\n]+\)\.\*\*/mg) {
    my $id = $1;
    fatal("spec requirement duplicated: $id") if $seen{$id}++;
    push @req, $id;
  }
  fatal('checkpoint spec has no FR/NFR requirements') unless @req;
  return \@req;
}

sub parse_delivery_contract {
  my ($raw, $requirements) = @_;
  my $text = markdown_text($raw, 'checkpoint delivery trace');
  my @line = split /\n/, $text, -1;
  pop @line if @line && $line[-1] eq q{};
  fatal('delivery trace is empty') unless @line >= 2;
  my @head = split /\t/, shift(@line), -1;
  my %at;
  for my $i (0 .. $#head) { fatal("delivery header duplicated: $head[$i]") if exists($at{$head[$i]}); $at{$head[$i]} = $i }
  for my $key (qw(requirement test kind)) { fatal("delivery trace missing column: $key") unless exists($at{$key}) }
  my %row;
  my %required = map { $_ => 1 } @$requirements;
  for my $line (@line) {
    next unless length($line);
    my @cell = split /\t/, $line, -1;
    fatal('delivery trace row arity mismatch') unless @cell == @head;
    my $req = $cell[$at{requirement}];
    fatal("delivery trace unknown requirement: $req") unless $req =~ /\A$REQ_RE\z/;
    fatal("delivery trace requirement is outside checkpoint spec: $req") unless $required{$req};
    fatal("delivery trace requirement duplicated: $req") if exists($row{$req});
    my $test = $cell[$at{test}];
    fatal("delivery trace TestId malformed for $req") unless $test =~ /\A$TEST_RE\z/;
    my $kind = $cell[$at{kind}];
    fatal("delivery trace kind malformed for $req")
      unless $kind eq 'behavioral' || $kind eq 'non-behavioral';
    $row{$req} = { test => $test, kind => $kind };
  }
  for my $req (@$requirements) { fatal("delivery trace missing requirement: $req") unless exists($row{$req}) }
  return \%row;
}

sub tdd_process_receipts {
  my ($root, $spec, $checkpoint, $attempt, $audit_sha) = @_;
  my $out = run_helper($root, $checkpoint, 'tdd-receipt-v1.pl',
    'verify-chain', $root, $spec, $attempt);
  my %receipt;
  my $expected_contract;
  while ($out =~ s/\AReceipt: ([^\r\n]+)\n//) {
    my $detail = $1;
    my @v = ($detail =~ /\Atest=($TEST_RE);phase=(red|green|adjacent);executed=($TEST_RE);run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);contract=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120;result=(assertion-failed|assertion-passed|setup-failed|timeout|invalid-output);exit=(0|[1-9][0-9]{0,2}|signal-[1-9][0-9]{0,2}|timeout);signature=($ROOT_RE|none);stdout=($ROOT_RE);stderr=($ROOT_RE);duration-ms=($UINT_RE)\z/);
    fatal('TDD process receipt output malformed') unless @v == 20;
    my %r = (test => $v[0], phase => $v[1], executed => $v[2], run => $v[3],
      generation => $v[4], implementation => $v[5], actor => $v[6], root => $v[7],
      contract => $v[8], producer => $v[13], result => $v[14], exit => $v[15],
      signature => $v[16]);
    fatal('TDD receipt does not belong to current implementation') unless $r{implementation} eq $attempt;
    fatal('TDD receipt expected-contract identity changed within the retained chain')
      if defined($expected_contract) && $r{contract} ne $expected_contract;
    $expected_contract = $r{contract};
    fatal("TDD receipt duplicated: $r{test}/$r{phase}") if exists($receipt{$r{test}}{$r{phase}});
    $receipt{$r{test}}{$r{phase}} = \%r;
  }
  $out =~ s/\AAudit-SHA256: ($ROOT_RE)\n\z// or fatal('TDD helper Audit-SHA output malformed');
  fatal('TDD helper observed another audit snapshot') unless $1 eq $audit_sha;
  return \%receipt;
}

sub verify_requirement_evidence {
  my ($raw, $checkpoint, $implementation, $requirements, $delivery,
    $root, $spec, $audit_sha, $critical) = @_;
  my $text = markdown_text($raw, 'requirement evidence');
  my $m = metadata($text, [qw(Schema Checkpoint-C Implementation-Root Verdict)],
    'requirement evidence');
  fatal('requirement evidence schema mismatch') unless $m->{Schema} eq 'requirement-evidence-v1';
  fatal('requirement evidence checkpoint mismatch') unless $m->{'Checkpoint-C'} eq $checkpoint;
  fatal('requirement evidence Implementation-Root mismatch')
    unless $m->{'Implementation-Root'} eq $implementation->{root};
  fatal('requirement evidence Verdict must be PASS') unless $m->{Verdict} eq 'PASS';
  my $rows = table_after($text, 'Requirement map',
    '| requirement | mode | primary-test | green-run | adjacent-test | adjacent-run | evidence | retest |',
    '|---|---|---|---|---|---|---|---|', 'requirement evidence');
  # Backward-compatible template location: the initial table may follow metadata directly.
  if (!@$rows) { fatal('requirement evidence map is empty') }
  my %row;
  for my $r (@$rows) {
    fatal('requirement evidence row arity mismatch') unless @$r == 8;
    my ($req, $mode, $test, $green, $adjacent_test, $adjacent, $evidence, $retest) = @$r;
    fatal("requirement evidence unknown ID: $req") unless $req =~ /\A$REQ_RE\z/;
    fatal("requirement evidence duplicates $req") if exists($row{$req});
    fatal("requirement evidence primary TestId mismatch for $req")
      unless $test eq $delivery->{$req}{test};
    $row{$req} = { mode => $mode, test => $test, green => $green,
      adjacent_test => $adjacent_test, adjacent => $adjacent,
      evidence => $evidence, retest => $retest };
  }
  fatal('requirement evidence row count mismatch') unless @$rows == @$requirements;
  for my $i (0 .. $#$requirements) {
    fatal('requirement evidence rows are not in checkpoint requirement order')
      unless $rows->[$i][0] eq $requirements->[$i];
  }
  # This is the single post-C TDD authority boundary used by quality-head and publish.  Replay the
  # trusted chain even for an all-non-behavioral delivery: otherwise a dangling receipt lifecycle
  # or trusted-producer drift could hide behind the absence of behavioral requirement rows.
  my $receipts = tdd_process_receipts($root, $spec, $checkpoint,
    $implementation->{attempt}, $audit_sha);
  for my $req (@$requirements) {
    my $r = $row{$req} // fatal("requirement evidence missing: $req");
    if ($delivery->{$req}{kind} eq 'behavioral') {
      fatal("behavioral requirement $req must use execution evidence") unless $r->{mode} eq 'execution';
      fatal("execution evidence marker malformed for $req")
        unless $r->{evidence} eq 'process-receipt-v1' && $r->{retest} eq 'passed';
      fatal("execution run IDs malformed for $req")
        unless $r->{green} =~ /\A$ATTEMPT_RE\z/ && $r->{adjacent} =~ /\A$ATTEMPT_RE\z/
          && $r->{adjacent_test} =~ /\A$TEST_RE\z/;
      fatal("adjacent evidence is not distinct from primary evidence for $req")
        if $r->{adjacent_test} eq $r->{test} || $r->{adjacent} eq $r->{green};
      my $green = $receipts->{$r->{test}}{green};
      my $adjacent = $receipts->{$r->{test}}{adjacent};
      fatal("accepted GREEN process receipt missing for $req")
        unless defined($green) && $green->{result} eq 'assertion-passed' && $green->{exit} eq '0'
          && $green->{run} eq $r->{green} && $green->{executed} eq $r->{test};
      fatal("accepted adjacent process receipt missing for $req")
        unless defined($adjacent) && $adjacent->{result} eq 'assertion-passed'
          && $adjacent->{exit} eq '0' && $adjacent->{run} eq $r->{adjacent}
          && $adjacent->{executed} eq $r->{adjacent_test};
    } else {
      fatal("non-behavioral requirement $req must use inspection evidence")
        unless $r->{mode} eq 'inspection';
      fatal("inspection receipt columns malformed for $req")
        unless $r->{green} eq q{-} && $r->{adjacent_test} eq q{-} && $r->{adjacent} eq q{-}
          && $r->{retest} eq 'reviewed';
      if ($r->{evidence} =~ /\Acritical-code:([a-z-]+)\z/) {
        fatal("inspection cites an absent critical axis for $req") unless exists($critical->{axes}{$1});
      } elsif ($r->{evidence} =~ /\Acheckpoint-file=([^;]+);sha256=($ROOT_RE)\z/) {
        my ($path, $sha) = ($1, $2);
        safe_rel($path, "inspection evidence for $req");
        my ($bytes, $mode) = git_entry_at($root, $checkpoint, $path);
        fatal("inspection evidence path mode mismatch for $req") unless $mode eq '100644';
        fatal("inspection evidence digest mismatch for $req") unless sha256_hex($bytes) eq $sha;
      } else {
        fatal("inspection evidence is not a bound critical axis or checkpoint file for $req");
      }
    }
  }
}

sub git_entry_at {
  my ($root, $commit, $path) = @_;
  safe_rel($path, 'Git tree entry path');
  my $listing = cached_tree_listing($root, $commit, $path);
  my ($mode, $type, $oid, $found) =
    $listing =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t([^\x00]+)\x00\z/s;
  fatal("path absent or ambiguous at checkpoint tree: $path")
    unless defined($found) && $found eq $path;
  fatal("performance dataset path is not a regular blob: $path")
    unless $type eq 'blob' && ($mode eq '100644' || $mode eq '100755');
  my $raw = cached_blob_raw($root, $oid);
  fatal("performance dataset blob exceeds 16 MiB: $path") if length($raw) > $MAX_FILE;
  return ($raw, $mode, $oid);
}

sub producer_sha {
  my ($root, $checkpoint) = @_;
  my $path = 'scripts/performance-process-v1.pl';
  my ($checkpoint_raw, $mode) = git_entry_at($root, $checkpoint, $path);
  fatal('checkpoint performance producer mode must be 100644') unless $mode eq '100644';
  return sha256_hex($checkpoint_raw);
}

sub performance_workload_at {
  my ($root, $spec, $checkpoint, $wanted) = @_;
  fatal('performance workload ID malformed')
    if defined($wanted) && $wanted !~ /\A$WORKLOAD_RE\z/;
  my ($raw) = git_blob_at($root, $checkpoint, "$spec/performance-manifest-v1.tsv");
  markdown_text($raw, 'performance manifest');
  # Preserve validated UTF-8 as bytes: Git path keys, canonical ordering and ScopeRoot all use the
  # same byte representation rather than a one-sided Perl character upgrade.
  my @line = split /\n/, $raw, -1;
  fatal('performance manifest must end with one LF') unless pop(@line) eq q{};
  fatal('performance manifest schema line mismatch')
    unless @line && shift(@line) eq "schema\tperformance-manifest-v1";
  fatal('performance manifest row count exceeds cap') if @line > $MAX_MANIFEST_ROWS;
  my (%workload, %nonimpact, %seen);
  my $dataset_rows = 0;
  for my $line (@line) {
    verifier_deadline_guard();
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
      valid_uint($absolute) && $absolute > 0 && $absolute <= 30_000_000
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
        if $covered_path eq "$spec/performance-manifest-v1.tsv";
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
        if $dataset eq "$spec/performance-manifest-v1.tsv";
      fatal("performance dataset row invalid: $id/$dataset")
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
    fatal("performance workload authority incomplete: $id")
      unless $w->{meta} && @{$w->{coverage} // []}
        && @{$w->{argv} // []} && @{$w->{dataset} // []};
    for my $i (0 .. $#{$w->{argv}}) {
      fatal("performance argv index is not contiguous: $id/$i")
        unless defined($w->{argv}[$i]) && $w->{argv}[$i]{index} == $i;
    }
    my $argv_bytes = 0;
    for my $arg (@{$w->{argv}}) {
      $argv_bytes += $arg->{size};
      fatal("performance argv exceeds byte cap: $id") if $argv_bytes > $MAX_ARG_BYTES;
    }
    my $m = $w->{meta};
    $measured_runs += $m->{repetitions} * ($m->{mode} eq 'comparative' ? 2 : 1)
      + scalar(@{$w->{coverage}});
    fatal('performance manifest measured-run count exceeds cap')
      if $measured_runs > $MAX_MEASURED_RUNS;
    $canonical .= join("\t", 'W', $id, @$m{qw(requirement test mode repetitions variance
      absolute regression metric unit environment)}) . "\n";
    $canonical .= join("\t", 'C', $id, $_, $w->{impact}{$_}) . "\n"
      for sort { use bytes; $a cmp $b } @{$w->{coverage}};
    $canonical .= join("\t", 'A', $id, @{$_}{qw(index size hex)}) . "\n"
      for @{$w->{argv}};
    $canonical .= join("\t", 'D', $id, @{$_}{qw(path mode size sha)}) . "\n"
      for sort { use bytes; $a->{path} cmp $b->{path} } @{$w->{dataset}};
    $w->{id} = $id;
  }
  $canonical .= join("\t", 'N', $_, $nonimpact{$_}) . "\n"
    for sort { use bytes; $a cmp $b } keys %nonimpact;
  fatal('performance manifest rows are not in canonical order')
    unless $canonical eq $raw;
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
  my $manifest_sha = sha256_hex($raw);
  if (defined($wanted)) {
    fatal("requested performance workload absent: $wanted") unless $workload{$wanted};
    my %selected = %{$workload{$wanted}};
    $selected{manifest_sha} = $manifest_sha;
    $selected{all_workloads} = \%workload;
    $selected{nonimpact} = \%nonimpact;
    $selected{scope_root} = sha256_hex($scope_preimage);
    $selected{c_count} = $c_count;
    $selected{n_count} = scalar(keys %nonimpact);
    return \%selected;
  }
  return { manifest_sha => $manifest_sha, all_workloads => \%workload,
    nonimpact => \%nonimpact, scope_root => sha256_hex($scope_preimage),
    c_count => $c_count, n_count => scalar(keys %nonimpact) };
}

sub workload_command_sha {
  my ($workload) = @_;
  my @argv = map { $_->{raw} } @{$workload->{argv}};
  fatal('performance workload argv is empty') unless @argv;
  if ($argv[0] =~ m{\A/}) {
    fatal('performance workload system executable outside closed policy')
      unless $SYSTEM_INTERPRETER{$argv[0]};
  } else {
    safe_rel($argv[0], 'performance workload executable');
    $argv[0] = "./$argv[0]";
  }
  my $manifest = "HARNESS-PERFORMANCE-ARGV-V1\n";
  for my $i (0 .. $#argv) {
    $manifest .= join("\t", 'A', $i, length($argv[$i]), unpack('H*', $argv[$i])) . "\n";
  }
  return sha256_hex($manifest);
}

sub verify_workload_binding {
  my ($root, $spec, $checkpoint, $base, $workload) = @_;
  my ($map_raw) = git_blob_at($root, $checkpoint, "$spec/implementation-map.tsv");
  markdown_text($map_raw, 'implementation map');
  my @map_line = split /\n/, $map_raw, -1;
  fatal('implementation map must end with one LF') unless pop(@map_line) eq q{};
  fatal('implementation map header mismatch')
    unless shift(@map_line) eq "requirement\tdecision\ttest\tpath";
  my %mapped;
  for my $line (@map_line) {
    my ($requirement, $decision, $test, $path) = split /\t/, $line, -1;
    fatal('implementation map row malformed')
      unless defined($path) && $requirement =~ /\A$REQ_RE\z/
        && $decision =~ /\AAD-[0-9]{3}\z/ && $test =~ /\A$TEST_RE\z/;
    safe_rel($path, 'implementation map path');
    fatal("implementation map path duplicated: $path") if exists($mapped{$path});
    $mapped{$path} = { requirement => $requirement, test => $test };
  }
  my $all = $workload->{all_workloads}
    // fatal('performance workload set authority unavailable');
  my $nonimpact = $workload->{nonimpact}
    // fatal('performance non-measured scope authority unavailable');
  my (%covered, %assigned);
  for my $id (sort keys %$all) {
    my $member = $all->{$id};
    for my $path (@{$member->{coverage}}) {
      fatal("performance measured C scope overlaps: $path")
        if exists($covered{$path}) || exists($nonimpact->{$path});
      fatal("performance workload covers path outside implementation map: $path")
        unless exists($mapped{$path});
      fatal("performance workload requirement/test does not own covered path: $id/$path")
        unless $mapped{$path}{requirement} eq $member->{meta}{requirement}
          && $mapped{$path}{test} eq $member->{meta}{test};
      $covered{$path} = $id;
      $assigned{$path} = 'C';
    }
  }
  for my $path (keys %$nonimpact) {
    fatal("performance non-measured scope path is outside implementation map: $path")
      unless exists($mapped{$path});
    fatal("performance C/N scope overlaps: $path") if exists($assigned{$path});
    $assigned{$path} = 'N';
  }
  my $self = "$spec/performance-manifest-v1.tsv";
  fatal('performance manifest self-authority must be N delivery-evidence-only')
    unless exists($nonimpact->{$self})
      && $nonimpact->{$self} eq 'delivery-evidence-only';
  fatal('performance C/N scope does not exactly partition the implementation map')
    unless keys(%assigned) == keys(%mapped)
      && !grep { !exists($assigned{$_}) } keys %mapped;

  for my $id (sort { use bytes; $a cmp $b } keys %$all) {
    my $member = $all->{$id};
    my $mode = $member->{meta}{mode};
    for my $path (sort { use bytes; $a cmp $b } @{$member->{coverage}}) {
      my $base_entry = optional_git_entry_at(
        $root, $base, $path, 'performance implementation-base C path');
      fatal("new-component performance C path exists in implementation base: $id/$path")
        if $mode eq 'new-component' && defined($base_entry);
      fatal("comparative performance C path is absent from implementation base: $id/$path")
        if $mode eq 'comparative' && !defined($base_entry);
    }
  }

  my ($test_raw) = git_blob_at($root, $checkpoint, "$spec/test-manifest-v2.tsv");
  markdown_text($test_raw, 'test manifest v2');
  my @test_line = split /\n/, $test_raw, -1;
  fatal('test-manifest-v2 must end with one LF') unless pop(@test_line) eq q{};
  fatal('test-manifest-v2 header mismatch') unless shift(@test_line) eq "test\trole\tpath";
  fatal('test-manifest-v2 row count exceeds cap')
    if @test_line > $MAX_TEST_MANIFEST_ROWS;
  my %input;
  for my $line (@test_line) {
    verifier_deadline_guard();
    my ($test, $role, $path) = split /\t/, $line, -1;
    fatal('test-manifest-v2 row malformed')
      unless defined($path) && $test =~ /\A$TEST_RE\z/
        && $role =~ /\A(?:test-logic|sut|fixture|transitive)\z/;
    safe_rel($path, 'test manifest input');
    fatal("test manifest input role conflict: $test/$path")
      if exists($input{$test}{$path}) && $input{$test}{$path} ne $role;
    $input{$test}{$path} = $role;
  }
  for my $id (sort keys %$all) {
    my $member = $all->{$id};
    my $test = $member->{meta}{test};
    fatal("performance workload TestId has no test manifest inputs: $id")
      unless $input{$test} && keys %{$input{$test}};
    my %dataset = map { $_->{path} => 1 } @{$member->{dataset}};
    my @argv = map { $_->{raw} } @{$member->{argv}};
    fatal("performance workload argv is empty: $id") unless @argv;
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
      my $entry = optional_git_entry_at(
        $root, $checkpoint, $argv[1], 'performance system interpreter script');
      fatal("performance system interpreter script is not a regular checkpoint blob: $id/$argv[1]")
        unless defined($entry)
          && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
      fatal("performance repo-relative argv lacks exact D binding: $id/$argv[1]")
        unless $dataset{$argv[1]};
      fatal("performance argv code path is not same-TestId test-logic: $id/$argv[1]")
        unless ($input{$test}{$argv[1]} // q{}) eq 'test-logic';
      $first_operand = 2;
    } else {
      safe_rel($argv[0], "performance repo executable: $id/argv[0]");
      my $entry = optional_git_entry_at(
        $root, $checkpoint, $argv[0], 'performance repo executable');
      fatal("repo performance executable is not a 100755 checkpoint blob: $id/$argv[0]")
        unless defined($entry) && $entry->{mode} eq '100755';
      fatal("performance repo-relative argv lacks exact D binding: $id/$argv[0]")
        unless $dataset{$argv[0]};
      fatal("performance argv code path is not same-TestId test-logic: $id/$argv[0]")
        unless ($input{$test}{$argv[0]} // q{}) eq 'test-logic';
      $first_operand = 1;
    }
    for my $i ($first_operand .. $#argv) {
      my $repo_path = $argv[$i];
      fatal("absolute performance argv operand is forbidden: $id/argv[$i]")
        if $repo_path =~ m{\A/};
      my $entry;
      if (index($repo_path, q{/}) >= 0) {
        safe_rel($repo_path, "performance slash-bearing argv operand: $id/argv[$i]");
        $entry = optional_git_entry_at(
          $root, $checkpoint, $repo_path, 'performance slash-bearing argv operand');
        fatal("performance slash-bearing argv operand is not a regular checkpoint blob: $id/$repo_path")
          unless defined($entry)
            && ($entry->{mode} eq '100644' || $entry->{mode} eq '100755');
      } else {
        next unless canonical_root_path_candidate($repo_path);
        $entry = optional_git_entry_at(
          $root, $checkpoint, $repo_path, 'performance checkpoint argv operand');
        next unless defined($entry);
        fatal("performance argv operand is not a regular checkpoint blob: $id/$repo_path")
          unless $entry->{mode} eq '100644' || $entry->{mode} eq '100755';
      }
      fatal("performance repo-relative argv lacks exact D binding: $id/$repo_path")
        unless $dataset{$repo_path};
      fatal("performance argv path is not declared under the workload TestId: $id/$repo_path")
        unless exists($input{$test}{$repo_path});
    }
    for my $dataset (@{$member->{dataset}}) {
      fatal("performance dataset is not declared under the workload TestId: $id/$dataset->{path}")
        unless $input{$test}{$dataset->{path}};
    }
    for my $path (@{$member->{coverage}}) {
      fatal("performance C path is not declared under the workload TestId: $id/$path")
        unless $input{$test}{$path};
      fatal("performance C path is not a same-TestId SUT: $id/$path")
        unless $input{$test}{$path} eq 'sut';
      fatal("performance C path lacks exact D binding: $id/$path")
        unless $dataset{$path};
    }
  }
}

# Mirror the producer's immutable execution-closure envelope independently.  Candidate sizes are
# already content-bound by every workload artifact below; summing one canonical declaration per
# path avoids rereading the candidate union here.  Comparative base sizes and modes are not present
# in the artifact, so resolve those exact blobs now and reject any closure the producer could not
# have materialized.
sub verify_performance_execution_envelope {
  my ($root, $checkpoint, $base, $manifest) = @_;
  my (%candidate, %base_path);
  my ($candidate_total, $base_total) = (0, 0);
  for my $id (sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}}) {
    my $workload = $manifest->{all_workloads}{$id};
    for my $dataset (sort { use bytes; $a->{path} cmp $b->{path} }
        @{$workload->{dataset}}) {
      my $path = $dataset->{path};
      my $identity = join("\t", @$dataset{qw(mode size sha)});
      if (exists($candidate{$path})) {
        fatal("performance candidate D path has conflicting authority: $path")
          unless $candidate{$path} eq $identity;
      } else {
        $candidate{$path} = $identity;
        $candidate_total += $dataset->{size};
        fatal('performance candidate execution closure exceeds 128 MiB')
          if $candidate_total > $MAX_TREE;
      }
      next unless $workload->{meta}{mode} eq 'comparative' && !$base_path{$path}++;
      my $entry = optional_git_entry_at(
        $root, $base, $path, 'performance base execution closure');
      fatal("performance base execution closure path is absent: $path")
        unless defined($entry);
      fatal("performance base execution closure path is not a regular blob: $path")
        unless $entry->{mode} eq '100644' || $entry->{mode} eq '100755';
      $base_total += length($entry->{raw});
      fatal('performance base execution closure exceeds 128 MiB')
        if $base_total > $MAX_TREE;
    }
  }
}

sub immutable_design_producer_paths {
  my ($root, $spec, $checkpoint, $base) = @_;
  my @producer = qw(scripts/implementation-tdd-verify.pl scripts/tdd-receipt-v1.pl);
  my @base_entry = map {
    optional_git_entry_at($root, $base, $_, 'immutable base TDD producer')
  } @producer;
  my $base_count = grep { defined($_) } @base_entry;
  fatal('immutable base TDD producer set is partial')
    if $base_count != 0 && $base_count != @producer;

  my $bootstrap_path = "$spec/producer-bootstrap-v1.tsv";
  my $bootstrap = optional_git_entry_at(
    $root, $checkpoint, $bootstrap_path, 'producer bootstrap');
  if ($base_count == @producer) {
    fatal('producer bootstrap is forbidden when TDD producers exist in immutable base')
      if defined($bootstrap);
    for my $i (0 .. $#producer) {
      fatal("immutable base TDD producer mode must be 100644: $producer[$i]")
        unless $base_entry[$i]{mode} eq '100644';
      my $candidate = optional_git_entry_at(
        $root, $checkpoint, $producer[$i], 'checkpoint TDD producer');
      fatal("checkpoint TDD producer is missing: $producer[$i]") unless defined($candidate);
      fatal("checkpoint TDD producer mode must be 100644: $producer[$i]")
        unless $candidate->{mode} eq '100644';
      fatal("checkpoint TDD producer differs from immutable base: $producer[$i]")
        unless $candidate->{raw} eq $base_entry[$i]{raw};
    }
    return ();
  }

  fatal('TDD producers are absent from immutable base and producer-bootstrap-v1.tsv is missing')
    unless defined($bootstrap);
  fatal('producer-bootstrap-v1.tsv mode must be 100644')
    unless $bootstrap->{mode} eq '100644';
  my @line = split /\n/, $bootstrap->{raw}, -1;
  fatal('producer-bootstrap-v1.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('producer-bootstrap-v1.tsv header mismatch')
    unless @line && shift(@line) eq "path\tmode\tsha256";
  fatal('producer-bootstrap-v1.tsv producer set mismatch') unless @line == @producer;
  for my $i (0 .. $#producer) {
    my @column = split /\t/, $line[$i], -1;
    fatal('producer-bootstrap-v1.tsv row malformed')
      unless @column == 3 && $column[0] eq $producer[$i]
        && $column[1] eq '100644' && $column[2] =~ /\A$ROOT_RE\z/;
    my $candidate = optional_git_entry_at(
      $root, $checkpoint, $producer[$i], 'checkpoint TDD producer');
    fatal("checkpoint TDD producer is missing: $producer[$i]") unless defined($candidate);
    fatal("checkpoint TDD producer mode must be 100644: $producer[$i]")
      unless $candidate->{mode} eq '100644';
    fatal("checkpoint TDD producer differs from reviewed bootstrap: $producer[$i]")
      unless sha256_hex($candidate->{raw}) eq $column[2];
  }
  return ($bootstrap_path);
}

sub immutable_design_root {
  my ($root, $spec, $checkpoint, $base) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT, 'ls-tree', '-r', '-z', '--full-name',
    $checkpoint, '--', "$spec/decisions/");
  my @record = split /\x00/, $raw, -1;
  fatal('checkpoint decision listing is not NUL terminated') unless pop(@record) eq q{};
  fatal('checkpoint decision set is empty') unless @record;
  my @decision;
  for my $record (@record) {
    my ($mode, $type, undef, $path) =
      $record =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t(.*)\z/s;
    fatal('checkpoint decision entry malformed') unless defined($path);
    fatal("checkpoint decision path outside closed set: $path")
      unless $path =~ /\A\Q$spec\E\/decisions\/AD-[0-9]{3}\.md\z/;
    fatal("checkpoint decision is not a 100644 blob: $path")
      unless $mode eq '100644' && $type eq 'blob';
    push @decision, $path;
  }
  my @producer_path = immutable_design_producer_paths(
    $root, $spec, $checkpoint, $base);
  my @path = ("$spec/spec.md", "$spec/plan.md", "$spec/roadmap-handoff.md",
    "$spec/traceability.tsv", "$spec/sdd-changelog.tsv", @decision, @producer_path);
  my $manifest = "HARNESS-DESIGN-ROOT-V1\n";
  for my $path (sort { use bytes; $a cmp $b } @path) {
    my ($bytes) = git_blob_at($root, $checkpoint, $path);
    $manifest .= join("\t", 'F', $path, '100644', length($bytes), sha256_hex($bytes)) . "\n";
  }
  fatal('immutable Design-Root manifest exceeds 64 MiB') if length($manifest) > $MAX_SET;
  return (sha256_hex($manifest), \@path);
}

sub immutable_implementation_root {
  my ($root, $spec, $checkpoint, $implementation, $design_path) = @_;
  my $delta = committed_delta($root, $implementation->{base}, $checkpoint);
  my %excluded = map { $_ => 1 } (
    @$design_path,
    "$spec/state.md",
    "$spec/audit.md",
    "$spec/reviews/architecture-critical-review.md",
    "$spec/reviews/critical-code-review.md",
    "$spec/reviews/performance-review.md",
    "$spec/checklists/requirement-evidence.md",
  );
  my @eligible = sort { use bytes; $a cmp $b } grep { !$excluded{$_} } keys %$delta;
  fatal('immutable implementation delta is empty') unless @eligible;
  my $manifest = "HARNESS-IMPLEMENTATION-ROOT-V1\n"
    . "base\t$implementation->{base}\n"
    . "design\t$implementation->{design}\n";
  my $total = 0;
  for my $path (@eligible) {
    my $d = $delta->{$path};
    if ($d->{status} eq 'D') {
      $manifest .= "D\t$path\n";
      next;
    }
    fatal("immutable implementation mode unsupported: $path")
      unless $d->{newmode} eq '100644' || $d->{newmode} eq '100755';
    my ($bytes, $mode) = git_entry_at($root, $checkpoint, $path);
    fatal("immutable implementation mode mismatch: $path") unless $mode eq $d->{newmode};
    $total += length($bytes);
    fatal('immutable Implementation-Root set exceeds 64 MiB') if $total > $MAX_SET;
    $manifest .= join("\t", 'F', $path, $mode, length($bytes), sha256_hex($bytes)) . "\n";
  }
  fatal('immutable Implementation-Root manifest exceeds 64 MiB') if length($manifest) > $MAX_SET;
  return sha256_hex($manifest);
}

sub verify_retained_roots {
  my ($root, $spec, $checkpoint, $implementation) = @_;
  my ($design, $design_path) = immutable_design_root(
    $root, $spec, $checkpoint, $implementation->{base});
  fatal('retained Design-Root does not recompute from immutable C')
    unless $design eq $implementation->{design};
  my $implementation_root =
    immutable_implementation_root($root, $spec, $checkpoint, $implementation, $design_path);
  fatal('retained Implementation-Root does not recompute from immutable C')
    unless $implementation_root eq $implementation->{root};
}

sub median_value {
  my (@value) = sort { $a <=> $b } @_;
  return $value[int(@value / 2)];
}

sub range_bps_value {
  my (@value) = sort { $a <=> $b } @_;
  my $mid = median_value(@value);
  fatal('performance median must be positive') unless $mid > 0;
  my $num = ($value[-1] - $value[0]) * 10_000;
  return int(($num + $mid - 1) / $mid);
}

sub argv_digest {
  my ($rows) = @_;
  my $manifest = "HARNESS-PERFORMANCE-ARGV-V1\n";
  my @argv;
  my $total = 0;
  for my $i (0 .. $#$rows) {
    my $row = $rows->[$i];
    fatal('performance argv row arity mismatch') unless @$row == 3;
    my ($index, $size, $hex) = @$row;
    fatal('performance argv index is not contiguous') unless $index eq "$i";
    valid_uint($size) or fatal('performance argv byte-size malformed');
    fatal('performance argv hex malformed') unless $hex =~ /\A(?:[0-9a-f]{2})*\z/;
    my $raw = pack('H*', $hex);
    fatal('performance argv byte-size mismatch') unless length($raw) == $size;
    fatal('performance argv contains control byte') if $raw =~ /[\x00-\x1f\x7f]/;
    $total += length($raw);
    fatal('performance argv exceeds byte cap') if $total > $MAX_ARG_BYTES;
    push @argv, $raw;
    $manifest .= join("\t", 'A', $i, length($raw), $hex) . "\n";
  }
  fatal('performance argv is empty') unless @argv;
  if ($argv[0] =~ m{\A/}) {
    fatal('performance argv executable is outside portable allowlist')
      unless $SYSTEM_INTERPRETER{$argv[0]};
  } else {
    fatal('repo performance argv[0] must use ./ canonical form') unless $argv[0] =~ s{\A\./}{};
    safe_rel($argv[0], 'performance executable');
  }
  return (sha256_hex($manifest), \@argv);
}

sub dataset_digest {
  my ($root, $rows, $candidate, $base, $covered) = @_;
  fatal('performance dataset is empty') unless @$rows;
  fatal('performance artifact dataset row count exceeds cap')
    if @$rows > $MAX_DATASET_ROWS;
  my $manifest = "HARNESS-PERFORMANCE-DATASET-V1\n";
  my ($prior, %seen);
  for my $row (@$rows) {
    verifier_deadline_guard();
    fatal('performance dataset row arity mismatch') unless @$row == 4;
    my ($path, $mode, $size, $sha) = @$row;
    safe_rel($path, 'performance dataset path');
    fatal('performance dataset path duplicated') if $seen{$path}++;
    fatal('performance dataset is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $path };
    fatal('performance dataset mode malformed') unless $mode eq '100644' || $mode eq '100755';
    valid_uint($size) or fatal('performance dataset byte-size malformed');
    fatal('performance dataset sha256 malformed') unless $sha =~ /\A$ROOT_RE\z/;
    my ($candidate_raw, $candidate_mode) = git_entry_at($root, $candidate, $path);
    fatal("candidate dataset mode/size/digest mismatch: $path")
      unless $candidate_mode eq $mode && length($candidate_raw) == $size
        && sha256_hex($candidate_raw) eq $sha;
    if (defined($base) && !$covered->{$path}) {
      my ($base_raw, $base_mode) = git_entry_at($root, $base, $path);
      fatal("comparative base/candidate dataset mismatch: $path")
        unless $base_mode eq $mode && $base_raw eq $candidate_raw;
    }
    $manifest .= join("\t", 'F', $path, $mode, $size, $sha) . "\n";
    $prior = $path;
  }
  return sha256_hex($manifest);
}

sub verify_process_workload {
  my ($text, $checkpoint, $implementation, $receipt, $root, $spec,
    $workload, $expected_id) = @_;
  fatal('performance workload artifact exceeds derived-artifact hard cap')
    if length($text) > $MAX_DERIVED_ARTIFACT;
  my @order = qw(Schema Producer Producer-Version Producer-SHA256 Workload-ID Manifest-SHA256
    Requirement Test-ID Mode Metric Checkpoint-C Unit Raw-Samples-SHA256 Scope-Root C-Path-Count
    N-Path-Count Dependency-Probe-Policy Dependency-Probe-Count
    Base Candidate-Tree Base-Tree Implementation-Root Implementation-Actor Implementation-Attempt
    Reviewer-Actor Reviewer-Attempt Snapshot-Policy Environment-Class Environment-SHA256
    Command-SHA256 Dataset-SHA256 Repetitions Timeout-Seconds Variance-Budget-BPS
    Absolute-Budget-Us Regression-Budget-BPS Base-Median-Us Candidate-Median-Us
    Base-Variance-BPS Candidate-Variance-BPS Verdict);
  my $m = metadata($text, \@order, 'performance workload result');
  fatal('performance workload result schema mismatch')
    unless $m->{Schema} eq 'performance-workload-result-v1';
  fatal('performance process producer mismatch')
    unless $m->{Producer} eq 'performance-process-v1' && $m->{'Producer-Version'} eq '1';
  fatal('performance process producer digest is stale or forged')
    unless $m->{'Producer-SHA256'} eq producer_sha($root, $checkpoint);
  fatal('performance process receipt producer mismatch')
    unless $receipt->{producer} eq $m->{'Producer-SHA256'};
  fatal('performance workload ID mismatch')
    unless $m->{'Workload-ID'} =~ /\A$WORKLOAD_RE\z/
      && $expected_id eq $m->{'Workload-ID'};
  fatal('performance manifest authority mismatch')
    unless $m->{'Manifest-SHA256'} eq $workload->{manifest_sha}
      && $receipt->{manifest} eq $workload->{manifest_sha};
  fatal('performance workload requirement/TestId mismatch')
    unless $m->{Requirement} eq $workload->{meta}{requirement}
      && $m->{'Test-ID'} eq $workload->{meta}{test};
  fatal('performance process mode malformed')
    unless $m->{Mode} eq $workload->{meta}{mode};
  fatal('performance process metric mismatch') unless $m->{Metric} eq 'wall-clock-us';
  fatal('performance process unit mismatch') unless $m->{Unit} eq 'us';
  fatal('performance scope authority mismatch')
    unless $m->{'Scope-Root'} eq $workload->{scope_root}
      && $m->{'C-Path-Count'} eq $workload->{c_count}
      && $m->{'N-Path-Count'} eq $workload->{n_count};
  fatal('performance dependency probe policy mismatch')
    unless $m->{'Dependency-Probe-Policy'} eq 'execution-dependency-probe-v1';
  valid_uint($m->{'Dependency-Probe-Count'})
    or fatal('performance dependency probe count malformed');
  fatal('performance dependency probe count differs from immutable C set')
    unless $m->{'Dependency-Probe-Count'} == @{$workload->{coverage}};
  fatal('performance checkpoint mismatch') unless $m->{'Checkpoint-C'} eq $checkpoint;
  fatal('performance Implementation-Root mismatch')
    unless $m->{'Implementation-Root'} eq $implementation->{root};
  fatal('performance Implementation-Actor mismatch')
    unless $m->{'Implementation-Actor'} eq $implementation->{actor};
  fatal('performance Implementation-Attempt mismatch')
    unless $m->{'Implementation-Attempt'} eq $implementation->{attempt};
  fatal('performance review actor mismatches receipt') unless $m->{'Reviewer-Actor'} eq $receipt->{actor};
  fatal('performance review attempt mismatches receipt')
    unless $m->{'Reviewer-Attempt'} eq $receipt->{attempt};
  fatal('performance process policy makes an unsupported isolation claim')
    unless $m->{'Snapshot-Policy'} eq 'mutation-evident-git-materialization-v1';
  fatal('performance environment class mismatch')
    unless $m->{'Environment-Class'} eq 'trusted-host-process-v1'
      && $m->{'Environment-SHA256'} eq sha256_hex($ENV_MANIFEST);
  fatal('performance timeout mismatch') unless $m->{'Timeout-Seconds'} eq '30';
  fatal('performance Verdict must be PASS') unless $m->{Verdict} eq 'PASS';
  valid_uint($m->{Repetitions}) && $m->{Repetitions} >= 3 && $m->{Repetitions} <= 21
    && $m->{Repetitions} % 2 == 1 or fatal('performance repetitions malformed');
  fatal('performance repetitions differ from immutable workload')
    unless $m->{Repetitions} eq $workload->{meta}{repetitions};
  valid_uint($m->{'Variance-Budget-BPS'}) && $m->{'Variance-Budget-BPS'} <= 1_000_000
    or fatal('performance variance budget malformed');
  fatal('performance variance budget differs from immutable workload')
    unless $m->{'Variance-Budget-BPS'} eq $workload->{meta}{variance};
  valid_uint($m->{'Absolute-Budget-Us'}) && $m->{'Absolute-Budget-Us'} > 0
    && $m->{'Absolute-Budget-Us'} <= 30_000_000
    or fatal('performance absolute budget malformed');
  fatal('performance absolute budget differs from immutable workload')
    unless $m->{'Absolute-Budget-Us'} eq $workload->{meta}{absolute};
  fatal('performance Candidate-Tree mismatch')
    unless $m->{'Candidate-Tree'} eq commit_exact($root, $checkpoint, 'performance candidate');

  my $base;
  if ($m->{Mode} eq 'comparative') {
    fatal('comparative performance base mismatch') unless $m->{Base} eq $implementation->{base};
    $base = $m->{Base};
    fatal('comparative Base-Tree mismatch')
      unless $m->{'Base-Tree'} eq commit_exact($root, $base, 'performance base');
    valid_uint($m->{'Regression-Budget-BPS'}) && $m->{'Regression-Budget-BPS'} <= 1_000_000
      or fatal('comparative regression budget malformed');
    fatal('performance regression budget differs from immutable workload')
      unless $m->{'Regression-Budget-BPS'} eq $workload->{meta}{regression};
  } else {
    fatal('new-component performance must not fabricate a base or regression budget')
      unless $m->{Base} eq q{-} && $m->{'Base-Tree'} eq q{-}
        && $m->{'Regression-Budget-BPS'} eq q{-}
        && $m->{'Base-Median-Us'} eq q{-} && $m->{'Base-Variance-BPS'} eq q{-};
  }
  my $argv_rows = table_after($text, 'Command argv',
    '| index | byte-size | hex |', '|---:|---:|---|', 'performance process review');
  my ($command_sha) = argv_digest($argv_rows);
  fatal('performance command digest mismatch') unless $command_sha eq $m->{'Command-SHA256'};
  fatal('performance command differs from immutable workload argv')
    unless $command_sha eq workload_command_sha($workload);
  my $dataset_rows = table_after($text, 'Dataset',
    '| path | mode | byte-size | sha256 |', '|---|---:|---:|---|', 'performance process review');
  my %covered = map { $_ => 1 } @{$workload->{coverage}};
  my $dataset_sha = dataset_digest($root, $dataset_rows, $checkpoint, $base, \%covered);
  fatal('performance dataset digest mismatch') unless $dataset_sha eq $m->{'Dataset-SHA256'};
  fatal('performance dataset row count differs from immutable workload')
    unless @$dataset_rows == @{$workload->{dataset}};
  for my $i (0 .. $#{$workload->{dataset}}) {
    my $expected = $workload->{dataset}[$i];
    fatal('performance dataset rows differ from immutable workload')
      unless join("\t", @{$dataset_rows->[$i]})
        eq join("\t", @$expected{qw(path mode size sha)});
  }
  my $machine_prefix = "## Machine samples\n\n" . (q{`} x 3) . "text\n";
  my $machine_at = index($text, $machine_prefix);
  fatal('performance machine sample block missing') if $machine_at < 0;
  fatal('performance machine sample block duplicated')
    if index($text, $machine_prefix, $machine_at + 1) >= 0;
  my $sample_raw = substr($text, $machine_at + length($machine_prefix));
  my $machine_end = (q{`} x 3) . "\n";
  fatal('performance machine sample block is not the canonical final section')
    unless $sample_raw =~ s/\Q$machine_end\E\z//;
  fatal('performance raw sample digest mismatch')
    unless sha256_hex($sample_raw) eq $m->{'Raw-Samples-SHA256'};
  my @sample_line = split /\n/, $sample_raw, -1;
  fatal('performance raw samples must end with one LF') unless pop(@sample_line) eq q{};
  fatal('performance raw sample schema mismatch')
    unless @sample_line && shift(@sample_line) eq 'HARNESS-PERFORMANCE-SAMPLES-V1';
  my (%sample, %probe);
  my @probe_path;
  my $probe_phase = 0;
  for my $line (@sample_line) {
    my @row = split /\t/, $line, -1;
    if (@row && $row[0] eq 'S') {
      fatal('performance sample appears after dependency probes') if $probe_phase;
      fatal('performance sample row arity/schema mismatch') unless @row == 7;
      my (undef, $series, $repetition, $duration, $exit, $stdout, $stderr) = @row;
      fatal('performance sample series malformed')
        unless $series eq 'base' || $series eq 'candidate';
      fatal('new-component artifact contains a fabricated base series')
        if $m->{Mode} eq 'new-component' && $series eq 'base';
      valid_uint($repetition) && $repetition >= 1 && $repetition <= $m->{Repetitions}
        or fatal('performance sample repetition malformed');
      fatal('performance sample duplicated') if exists($sample{$series}{$repetition});
      valid_uint($duration) && $duration > 0 && $duration <= 30_000_000
        or fatal('performance sample duration malformed');
      fatal('performance sample is not a successful process exit') unless $exit eq '0';
      fatal('performance sample stream digest malformed')
        unless $stdout =~ /\A$ROOT_RE\z/ && $stderr =~ /\A$ROOT_RE\z/;
      fatal("performance $series sample exceeds absolute performance budget")
        if $duration > $m->{'Absolute-Budget-Us'};
      $sample{$series}{$repetition} = {
        duration => $duration, stdout => $stdout, stderr => $stderr,
      };
      next;
    }
    if (@row && $row[0] eq 'P') {
      $probe_phase = 1;
      fatal('performance dependency probe row arity mismatch') unless @row == 6;
      my (undef, $path, $duration, $exit, $stdout, $stderr) = @row;
      safe_rel($path, 'performance dependency probe path');
      fatal('performance dependency probe duplicated') if exists($probe{$path});
      valid_uint($duration) && $duration > 0 && $duration <= 30_000_000
        or fatal('performance dependency probe duration malformed');
      valid_uint($exit) && $exit <= 255
        or fatal('performance dependency probe exit malformed');
      fatal('performance dependency probe stream digest malformed')
        unless $stdout =~ /\A$ROOT_RE\z/ && $stderr =~ /\A$ROOT_RE\z/;
      fatal("performance dependency probe exceeds absolute performance budget: $path")
        if $duration > $m->{'Absolute-Budget-Us'};
      $probe{$path} = {
        duration => $duration, exit => $exit, stdout => $stdout, stderr => $stderr,
      };
      push @probe_path, $path;
      next;
    }
    fatal('performance sample row arity/schema mismatch');
  }
  for my $series ($m->{Mode} eq 'comparative' ? qw(base candidate) : qw(candidate)) {
    fatal("performance $series sample count mismatch")
      unless keys(%{$sample{$series} // {}}) == $m->{Repetitions};
    my @s = map { $sample{$series}{$_} } 1 .. $m->{Repetitions};
    my $stdout = $s[0]{stdout}; my $stderr = $s[0]{stderr};
    fatal("performance $series output is unstable")
      if grep { $_->{stdout} ne $stdout || $_->{stderr} ne $stderr } @s;
    my $median = median_value(map { $_->{duration} } @s);
    my $variance = range_bps_value(map { $_->{duration} } @s);
    fatal("performance $series median metadata mismatch")
      unless $m->{ucfirst($series) . '-Median-Us'} eq "$median";
    fatal("performance $series variance metadata mismatch")
      unless $m->{ucfirst($series) . '-Variance-BPS'} eq "$variance";
    fatal("performance $series variance exceeds budget")
      if $variance > $m->{'Variance-Budget-BPS'};
  }
  my $candidate_median = $m->{'Candidate-Median-Us'};
  fatal('candidate median exceeds absolute performance budget')
    if $candidate_median > $m->{'Absolute-Budget-Us'};
  if ($m->{Mode} eq 'comparative') {
    my $base_median = $m->{'Base-Median-Us'};
    fatal('comparative base and candidate outputs differ')
      unless $sample{base}{1}{stdout} eq $sample{candidate}{1}{stdout}
        && $sample{base}{1}{stderr} eq $sample{candidate}{1}{stderr};
    fatal('candidate regression exceeds declared budget')
      if $candidate_median > $base_median
        && ($candidate_median - $base_median) * 10_000
          > $base_median * $m->{'Regression-Budget-BPS'};
  }
  my @expected_probe = sort { use bytes; $a cmp $b } @{$workload->{coverage}};
  fatal('performance dependency probe set/count/order mismatch')
    unless @probe_path == @expected_probe
      && @probe_path == $m->{'Dependency-Probe-Count'};
  for my $i (0 .. $#expected_probe) {
    fatal('performance dependency probe set/count/order mismatch')
      unless $probe_path[$i] eq $expected_probe[$i];
    my $p = $probe{$expected_probe[$i]};
    fatal("performance execution dependency is unproven for path: $expected_probe[$i]")
      if $p->{exit} == 0
        && $p->{stdout} eq $sample{candidate}{1}{stdout}
        && $p->{stderr} eq $sample{candidate}{1}{stderr};
  }
  my $canonical = canonical_metadata_block(q{}, $m, \@order)
    . canonical_table_block('Command argv', '| index | byte-size | hex |',
      '|---:|---:|---|', $argv_rows)
    . "\n"
    . canonical_table_block('Dataset', '| path | mode | byte-size | sha256 |',
      '|---|---:|---:|---|', $dataset_rows)
    . "\n## Machine samples\n\n" . (q{`} x 3) . "text\n"
    . $sample_raw . (q{`} x 3) . "\n";
  fatal('performance workload result is not canonical') unless $text eq $canonical;
  return $m->{'Raw-Samples-SHA256'};
}

sub verify_process_performance {
  my ($text, $checkpoint, $implementation, $receipt, $root, $spec) = @_;
  fatal('performance aggregate artifact exceeds derived-artifact hard cap')
    if length($text) > $MAX_DERIVED_ARTIFACT;
  my @marker;
  while ($text =~ /^## Workload ($WORKLOAD_RE)\n\n/mg) {
    verifier_deadline_guard();
    push @marker, { id => $1, start => $-[0], content => $+[0] };
    fatal('performance process review workload marker count exceeds cap')
      if @marker > $MAX_WORKLOADS;
  }
  fatal('performance process review has no workload results') unless @marker;
  my $header = substr($text, 0, $marker[0]{start});
  fatal('performance process review heading mismatch')
    unless $header =~ /\A# Performance process review v1\n\n/;
  my @required = qw(Schema Producer Producer-Version Producer-SHA256 Manifest-SHA256
    Workload-Count Raw-Samples-SHA256 Checkpoint-C Scope-Root C-Path-Count N-Path-Count
    Aggregate-Timeout-Seconds Dependency-Probe-Policy
    Candidate-Tree Implementation-Root
    Implementation-Actor Implementation-Attempt Reviewer-Actor Reviewer-Attempt Snapshot-Policy
    Environment-Class Environment-SHA256 Verdict);
  my $m = metadata($header, \@required, 'performance process review');
  fatal('performance process review header is not canonical')
    unless $header eq canonical_metadata_block(
      "# Performance process review v1\n\n", $m, \@required);
  fatal('performance process schema mismatch')
    unless $m->{Schema} eq 'performance-process-review-v1';
  fatal('performance process producer mismatch')
    unless $m->{Producer} eq 'performance-process-v1' && $m->{'Producer-Version'} eq '1';
  fatal('performance process producer digest is stale or forged')
    unless $m->{'Producer-SHA256'} eq producer_sha($root, $checkpoint)
      && $receipt->{producer} eq $m->{'Producer-SHA256'};
  my $manifest = performance_workload_at($root, $spec, $checkpoint, undef);
  verify_workload_binding($root, $spec, $checkpoint, $implementation->{base}, $manifest);
  verify_performance_execution_envelope(
    $root, $checkpoint, $implementation->{base}, $manifest);
  fatal('performance manifest authority mismatch')
    unless $m->{'Manifest-SHA256'} eq $manifest->{manifest_sha}
      && $receipt->{manifest} eq $manifest->{manifest_sha};
  fatal('performance aggregate scope authority mismatch')
    unless $m->{'Scope-Root'} eq $manifest->{scope_root}
      && $m->{'C-Path-Count'} eq $manifest->{c_count}
      && $m->{'N-Path-Count'} eq $manifest->{n_count};
  my @expected = sort { use bytes; $a cmp $b } keys %{$manifest->{all_workloads}};
  valid_uint($m->{'Workload-Count'}) && $m->{'Workload-Count'} > 0
    or fatal('performance workload count malformed');
  fatal('performance workload count mismatch')
    unless $m->{'Workload-Count'} == @expected
      && $receipt->{workloads} == @expected && @marker == @expected;
  fatal('performance checkpoint mismatch') unless $m->{'Checkpoint-C'} eq $checkpoint;
  fatal('performance aggregate timeout mismatch')
    unless $m->{'Aggregate-Timeout-Seconds'} eq "$AGGREGATE_TIMEOUT";
  fatal('performance aggregate dependency probe policy mismatch')
    unless $m->{'Dependency-Probe-Policy'} eq 'execution-dependency-probe-v1';
  fatal('performance Candidate-Tree mismatch')
    unless $m->{'Candidate-Tree'} eq commit_exact($root, $checkpoint, 'performance candidate');
  fatal('performance Implementation-Root mismatch')
    unless $m->{'Implementation-Root'} eq $implementation->{root};
  fatal('performance implementation identity mismatch')
    unless $m->{'Implementation-Actor'} eq $implementation->{actor}
      && $m->{'Implementation-Attempt'} eq $implementation->{attempt};
  fatal('performance reviewer identity mismatches receipt')
    unless $m->{'Reviewer-Actor'} eq $receipt->{actor}
      && $m->{'Reviewer-Attempt'} eq $receipt->{attempt};
  fatal('performance process policy makes an unsupported isolation claim')
    unless $m->{'Snapshot-Policy'} eq 'mutation-evident-git-materialization-v1';
  fatal('performance environment class mismatch')
    unless $m->{'Environment-Class'} eq 'trusted-host-process-v1'
      && $m->{'Environment-SHA256'} eq sha256_hex($ENV_MANIFEST);
  fatal('performance process Verdict must be PASS') unless $m->{Verdict} eq 'PASS';

  my $aggregate = "HARNESS-PERFORMANCE-AGGREGATE-SAMPLES-V1\n";
  for my $i (0 .. $#marker) {
    verifier_deadline_guard();
    fatal('performance workload result set is missing, duplicated, extra, or out of order')
      unless $marker[$i]{id} eq $expected[$i];
    my $end = $i == $#marker ? length($text) : $marker[$i + 1]{start};
    my $segment = substr($text, $marker[$i]{content}, $end - $marker[$i]{content});
    fatal('performance workload artifact exceeds derived-artifact hard cap')
      if length($segment) > $MAX_DERIVED_ARTIFACT;
    my %workload = %{$manifest->{all_workloads}{$expected[$i]}};
    $workload{manifest_sha} = $manifest->{manifest_sha};
    $workload{all_workloads} = $manifest->{all_workloads};
    $workload{nonimpact} = $manifest->{nonimpact};
    $workload{scope_root} = $manifest->{scope_root};
    $workload{c_count} = $manifest->{c_count};
    $workload{n_count} = $manifest->{n_count};
    my $sample_sha = verify_process_workload($segment, $checkpoint, $implementation,
      $receipt, $root, $spec, \%workload, $expected[$i]);
    $aggregate .= join("\t", 'W', $expected[$i], $sample_sha) . "\n";
  }
  fatal('performance aggregate raw sample digest mismatch')
    unless sha256_hex($aggregate) eq $m->{'Raw-Samples-SHA256'}
      && $receipt->{raw_samples} eq $m->{'Raw-Samples-SHA256'};
  return 'process';
}

sub profile_control_path {
  my ($spec, $path) = @_;
  return 1 if $path eq "$spec/state.md" || $path eq "$spec/audit.md";
  # Exact architecture-evidence-v1 control-plane set.  These paths describe and bind the
  # delivery itself; they are not product/runtime impact.  Keep this closed instead of treating
  # the whole SPEC_DIR as metadata, because an unknown executable, fixture, or future profile
  # artifact under SPEC_DIR must still make N/A fail closed.
  return 1 if $path eq "$spec/spec.md"
    || $path eq "$spec/plan.md"
    || $path eq "$spec/roadmap-handoff.md"
    || $path eq "$spec/traceability.tsv"
    || $path eq "$spec/sdd-changelog.tsv"
    || $path eq "$spec/reviews/architecture-critical-review.md"
    || $path eq "$spec/reviews/critical-code-review.md"
    || $path eq "$spec/reviews/performance-review.md"
    || $path eq "$spec/checklists/requirement-evidence.md";
  return 1 if $path =~ /\A\Q$spec\E\/decisions\/AD-[0-9]{3}\.md\z/;
  return 1 if $path eq "$spec/delivery-trace.tsv"
    || $path eq "$spec/implementation-map.tsv"
    || $path eq "$spec/delivery-changelog.tsv"
    || $path eq "$spec/test-manifest-v2.tsv"
    || $path eq "$spec/performance-manifest-v1.tsv";
  return 0;
}

sub narrative_nonruntime_path {
  my ($path) = @_;
  return 1 if $path eq 'README.md';
  return 1 if $path eq 'CHANGELOG.md';
  return 1 if $path =~ /\Adocs\/(?:narrative|explanations)\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md\z/;
  return 0;
}

sub nonruntime_impact_paths {
  my ($root, $spec, $base, $checkpoint) = @_;
  my $delta = committed_delta($root, $base, $checkpoint);
  my (@impact, @forbidden);
  for my $path (sort { use bytes; $a cmp $b } keys %$delta) {
    safe_rel($path, 'base-to-C path');
    next if profile_control_path($spec, $path);
    my $d = $delta->{$path};
    if (narrative_nonruntime_path($path)
        && ($d->{status} eq 'A' || $d->{status} eq 'M')
        && $d->{newmode} eq '100644'
        && ($d->{status} eq 'A' || $d->{oldmode} eq '100644')) {
      # Exact raw modes exclude executable blobs, symlinks, gitlinks, deletions and type changes.
      my (undef, $mode) = git_entry_at($root, $checkpoint, $path);
      if ($mode eq '100644') { push @impact, $path; next }
    }
    push @forbidden, $path;
  }
  fatal('performance/critical N/A misused for runtime or verification paths: '
    . join(q{,}, @forbidden)) if @forbidden;
  fatal('performance N/A has no concrete non-runtime impact path') unless @impact;
  return \@impact;
}

sub verify_na_performance {
  my ($text, $checkpoint, $implementation, $receipt, $root, $spec) = @_;
  my @required = qw(Schema Mode Checkpoint-C Base Implementation-Root Implementation-Actor
    Implementation-Attempt Reviewer-Actor Reviewer-Attempt Reason Impact-Path-Count Verdict);
  my $m = metadata($text, \@required, 'performance N/A review');
  fatal('performance N/A schema/mode mismatch')
    unless $m->{Schema} eq 'performance-review-na-v1' && $m->{Mode} eq 'n-a';
  fatal('performance N/A checkpoint/base mismatch')
    unless $m->{'Checkpoint-C'} eq $checkpoint && $m->{Base} eq $implementation->{base};
  fatal('performance N/A Implementation-Root mismatch')
    unless $m->{'Implementation-Root'} eq $implementation->{root};
  fatal('performance N/A implementation identity mismatch')
    unless $m->{'Implementation-Actor'} eq $implementation->{actor}
      && $m->{'Implementation-Attempt'} eq $implementation->{attempt};
  fatal('performance N/A reviewer identity mismatches receipt')
    unless $m->{'Reviewer-Actor'} eq $receipt->{actor}
      && $m->{'Reviewer-Attempt'} eq $receipt->{attempt};
  fatal('performance N/A requires a concrete reason')
    unless length($m->{Reason}) >= 12 && $m->{Reason} ne q{-};
  valid_uint($m->{'Impact-Path-Count'}) or fatal('performance N/A impact count malformed');
  fatal('performance N/A Verdict must be PASS') unless $m->{Verdict} eq 'PASS';
  my $rows = table_after($text, 'Non-runtime impact',
    '| path | classification | evidence |', '|---|---|---|', 'performance N/A review');
  fatal('performance N/A impact row count mismatch') unless @$rows == $m->{'Impact-Path-Count'};
  my $expected = nonruntime_impact_paths($root, $spec, $implementation->{base}, $checkpoint);
  fatal('performance N/A impact path-set count mismatch') unless @$rows == @$expected;
  for my $i (0 .. $#$expected) {
    my $row = $rows->[$i];
    fatal('performance N/A impact row arity mismatch') unless @$row == 3;
    fatal('performance N/A impact path-set mismatch') unless $row->[0] eq $expected->[$i];
    fatal('performance N/A classification mismatch') unless $row->[1] eq 'documentation-only';
    fatal('performance N/A row has no concrete evidence')
      unless $row->[2] =~ /[^[:space:]]/ && $row->[2] ne q{-};
  }
  return 'n-a';
}

sub verify_performance_review {
  my ($raw, $checkpoint, $implementation, $receipt, $root, $spec) = @_;
  fatal('performance aggregate artifact exceeds derived-artifact hard cap')
    if length($raw) > $MAX_DERIVED_ARTIFACT;
  markdown_text($raw, 'performance review');
  my $text = $raw;
  if ($text =~ /^- Schema: performance-process-review-v1$/m) {
    fatal('generic performance review-finish cannot authorize process evidence')
      unless ($receipt->{terminal_type} // q{}) eq 'process';
    return verify_process_performance($text, $checkpoint, $implementation, $receipt, $root, $spec);
  }
  if ($text =~ /^- Schema: performance-review-na-v1$/m) {
    fatal('specialized performance process receipt cannot authorize typed N/A')
      unless ($receipt->{terminal_type} // q{}) eq 'n-a';
    return verify_na_performance($text, $checkpoint, $implementation, $receipt, $root, $spec);
  }
  fatal('performance review schema is unknown or hand-authored executable evidence');
}

sub require_mandatory_evidence_transition {
  my ($d, $path, $label) = @_;
  return 1
    if $d->{status} eq 'A' && $d->{oldmode} eq '000000' && $d->{newmode} eq '100644';
  return 1
    if $d->{status} eq 'M' && $d->{oldmode} eq '100644' && $d->{newmode} eq '100644';
  fatal("$label Stage-4 evidence must be an added or replaced 100644 blob: $path");
}

sub build_envelope {
  my ($root, $spec, $checkpoint, $bound_mode) = @_;
  fatal('SPEC_DIR grammar mismatch')
    unless $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'git root');
  fatal('repo root is not canonical git toplevel') unless abs_path($top) eq $root;
  commit_exact($root, $checkpoint, 'checkpoint C');
  my $head = exact_line(git_capture($root, 4096, 'rev-parse', 'HEAD'), 'HEAD');
  my $committed_bound = $bound_mode && $head ne $checkpoint;
  if ($head ne $checkpoint) {
    fatal('checkpoint C must equal exact current HEAD for an unbound candidate') unless $bound_mode;
    commit_exact($root, $head, 'bound evidence checkpoint H');
    my $head_parents = exact_line(
      git_capture($root, 8192, 'rev-list', '--parents', '-n', '1', $head), 'H parents');
    my @head_parent = split / /, $head_parents;
    fatal('bound H must be the sole direct child transition from checkpoint C')
      unless @head_parent == 2 && $head_parent[0] eq $head && $head_parent[1] eq $checkpoint;
    fatal('bound H verification requires index tree equal immutable H')
      unless git_quiet($root, 'diff-index', '--cached', '--quiet', $head, '--');
  }
  my $parents = exact_line(git_capture($root, 8192, 'rev-list', '--parents', '-n', '1', $checkpoint),
    'checkpoint parents');
  my @parent = split / /, $parents;
  fatal('checkpoint C must be a non-root commit with exactly one parent')
    unless @parent == 2 && $parent[0] eq $checkpoint && $parent[1] =~ /\A$OID_RE\z/;

  my ($index_snapshot_dir, $index_snapshot) = authority_index_snapshot($root);
  local $ENV{GIT_INDEX_FILE} = $index_snapshot;
  my $index = index_entries($root);
  reject_nonstandard_index_flags($root, $index);
  my $delta = staged_delta($root, $checkpoint);
  my $state_path = "$spec/state.md";
  my $audit_path = "$spec/audit.md";
  if ($committed_bound) {
    committed_bound_worktree_metadata_only($root, $state_path, $audit_path);
  } else {
    fatal('live tracked bytes differ from prospective H index')
      unless tracked_bytes_match_index($root);
  }
  my @mandatory = (
    "$spec/reviews/critical-code-review.md",
    "$spec/reviews/performance-review.md",
    "$spec/checklists/requirement-evidence.md",
  );
  my %allowed_delta = map { $_ => 1 } ($state_path, $audit_path, @mandatory);
  for my $metadata_path ($state_path, $audit_path) {
    my $d = $delta->{$metadata_path} // fatal("prospective H omits modified metadata: $metadata_path");
    fatal("prospective H metadata delta malformed: $metadata_path")
      unless $d->{status} eq 'M' && $d->{oldmode} eq '100644' && $d->{newmode} eq '100644';
  }
  for my $path (keys %$delta) {
    fatal("post-C path is outside the frozen Stage-4 profile: $path")
      unless $allowed_delta{$path};
  }
  for my $path (@mandatory) {
    my $d = $delta->{$path} // fatal("prospective H omits mandatory evidence: $path");
    require_mandatory_evidence_transition($d, $path, 'prospective');
  }
  my @evidence_path = sort { use bytes; $a cmp $b } @mandatory;

  my %raw;
  my ($total, @manifest_row) = (0);
  for my $path (@evidence_path) {
    my $blob = index_blob($root, $index->{$path}, $path);
    my $live = safe_read($root, $path);
    fatal("live/index evidence bytes differ: $path") unless $live eq $blob;
    markdown_text($blob, "evidence artifact $path");
    $total += length($blob);
    fatal('EvidenceRoot set exceeds 64 MiB') if $total > $MAX_SET;
    $raw{$path} = $blob;
    push @manifest_row, join("\t", 'F', $path, '100644', length($blob), sha256_hex($blob)) . "\n";
  }
  my $manifest = $DOMAIN . "checkpoint\t$checkpoint\n" . join(q{}, @manifest_row);
  fatal('EvidenceRoot manifest exceeds 64 MiB') if length($manifest) > $MAX_SET;
  my $evidence_root = sha256_hex($manifest);

  my ($checkpoint_state) = git_blob_at($root, $checkpoint, $state_path);
  my ($checkpoint_audit) = git_blob_at($root, $checkpoint, $audit_path);
  my ($live_state, $live_audit, $helper_audit);
  if ($committed_bound) {
    # H is the evidence authority after quality-head.  Later state-machine transitions are
    # deliberately live metadata-only, so parse the exact H index while letting receipt helpers
    # observe the append-only live audit that extends H.
    safe_read($root, $state_path);
    $helper_audit = safe_read($root, $audit_path);
    $live_state = index_blob($root, $index->{$state_path}, $state_path);
    $live_audit = index_blob($root, $index->{$audit_path}, $audit_path);
    fatal('committed H audit is not an exact prefix of live receipt audit')
      unless length($helper_audit) >= length($live_audit)
        && substr($helper_audit, 0, length($live_audit)) eq $live_audit;
  } else {
    $live_state = safe_read($root, $state_path);
    $live_audit = safe_read($root, $audit_path);
    fatal('live/index state bytes differ')
      unless index_blob($root, $index->{$state_path}, $state_path) eq $live_state;
    fatal('live/index audit bytes differ')
      unless index_blob($root, $index->{$audit_path}, $audit_path) eq $live_audit;
    $helper_audit = $live_audit;
  }
  fatal('checkpoint C audit is not an exact byte prefix of prospective H audit')
    unless length($live_audit) > length($checkpoint_audit)
      && substr($live_audit, 0, length($checkpoint_audit)) eq $checkpoint_audit;
  my ($checkpoint_rows) = audit_rows($checkpoint_audit, 'checkpoint C');
  my ($live_rows) = audit_rows($live_audit, 'prospective H');
  my $implementation = parse_implementation($checkpoint_rows);
  my $checkpoint_cycle = checkpoint_quality_cycle($checkpoint_state, 'checkpoint C');
  authenticate_completed_checkpoint($root, $spec, $checkpoint, $checkpoint_state,
    $checkpoint_cycle, $implementation);
  verify_retained_roots($root, $spec, $checkpoint, $implementation);
  fatal('checkpoint C state Implementation-Root mismatch')
    unless state_field($checkpoint_state, 'Implementation-Root', 'checkpoint C') eq $implementation->{root};
  fatal('checkpoint C state Design-Root mismatch')
    unless state_field($checkpoint_state, 'Design-Root', 'checkpoint C') eq $implementation->{design};
  fatal('prospective H changed Implementation-Root')
    unless state_field($live_state, 'Implementation-Root', 'prospective H') eq $implementation->{root};
  fatal('prospective H changed Design-Root')
    unless state_field($live_state, 'Design-Root', 'prospective H') eq $implementation->{design};
  fatal('prospective H has premature Quality-HEAD')
    unless state_field($live_state, 'Quality-HEAD', 'prospective H') eq encode(q{UTF-8}, '—');
  my $live_eroot = state_field($live_state, 'Evidence-Root', 'prospective H');
  if ($bound_mode) {
    fatal('bound prospective H state Evidence-Root mismatch') unless $live_eroot eq $evidence_root;
  } else {
    fatal('unbound prospective H already has Evidence-Root') unless $live_eroot eq encode(q{UTF-8}, '—');
  }

  my ($final, $bind) = parse_quality_suffix($checkpoint_rows, $live_rows,
    $checkpoint, $bound_mode, $checkpoint_cycle, $implementation->{receipt_generation});
  if ($bound_mode) {
    fatal('evidence-bind root omits or changes prospective EvidenceRoot')
      unless $bind->{root} eq $evidence_root;
  }
  my $audit_sha = sha256_hex($helper_audit);
  my $critical_receipt = verify_receipt($root, $spec, $checkpoint, 'critical-code',
    $final->{'critical-code'}{attempt}, $audit_sha);
  for my $key (qw(attempt generation actor subject capability artifact sha256)) {
    fatal("critical-code helper/tail receipt mismatch: $key")
      unless $critical_receipt->{$key} eq $final->{'critical-code'}{$key};
  }
  fatal('critical-code receipt subject is not exact checkpoint C')
    unless $critical_receipt->{subject} eq $checkpoint;
  fatal('critical-code reviewer actor equals implementation actor')
    if $critical_receipt->{actor} eq $implementation->{actor};
  fatal('critical-code reviewer attempt equals implementation attempt')
    if $critical_receipt->{attempt} eq $implementation->{attempt};
  fatal('critical review artifact path is non-canonical')
    unless $critical_receipt->{artifact} eq $mandatory[0];
  fatal('critical receipt digest differs from prospective index')
    unless sha256_hex($raw{$mandatory[0]}) eq $critical_receipt->{sha256};
  my $performance_receipt = trusted_performance_terminal(
    $root, $spec, $checkpoint, $implementation, $final->{performance}, $audit_sha,
    $mandatory[1], $raw{$mandatory[1]});
  my $critical = verify_critical_review($raw{$mandatory[0]}, $checkpoint,
    $implementation, $critical_receipt, $root, $spec);
  my $performance_mode = verify_performance_review($raw{$mandatory[1]}, $checkpoint,
    $implementation, $performance_receipt, $root, $spec);
  my ($spec_raw) = git_blob_at($root, $checkpoint, "$spec/spec.md");
  my ($delivery_raw) = git_blob_at($root, $checkpoint, "$spec/delivery-trace.tsv");
  my $requirements = parse_spec_requirements($spec_raw);
  my $delivery = parse_delivery_contract($delivery_raw, $requirements);
  verify_requirement_evidence($raw{$mandatory[2]}, $checkpoint, $implementation,
    $requirements, $delivery, $root, $spec, $audit_sha, $critical);
  revalidate_immutable_cache_hits();
  revalidate_pins();
  return {
    manifest => $manifest, root => $evidence_root, checkpoint => $checkpoint,
    implementation => $implementation, critical => $critical_receipt,
    performance => $performance_receipt, performance_mode => $performance_mode,
    audit_sha => $audit_sha,
  };
}

sub state_text {
  my ($raw, $label) = @_;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$label state is not UTF-8");
  return $text;
}

sub verify_immutable_b_boundary {
  my ($root, $spec, $evidence_head, $bound_head, $evidence_root,
    $implementation_root, $design_root) = @_;
  commit_exact($root, $evidence_head, 'evidence checkpoint H');
  commit_exact($root, $bound_head, 'bound checkpoint B');
  my $parents = exact_line(
    git_capture($root, 8192, 'rev-list', '--parents', '-n', '1', $bound_head), 'B parents');
  my @parent = split / /, $parents;
  fatal('B must be the sole direct child transition from evidence H')
    unless @parent == 2 && $parent[0] eq $bound_head && $parent[1] eq $evidence_head;

  my $delta = committed_delta($root, $evidence_head, $bound_head);
  my %allowed = map { $_ => 1 } ("$spec/state.md", "$spec/audit.md");
  fatal('H-to-B transition must change exact state/audit path-set')
    unless keys(%$delta) == 2 && !grep { !$allowed{$_} } keys %$delta;
  for my $path (keys %allowed) {
    my $d = $delta->{$path} // fatal("H-to-B transition omits $path");
    fatal("H-to-B metadata delta malformed: $path")
      unless $d->{status} eq 'M' && $d->{oldmode} eq '100644' && $d->{newmode} eq '100644';
  }

  my ($h_state) = git_blob_at($root, $evidence_head, "$spec/state.md");
  my ($b_state) = git_blob_at($root, $bound_head, "$spec/state.md");
  my ($h_audit) = git_blob_at($root, $evidence_head, "$spec/audit.md");
  my ($b_audit) = git_blob_at($root, $bound_head, "$spec/audit.md");
  fatal('H audit is not an exact byte prefix of B audit')
    unless length($b_audit) > length($h_audit)
      && substr($b_audit, 0, length($h_audit)) eq $h_audit;
  my ($h_rows) = audit_rows($h_audit, 'evidence H');
  my ($b_rows) = audit_rows($b_audit, 'bound B');
  my @suffix = @$b_rows[@$h_rows .. $#$b_rows];

  for my $pair (
    ['Design-Root', $design_root],
    ['Implementation-Root', $implementation_root],
    ['Evidence-Root', $evidence_root],
  ) {
    fatal("H state $pair->[0] mismatch")
      unless state_field($h_state, $pair->[0], 'evidence H') eq $pair->[1];
    fatal("B state $pair->[0] changed")
      unless state_field($b_state, $pair->[0], 'bound B') eq $pair->[1];
  }
  fatal('H Quality-HEAD must be pending')
    unless state_field($h_state, 'Quality-HEAD', 'evidence H') eq encode(q{UTF-8}, '—');
  fatal('B Quality-HEAD must equal immutable evidence H')
    unless state_field($b_state, 'Quality-HEAD', 'bound B') eq $evidence_head;

  my $h = state_text($h_state, 'evidence H');
  my $b = state_text($b_state, 'bound B');
  fatal('H Stage 4 must be running') unless $h =~ /^- \[-\] stage-4-quality$/m;
  fatal('B Stage 4 must be done') unless $b =~ /^- \[x\] stage-4-quality$/m;
  fatal('H quality verdict must be pending') unless $h =~ /^- quality-verdict: \x{2014}$/m;
  fatal('H Stage 4 confidence must be pending')
    unless $h =~ /^- confidence-stage-4-quality: \x{2014}$/m;
  my $ts = qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;
  my ($verdict_evidence, $verdict_ts) =
    $b =~ /^- quality-verdict: PASS \x{2014} ([^\r\n]+) \(($ts)\)$/m;
  fatal('B quality verdict is not canonical PASS evidence') unless defined($verdict_evidence);
  my ($level, $reason, $confidence_ts, $ack_by, $ack_ts);
  my $confidence = state_field($b, 'confidence-stage-4-quality', 'bound B');
  if ($confidence =~ /\Agreen \(($ts)\)\z/) {
    ($level, $reason, $confidence_ts) = ('green', '-', $1);
  } elsif ($confidence =~ /\Agreen \x{2014} ([^\r\n]+) \(($ts)\)\z/) {
    ($level, $reason, $confidence_ts) = ('green', $1, $2);
  } elsif ($confidence =~ /\A(yellow|red) \x{2014} ([^\r\n]+) \(($ts)\) \x{00b7} ack: ([^\r\n]+) \(($ts)\)\z/) {
    ($level, $reason, $confidence_ts, $ack_by, $ack_ts) = ($1, $2, $3, $4, $5);
  } else { fatal('B Stage 4 confidence is not canonical or lacks required ack') }

  my @expected = qw(quality-head quality-verdict confidence:stage-4-quality stage-4-quality:done);
  push @expected, 'confidence-ack:stage-4-quality' if defined($ack_by);
  unless (@suffix == @expected) {
    my $quality_verdict_count = grep { $_->{event} eq 'quality-verdict' } @suffix;
    fatal("H-to-B strict lifecycle event count mismatch: quality-verdict=$quality_verdict_count");
  }
  for my $i (0 .. $#expected) {
    fatal("H-to-B strict lifecycle event out of order: $suffix[$i]{event}")
      unless $suffix[$i]{event} eq $expected[$i];
  }
  fatal('quality-head audit detail mismatch') unless $suffix[0]{detail} eq $evidence_head;
  my $verdict_detail = encode(q{UTF-8}, "PASS — $verdict_evidence");
  fatal('quality-verdict audit/state mismatch')
    unless $suffix[1]{detail} eq $verdict_detail && $suffix[1]{ts} eq $verdict_ts;
  fatal('confidence audit/state mismatch')
    unless $suffix[2]{detail} eq "level=$level reason=$reason"
      && $suffix[2]{ts} eq $confidence_ts;
  fatal('Stage 4 done audit/state mismatch')
    unless $suffix[3]{detail} eq '-' && $suffix[3]{ts} eq $confidence_ts;
  if (defined($ack_by)) {
    fatal('Stage 4 ack audit/state mismatch')
      unless $suffix[4]{detail} eq "by=$ack_by" && $suffix[4]{ts} eq $ack_ts;
  }

  my @mask = (
    qr/^- Updated:.*$/m,
    qr/^- Quality-HEAD:.*$/m,
    qr/^- \[[ x-]\] stage-4-quality$/m,
    qr/^- quality-verdict:.*$/m,
    qr/^- confidence-stage-4-quality:.*$/m,
  );
  for my $i (0 .. $#mask) {
    my $hc = ($h =~ s/$mask[$i]/__HARNESS_BOUND_${i}__/g);
    my $bc = ($b =~ s/$mask[$i]/__HARNESS_BOUND_${i}__/g);
    fatal('H-to-B allowed state anchor is not unique') unless $hc == 1 && $bc == 1;
  }
  fatal('H-to-B changed state outside the strict quality envelope') unless $h eq $b;
  return $bound_head;
}

sub verify_b_boundary {
  my ($root, $spec, $evidence_head, $bound_head, $evidence_root,
    $implementation_root, $design_root) = @_;
  verify_immutable_b_boundary($root, $spec, $evidence_head, $bound_head, $evidence_root,
    $implementation_root, $design_root);
  my $current = exact_line(git_capture($root, 4096, 'rev-parse', 'HEAD'), 'current HEAD');
  fatal('verify-committed authority requires exact current HEAD B') unless $current eq $bound_head;
  fatal('current index tree differs from immutable B')
    unless git_quiet($root, 'diff-index', '--cached', '--quiet', $bound_head, '--');
  fatal('current tracked bytes differ from immutable B')
    unless tracked_bytes_match_index($root);
  return $bound_head;
}

sub build_committed_envelope {
  my ($root, $spec, $checkpoint, $evidence_head, $bound_head) = @_;
  fatal('SPEC_DIR grammar mismatch')
    unless $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'git root');
  fatal('repo root is not canonical git toplevel') unless abs_path($top) eq $root;
  commit_exact($root, $checkpoint, 'checkpoint C');
  commit_exact($root, $evidence_head, 'evidence checkpoint H');
  my ($index_snapshot_dir, $index_snapshot) = authority_index_snapshot($root);
  local $ENV{GIT_INDEX_FILE} = $index_snapshot;
  my $live_index = index_entries($root);
  reject_nonstandard_index_flags($root, $live_index);
  my $parents = exact_line(
    git_capture($root, 8192, 'rev-list', '--parents', '-n', '1', $evidence_head), 'H parents');
  my @parent = split / /, $parents;
  fatal('committed H must be the sole direct child transition from checkpoint C')
    unless @parent == 2 && $parent[0] eq $evidence_head && $parent[1] eq $checkpoint;

  my $delta = committed_delta($root, $checkpoint, $evidence_head);
  my $state_path = "$spec/state.md";
  my $audit_path = "$spec/audit.md";
  my @mandatory = (
    "$spec/reviews/critical-code-review.md",
    "$spec/reviews/performance-review.md",
    "$spec/checklists/requirement-evidence.md",
  );
  my %allowed_delta = map { $_ => 1 } ($state_path, $audit_path, @mandatory);
  for my $metadata_path ($state_path, $audit_path) {
    my $d = $delta->{$metadata_path}
      // fatal("committed H omits modified metadata: $metadata_path");
    fatal("committed H metadata delta malformed: $metadata_path")
      unless $d->{status} eq 'M' && $d->{oldmode} eq '100644' && $d->{newmode} eq '100644';
  }
  for my $path (keys %$delta) {
    fatal("committed H path is outside the frozen Stage-4 profile: $path")
      unless $allowed_delta{$path};
  }
  for my $path (@mandatory) {
    my $d = $delta->{$path} // fatal("committed H omits mandatory evidence: $path");
    require_mandatory_evidence_transition($d, $path, 'committed');
  }
  my @evidence_path = sort { use bytes; $a cmp $b } @mandatory;

  my (%raw, @manifest_row, $total);
  for my $path (@evidence_path) {
    my ($blob) = git_blob_at($root, $evidence_head, $path);
    markdown_text($blob, "committed evidence artifact $path");
    $total += length($blob);
    fatal('committed EvidenceRoot set exceeds 64 MiB') if $total > $MAX_SET;
    $raw{$path} = $blob;
    push @manifest_row,
      join("\t", 'F', $path, '100644', length($blob), sha256_hex($blob)) . "\n";
  }
  my $manifest = $DOMAIN . "checkpoint\t$checkpoint\n" . join(q{}, @manifest_row);
  fatal('committed EvidenceRoot manifest exceeds 64 MiB') if length($manifest) > $MAX_SET;
  my $evidence_root = sha256_hex($manifest);

  my ($checkpoint_state) = git_blob_at($root, $checkpoint, $state_path);
  my ($checkpoint_audit) = git_blob_at($root, $checkpoint, $audit_path);
  my ($head_state) = git_blob_at($root, $evidence_head, $state_path);
  my ($head_audit) = git_blob_at($root, $evidence_head, $audit_path);
  fatal('checkpoint C audit is not an exact byte prefix of committed H audit')
    unless length($head_audit) > length($checkpoint_audit)
      && substr($head_audit, 0, length($checkpoint_audit)) eq $checkpoint_audit;
  my ($checkpoint_rows) = audit_rows($checkpoint_audit, 'checkpoint C');
  my ($head_rows) = audit_rows($head_audit, 'committed H');
  my $implementation = parse_implementation($checkpoint_rows);
  my $checkpoint_cycle = checkpoint_quality_cycle($checkpoint_state, 'checkpoint C');
  authenticate_completed_checkpoint($root, $spec, $checkpoint, $checkpoint_state,
    $checkpoint_cycle, $implementation);
  verify_retained_roots($root, $spec, $checkpoint, $implementation);
  fatal('checkpoint C state Implementation-Root mismatch')
    unless state_field($checkpoint_state, 'Implementation-Root', 'checkpoint C')
      eq $implementation->{root};
  fatal('checkpoint C state Design-Root mismatch')
    unless state_field($checkpoint_state, 'Design-Root', 'checkpoint C')
      eq $implementation->{design};
  fatal('committed H changed Implementation-Root')
    unless state_field($head_state, 'Implementation-Root', 'committed H') eq $implementation->{root};
  fatal('committed H changed Design-Root')
    unless state_field($head_state, 'Design-Root', 'committed H') eq $implementation->{design};
  fatal('committed H has premature Quality-HEAD')
    unless state_field($head_state, 'Quality-HEAD', 'committed H') eq encode(q{UTF-8}, '—');
  fatal('committed H state Evidence-Root mismatch')
    unless state_field($head_state, 'Evidence-Root', 'committed H') eq $evidence_root;

  verify_b_boundary($root, $spec, $evidence_head, $bound_head, $evidence_root,
    $implementation->{root}, $implementation->{design});

  my ($final, $bind) = parse_quality_suffix($checkpoint_rows, $head_rows, $checkpoint, 1,
    $checkpoint_cycle, $implementation->{receipt_generation});
  fatal('committed evidence-bind root omits or changes EvidenceRoot')
    unless $bind->{root} eq $evidence_root;
  my $live_audit = safe_read($root, $audit_path);
  fatal('committed H audit is not an exact prefix of current live audit')
    unless length($live_audit) >= length($head_audit)
      && substr($live_audit, 0, length($head_audit)) eq $head_audit;
  my $helper_audit_sha = sha256_hex($live_audit);
  my %trusted_receipt;
  my $critical_terminal = $final->{'critical-code'};
  fatal('critical-code committed artifact path is non-canonical')
    unless $critical_terminal->{artifact} eq $mandatory[0];
  fatal('critical-code committed artifact digest mismatch')
    unless sha256_hex($raw{$mandatory[0]}) eq $critical_terminal->{sha256};
  fatal('critical-code committed reviewer actor equals implementation actor')
    if $critical_terminal->{actor} eq $implementation->{actor};
  fatal('critical-code committed reviewer attempt equals implementation attempt')
    if $critical_terminal->{attempt} eq $implementation->{attempt};
  my $live_critical = safe_read($root, $mandatory[0]);
  fatal('critical-code live artifact differs from immutable H')
    unless $live_critical eq $raw{$mandatory[0]};
  my $trusted_critical = verify_receipt($root, $spec, $checkpoint, 'critical-code',
    $critical_terminal->{attempt}, $helper_audit_sha);
  for my $key (qw(attempt generation actor subject capability artifact sha256)) {
    fatal("critical-code committed/helper receipt mismatch: $key")
      unless $trusted_critical->{$key} eq $critical_terminal->{$key};
  }
  $trusted_receipt{'critical-code'} = $trusted_critical;
  my $live_performance = safe_read($root, $mandatory[1]);
  fatal('performance live artifact differs from immutable H')
    unless $live_performance eq $raw{$mandatory[1]};
  $trusted_receipt{performance} = trusted_performance_terminal(
    $root, $spec, $checkpoint, $implementation, $final->{performance}, $helper_audit_sha,
    $mandatory[1], $raw{$mandatory[1]});
  my $critical = verify_critical_review($raw{$mandatory[0]}, $checkpoint,
    $implementation, $trusted_receipt{'critical-code'}, $root, $spec);
  verify_performance_review($raw{$mandatory[1]}, $checkpoint,
    $implementation, $trusted_receipt{performance}, $root, $spec);
  my ($spec_raw) = git_blob_at($root, $checkpoint, "$spec/spec.md");
  my ($delivery_raw) = git_blob_at($root, $checkpoint, "$spec/delivery-trace.tsv");
  my $requirements = parse_spec_requirements($spec_raw);
  my $delivery = parse_delivery_contract($delivery_raw, $requirements);
  my $live_requirement = safe_read($root, $mandatory[2]);
  fatal('requirement evidence live artifact differs from immutable H')
    unless $live_requirement eq $raw{$mandatory[2]};
  verify_requirement_evidence($raw{$mandatory[2]}, $checkpoint, $implementation,
    $requirements, $delivery, $root, $spec, $helper_audit_sha, $critical);
  revalidate_immutable_cache_hits();
  revalidate_pins();
  return {
    manifest => $manifest, root => $evidence_root, checkpoint => $checkpoint,
    evidence_head => $evidence_head, bound_head => $bound_head, implementation => $implementation,
    audit_sha => sha256_hex($head_audit),
  };
}

sub usage {
  fatal('usage: evidence-v1-verify.pl <manifest|candidate|verify|verify-bound> <repo-root> <SPEC_DIR> <checkpoint-C> | verify-committed <repo-root> <SPEC_DIR> <checkpoint-C> <evidence-H> <bound-B>');
}

binmode(STDOUT, q{:raw}); binmode(STDERR, q{:raw});
enter_dedicated_runtime();
arm_verifier_deadline();
sanitize_environment();
my $command = shift // usage();
if ($command eq 'verify-committed') {
  @ARGV == 5 or usage();
  my ($root_arg, $spec, $checkpoint, $evidence_head, $bound_head) = @ARGV;
  fatal('checkpoint C malformed') unless $checkpoint =~ /\A$OID_RE\z/;
  fatal('evidence H malformed') unless $evidence_head =~ /\A$OID_RE\z/;
  fatal('bound B malformed') unless $bound_head =~ /\A$OID_RE\z/;
  my $root = root_abs($root_arg);
  configure_internal_git_context($root);
  my $result = build_committed_envelope($root, $spec, $checkpoint, $evidence_head, $bound_head);
  alarm(0);
  print "Evidence-Root: $result->{root}\n";
  print "Checkpoint-C: $result->{checkpoint}\n";
  print "Evidence-HEAD: $result->{evidence_head}\n";
  print "Bound-HEAD: $result->{bound_head}\n";
  print "Implementation-Root: $result->{implementation}{root}\n";
  print "Audit-SHA256: $result->{audit_sha}\n";
  exit 0;
}
@ARGV == 3 or usage();
my ($root_arg, $spec, $checkpoint) = @ARGV;
fatal('checkpoint C malformed') unless $checkpoint =~ /\A$OID_RE\z/;
my $root = root_abs($root_arg);
configure_internal_git_context($root);
my $bound_mode = $command eq 'verify-bound';
fatal('unknown evidence verifier command')
  unless $command eq 'manifest' || $command eq 'candidate'
    || $command eq 'verify' || $command eq 'verify-bound';
my $result = build_envelope($root, $spec, $checkpoint, $bound_mode);
alarm(0);
if ($command eq 'manifest') { print $result->{manifest}; exit 0 }
if ($command eq 'candidate') { print "$result->{root}\n"; exit 0 }
print "Evidence-Root: $result->{root}\n";
print "Checkpoint-C: $result->{checkpoint}\n";
print "Implementation-Root: $result->{implementation}{root}\n";
print "Implementation-Attempt: $result->{implementation}{attempt}\n";
print "Implementation-Generation: $result->{implementation}{generation}\n";
print "Implementation-Actor: $result->{implementation}{actor}\n";
print "Critical-Attempt: $result->{critical}{attempt}\n";
print "Critical-Actor: $result->{critical}{actor}\n";
print "Performance-Attempt: $result->{performance}{attempt}\n";
print "Performance-Actor: $result->{performance}{actor}\n";
print "Performance-Mode: $result->{performance_mode}\n";
print "Audit-SHA256: $result->{audit_sha}\n";
exit 0;
