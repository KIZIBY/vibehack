#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

our $ACTIVE_PROCESS_GROUP;
our $DEDICATED_DONE_WRITE;
our $DEDICATED_RUNTIME_PID;
our $DEDICATED_RUNTIME_TEARDOWN;
our $DEDICATED_RUNTIME_CANCEL_SET;

# Registered before File::Temp, so this is the final runtime END block. All later teardown and
# snapshot cleanup finishes first; POSIX::_exit then leaves done-FD closure to the kernel, making
# guard-observed EOF proof that the exact runtime is already dead or unreaped.
END {
  if (defined($DEDICATED_RUNTIME_PID) && $$ == $DEDICATED_RUNTIME_PID) {
    my $status = $?;
    POSIX::_exit($status);
  }
}

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(EAGAIN EWOULDBLOCK EEXIST ENOENT ECHILD EINTR);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW O_NONBLOCK FD_CLOEXEC F_GETFD F_GETFL F_SETFD F_SETFL S_ISDIR S_ISLNK S_ISREG SEEK_SET);
use File::Basename qw(dirname);
use File::Path qw(remove_tree);
use File::Temp qw(tempdir tempfile);
use IO::Handle;
use IO::Select;
use POSIX qw(SIGHUP SIGINT SIGTERM SIG_BLOCK SIG_SETMASK SIG_UNBLOCK WNOHANG setsid sigprocmask);
use Time::HiRes qw(clock_gettime CLOCK_MONOTONIC sleep);

my $MAX_FILE = 16 * 1024 * 1024;
my $MAX_STREAM = 4 * 1024 * 1024;
my $MAX_GIT_OUTPUT = 512 * 1024 * 1024;
my $MAX_SNAPSHOT = 512 * 1024 * 1024;
my $MAX_PATHS = 100_000;
my $MAX_GENERATION = 2147483647;
my $TIMEOUT = 120;
my $PROCESS_TIMEOUT = 120;
my $SCRIPT_DIR = abs_path(dirname(__FILE__));
my $INTERNAL_GIT_CONTEXT = delete $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1};

# Registered after File::Temp, therefore executed before its older END cleanup. Structured runtime
# exits already enter teardown and block cancellation before END dispatch; this remains a defensive
# fallback for an unexpected interpreter-level termination. Late cancellation stays owned by the
# wrapper and is re-raised after done-pipe EOF, so snapshot cleanup cannot be interrupted by a
# nested exit or EINTR.
END {
  if (defined($DEDICATED_RUNTIME_PID) && $$ == $DEDICATED_RUNTIME_PID) {
    arm_dedicated_runtime_teardown();
  }
}

my $MODERN_HEADER = encode(q{UTF-8},
  "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n"
  . "| ts (UTC) | event | detail |\n|---|---|---|\n");
my $LEGACY_HEADER =
  "# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";

my $ROOT_RE = qr/[0-9a-f]{64}/;
my $OID_RE = qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my $ATTEMPT_RE = qr/[0-9a-f]{64}/;
my $ACTOR_RE = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $TEST_RE = qr/T-[A-Z0-9][A-Z0-9-]{1,63}/;
my $UINT_RE = qr/(?:0|[1-9][0-9]*)/;

sub arm_dedicated_runtime_teardown {
  return unless defined($DEDICATED_RUNTIME_PID) && $$ == $DEDICATED_RUNTIME_PID;
  return if $DEDICATED_RUNTIME_TEARDOWN;
  local $!; local $^E; local $?;
  # The set was created while cancellation was already blocked during runtime bootstrap. Block it
  # before arming the handler-visible flag: a signal before this boundary follows the normal
  # cancellation path, while one after it remains pending and cannot enter END dispatch.
  defined($DEDICATED_RUNTIME_CANCEL_SET) or POSIX::_exit(125);
  sigprocmask(SIG_BLOCK, $DEDICATED_RUNTIME_CANCEL_SET) or POSIX::_exit(125);
  $DEDICATED_RUNTIME_TEARDOWN = 1;
}

sub runtime_exit {
  my ($status) = @_;
  arm_dedicated_runtime_teardown();
  CORE::exit($status);
}

sub fatal {
  arm_dedicated_runtime_teardown();
  print STDERR "tdd-receipt-v1: FATAL: $_[0]\n";
  runtime_exit(2);
}
sub monotonic_now { return clock_gettime(CLOCK_MONOTONIC) }
sub inode_id { return $_[0][0] . q{:} . $_[0][1] }
sub valid_uint {
  my ($v) = @_;
  return defined($v) && $v =~ /\A$UINT_RE\z/
    && length($v) <= 10 && $v <= $MAX_GENERATION;
}

sub signal_process_group {
  my ($pid) = @_;
  return unless defined($pid);
  # The session leader remains unreaped while these signals are sent, so its numeric PID/PGID
  # cannot be recycled between the positive and group-directed operations.
  kill 'TERM', -$pid;
  kill 'TERM', $pid;
  sleep 0.02;
  kill 'KILL', -$pid;
  kill 'KILL', $pid;
}

sub stop_process_group {
  my ($pid) = @_;
  return unless defined($pid);
  signal_process_group($pid);
  # Drop asynchronous authority before reap.  A later cancellation handler must never signal a
  # numeric identity whose exact session leader has already been collected.
  $ACTIVE_PROCESS_GROUP = undef
    if defined($ACTIVE_PROCESS_GROUP) && $ACTIVE_PROCESS_GROUP == $pid;
  while (1) {
    my $got = waitpid($pid, 0);
    return if $got == $pid || ($got == -1 && $! == ECHILD);
    next if $got == -1 && $! == EINTR;
    return;
  }
}

sub block_cancellation {
  my ($label) = @_;
  my $cancel = POSIX::SigSet->new(SIGHUP, SIGINT, SIGTERM);
  my $prior = POSIX::SigSet->new();
  sigprocmask(SIG_BLOCK, $cancel, $prior)
    or fatal("$label cancellation-mask block failed");
  return ($cancel, $prior);
}

sub restore_cancellation {
  my ($prior, $pid, $label) = @_;
  return if sigprocmask(SIG_SETMASK, $prior);
  stop_process_group($pid) if defined($pid);
  fatal("$label cancellation-mask restore failed");
}

sub re_raise_runtime_signal {
  my ($signal) = @_;
  my $name = $signal == SIGHUP ? 'HUP'
    : $signal == SIGINT ? 'INT'
    : $signal == SIGTERM ? 'TERM' : undef;
  POSIX::_exit(128 + $signal) unless defined($name);
  $SIG{$name} = 'DEFAULT';
  my $one = POSIX::SigSet->new($signal);
  sigprocmask(SIG_UNBLOCK, $one)
    or POSIX::_exit(128 + $signal);
  kill $signal, $$;
  POSIX::_exit(128 + $signal);
}

sub enter_dedicated_runtime {
  # An exec caller may retain live children and pending SIGCHLD.  The isolated runtime inherits
  # neither.  A sibling guard owns cancellation forwarding through pipes, never a post-reap PID:
  # runtime completion is the done-pipe EOF emitted only after every END cleanup and descriptor
  # close, while HUP/INT/TERM are blocked across both forks and handler registration.
  $SIG{CHLD} = 'DEFAULT';
  my $cancel_set = POSIX::SigSet->new(SIGHUP, SIGINT, SIGTERM);
  my $prior_cancel = POSIX::SigSet->new();
  sigprocmask(SIG_BLOCK, $cancel_set, $prior_cancel)
    or fatal('dedicated TDD cancellation-mask block failed');
  pipe(my $cancel_read, my $cancel_write)
    or fatal('dedicated TDD cancellation pipe failed');
  pipe(my $done_read, my $done_write)
    or fatal('dedicated TDD completion pipe failed');
  pipe(my $ready_read, my $ready_write)
    or fatal('dedicated TDD readiness pipe failed');

  my $pid = fork();
  unless (defined($pid)) {
    close($cancel_read); close($cancel_write); close($done_read); close($done_write);
    close($ready_read); close($ready_write);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated TDD runtime fork failed');
  }
  if ($pid == 0) {
    close($cancel_read); close($cancel_write); close($done_read); close($ready_read);
    $DEDICATED_DONE_WRITE = $done_write;
    $DEDICATED_RUNTIME_PID = $$;
    $DEDICATED_RUNTIME_CANCEL_SET = $cancel_set;
    setsid() >= 0 or fatal('dedicated TDD runtime setsid failed');
    my $flags = fcntl($done_write, F_GETFD, 0);
    defined($flags) && defined(fcntl($done_write, F_SETFD, $flags | FD_CLOEXEC))
      or fatal('dedicated TDD completion CLOEXEC failed');
    my $cancelling = 0;
    for my $pair ([HUP => SIGHUP], [INT => SIGINT], [TERM => SIGTERM]) {
      my ($name, $number) = @$pair;
      $SIG{$name} = sub {
        re_raise_runtime_signal($number)
          unless defined($DEDICATED_RUNTIME_PID) && $$ == $DEDICATED_RUNTIME_PID;
        return if $DEDICATED_RUNTIME_TEARDOWN;
        return if $cancelling++;
        stop_process_group($ACTIVE_PROCESS_GROUP) if defined($ACTIVE_PROCESS_GROUP);
        # Structured exit masks cancellation before END dispatch so File::Temp cleanup is atomic
        # with respect to late wrapper cancellation.
        runtime_exit(128 + $number);
      };
    }
    syswrite($ready_write, 'R', 1) == 1
      or fatal('dedicated TDD readiness publish failed');
    close($ready_write) or fatal('dedicated TDD readiness close failed');
    sigprocmask(SIG_UNBLOCK, $cancel_set)
      or fatal('dedicated TDD runtime signal-mask activation failed');
    return;
  }
  close($done_write); close($ready_write);
  my $runtime_ready;
  while (1) {
    my $n = sysread($ready_read, my $byte, 1);
    if (defined($n)) {
      $runtime_ready = $n == 1 && $byte eq 'R';
      last;
    }
    next if $! == EINTR;
    last;
  }
  close($ready_read);
  unless ($runtime_ready) {
    stop_process_group($pid);
    close($cancel_read); close($cancel_write); close($done_read);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated TDD runtime readiness failed');
  }

  my $guard = fork();
  unless (defined($guard)) {
    stop_process_group($pid);
    close($cancel_read); close($cancel_write);
    close($done_read);
    sigprocmask(SIG_SETMASK, $prior_cancel);
    fatal('dedicated TDD cancellation guard fork failed');
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
        if (defined($n) && $n == 0) {
          # Runtime PID is still an unreaped child of the wrapper, so its numeric PGID cannot be
          # recycled. Normal exit has no members left; hard death may leave only owned preflight
          # descendants, which must be gone before the guard relinquishes authority.
          signal_process_group($pid);
          POSIX::_exit(0);
        }
        POSIX::_exit(125);
      }
      if (exists($ready{fileno($cancel_read)})) {
        my $n = sysread($cancel_read, my $code, 1);
        next if !defined($n) && $! == EINTR;
        my $signal = defined($n) && $n == 1
          ? ($code eq 'H' ? SIGHUP : $code eq 'I' ? SIGINT : SIGTERM)
          : SIGTERM;
        kill($signal, -$pid) or kill($signal, $pid);
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
    or fatal('dedicated TDD cancellation-mask activation failed');

  # Reap the guard first: it is the only process allowed to signal the numeric runtime PID.  Once
  # it has exited, that authority is gone and the runtime can be reaped without a PID-reuse race.
  while (1) {
    my $got = waitpid($guard, 0);
    last if $got == $guard;
    next if $got == -1 && $! == EINTR;
    fatal('dedicated TDD cancellation guard wait failed');
  }
  my $status;
  while (1) {
    my $got = waitpid($pid, 0);
    if ($got == $pid) { $status = $?; last }
    next if $got == -1 && $! == EINTR;
    fatal('dedicated TDD runtime wait failed');
  }
  sigprocmask(SIG_BLOCK, $cancel_set)
    or fatal('dedicated TDD cancellation-mask shutdown failed');
  for my $name (qw(HUP INT TERM)) {
    my $handler = $old_signal{$name};
    $SIG{$name} = !defined($handler) || $handler eq q{} || $handler eq q{0}
      ? 'DEFAULT' : $handler;
  }
  if ($cancel_open) { close($cancel_write); $cancel_open = 0 }
  close($cancel_read); close($done_read);
  sigprocmask(SIG_SETMASK, $prior_cancel)
    or fatal('dedicated TDD cancellation-mask restore failed');
  re_raise_runtime_signal($cancel_signal) if defined($cancel_signal);
  re_raise_runtime_signal($status & 127) if $status & 127;
  my $exit = ($status >> 8) & 255;
  re_raise_runtime_signal($exit - 128)
    if $exit == 128 + SIGHUP || $exit == 128 + SIGINT || $exit == 128 + SIGTERM;
  exit $exit;
}

sub safe_rel {
  my ($raw) = @_;
  fatal('empty repo-relative path') unless defined($raw) && length($raw);
  fatal('unsafe repo-relative path') if $raw =~ m{\A/} || $raw =~ /[\x00-\x1f\x7f]/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('repo-relative path is not UTF-8');
  fatal('Unicode control in repo-relative path') if $text =~ /\p{Cc}/;
  my @part = split m{/}, $raw, -1;
  fatal('unsafe repo-relative path segment')
    if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  return @part;
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

sub require_declared_absent {
  my ($root, $rel) = @_;
  my @part = safe_rel($rel);
  check_root($root);
  my $dir = $root->{fh};
  my @hold;
  my @parents = @part > 1 ? @part[0 .. $#part - 1] : ();
  for my $component (@parents) {
    chdir($dir) or fatal('declared path traversal failed');
    my @named = lstat($component);
    if (!@named) {
      fatal('declared path absence cannot be established') unless $! == ENOENT;
      chdir($root->{fh}) or fatal('repo root traversal failed');
      close($_) or fatal('declared path parent close failed') for reverse @hold;
      return;
    }
    fatal('declared path parent must be a real directory')
      if S_ISLNK($named[2]) || !S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal('declared path parent open failed');
    my @opened = stat($next);
    fatal('declared path parent identity changed')
      unless @opened && inode_id(\@opened) eq inode_id(\@named);
    push @hold, $next;
    $dir = $next;
  }
  chdir($dir) or fatal('declared path parent unavailable');
  my @leaf = lstat($part[-1]);
  fatal("untracked/ignored path collides with declared closure: $rel") if @leaf;
  fatal('declared path absence cannot be established') unless $! == ENOENT;
  chdir($root->{fh}) or fatal('repo root traversal failed');
  close($_) or fatal('declared path parent close failed') for reverse @hold;
}

sub open_leaf {
  my ($root, $rel, $limit, $expected_mode) = @_;
  $expected_mode //= 0644;
  my @part = safe_rel($rel);
  check_root($root);
  chdir($root->{fh}) or fatal('repo root traversal failed');
  my @hold = ($root->{fh});
  my $dir = $root->{fh};
  if (@part > 1) {
    for my $component (@part[0 .. $#part - 1]) {
      chdir($dir) or fatal('directory traversal failed');
      my @named = lstat($component);
      fatal('path parent must be a real directory')
        unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
      sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        or fatal('path parent open failed');
      my @opened = stat($next);
      fatal('path parent identity changed')
        unless @opened && inode_id(\@opened) eq inode_id(\@named);
      push @hold, $next;
      $dir = $next;
    }
  }
  chdir($dir) or fatal('artifact directory unavailable');
  my $leaf = $part[-1];
  my @named = lstat($leaf);
  fatal("$rel must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$rel mode differs from staged tree")
    unless ($named[2] & 07777) == $expected_mode;
  fatal("$rel exceeds size limit") if $named[7] > $limit;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $rel");
  my @opened = stat($fh);
  fatal("$rel identity changed")
    unless @opened && inode_id(\@opened) eq inode_id(\@named)
      && S_ISREG($opened[2]) && $opened[3] == 1
      && ($opened[2] & 07777) == $expected_mode;
  return { fh => $fh, dir => $dir, leaf => $leaf, rel => $rel,
    opened => \@opened, hold => \@hold, limit => $limit,
    expected_mode => $expected_mode };
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
    fatal('file exceeds size limit') if length($raw) > $leaf->{limit};
  }
  return $raw;
}

sub check_leaf {
  my ($leaf, $length) = @_;
  my @opened = stat($leaf->{fh});
  chdir($leaf->{dir}) or fatal('artifact directory unavailable');
  my @named = lstat($leaf->{leaf});
  fatal('file changed during receipt operation')
    unless @opened && @named && !S_ISLNK($named[2])
      && S_ISREG($opened[2]) && S_ISREG($named[2])
      && $opened[3] == 1 && $named[3] == 1
      && inode_id(\@opened) eq inode_id($leaf->{opened})
      && inode_id(\@named) eq inode_id($leaf->{opened})
      && ($opened[2] & 07777) == $leaf->{expected_mode}
      && ($named[2] & 07777) == $leaf->{expected_mode}
      && $opened[7] == $length && $named[7] == $length;
}

sub close_leaf {
  my ($leaf) = @_;
  chdir($leaf->{hold}[0]) or fatal('repo root traversal failed while closing leaf');
  close($leaf->{fh}) or fatal('file close failed');
  if (@{$leaf->{hold}} > 1) {
    for my $i (reverse 1 .. $#{$leaf->{hold}}) {
      close($leaf->{hold}[$i]) or fatal('directory chain close failed');
    }
  }
}

sub read_repo_file {
  my ($root, $rel, $mode) = @_;
  $mode //= 0644;
  my $first = open_leaf($root, $rel, $MAX_FILE, $mode);
  my $raw = read_from_start($first);
  check_leaf($first, length($raw));
  fatal('file changed between descriptor reads') unless read_from_start($first) eq $raw;
  check_leaf($first, length($raw));
  my $second = open_leaf($root, $rel, $MAX_FILE, $mode);
  fatal('file identity changed after canonical re-resolution')
    unless inode_id($second->{opened}) eq inode_id($first->{opened});
  fatal('file bytes changed after canonical re-resolution')
    unless read_from_start($second) eq $raw;
  check_leaf($second, length($raw));
  check_leaf($first, length($raw));
  close_leaf($second);
  close_leaf($first);
  check_root($root);
  return $raw;
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

sub parse_common {
  my ($detail, $finish) = @_;
  my @v;
  my $legacy_contract = 0;
  if (!$finish) {
    @v = ($detail =~ /\Atest=($TEST_RE);phase=(red|green|adjacent);executed=($TEST_RE);run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);contract=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120\z/);
    if (@v != 14) {
      @v = ($detail =~ /\Atest=($TEST_RE);phase=(red|green|adjacent);executed=($TEST_RE);run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120\z/);
      fatal('non-canonical tdd-run-start detail') unless @v == 13;
      splice @v, 8, 0, ('0' x 64);
      $legacy_contract = 1;
    }
  } else {
    @v = ($detail =~ /\Atest=($TEST_RE);phase=(red|green|adjacent);executed=($TEST_RE);run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);contract=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120;result=(assertion-failed|assertion-passed|setup-failed|timeout|invalid-output);exit=(0|[1-9][0-9]{0,2}|signal-[1-9][0-9]{0,2}|timeout);signature=($ROOT_RE|none);stdout=($ROOT_RE);stderr=($ROOT_RE);duration-ms=($UINT_RE)\z/);
    if (@v != 20) {
      @v = ($detail =~ /\Atest=($TEST_RE);phase=(red|green|adjacent);executed=($TEST_RE);run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120;result=(assertion-failed|assertion-passed|setup-failed|timeout|invalid-output);exit=(0|[1-9][0-9]{0,2}|signal-[1-9][0-9]{0,2}|timeout);signature=($ROOT_RE|none);stdout=($ROOT_RE);stderr=($ROOT_RE);duration-ms=($UINT_RE)\z/);
      fatal('non-canonical tdd-run-finish detail') unless @v == 19;
      splice @v, 8, 0, ('0' x 64);
      $legacy_contract = 1;
    }
  }
  fatal('TDD receipt generation malformed') unless valid_uint($v[4]);
  if ($finish) {
    fatal('TDD receipt exit malformed')
      if ($v[15] =~ /\A[0-9]+\z/ && $v[15] > 255)
        || ($v[15] =~ /\Asignal-([0-9]+)\z/ && $1 > 255);
    fatal('TDD receipt duration malformed') unless valid_uint($v[19]);
  }
  return {
    test => $v[0], phase => $v[1], executed => $v[2], run => $v[3],
    generation => $v[4], implementation => $v[5], actor => $v[6],
    root => $v[7], contract => $v[8], tree => $v[9], manifest => $v[10],
    executable => $v[11], argv_template => $v[12], producer => $v[13],
    legacy_contract => $legacy_contract,
    ($finish ? (result => $v[14], exit => $v[15], signature => $v[16],
      stdout => $v[17], stderr => $v[18], duration => $v[19]) : ()),
  };
}

sub same_common {
  my ($a, $b) = @_;
  for my $key (qw(test phase executed run generation implementation actor root contract tree manifest executable argv_template producer legacy_contract)) {
    fatal("TDD terminal $key mismatch") unless $a->{$key} eq $b->{$key};
  }
}

sub accepted {
  my ($r) = @_;
  return $r->{result} eq 'assertion-failed'
    && $r->{exit} =~ /\A[0-9]+\z/ && $r->{exit} > 0
    && $r->{signature} =~ /\A$ROOT_RE\z/ if $r->{phase} eq 'red';
  return $r->{result} eq 'assertion-passed' && $r->{exit} eq '0'
    && $r->{signature} =~ /\A$ROOT_RE\z/;
}

sub can_start_phase {
  my ($parsed, $test, $phase, $executed, $root, $identity) = @_;
  fatal('another TDD process receipt is still open') if defined($parsed->{open});
  my $phase_map = $parsed->{phase};
  fatal('TDD phase already has a terminal receipt') if exists($phase_map->{$test}{$phase});
  if ($phase eq 'red') {
    fatal('RED must execute the primary test ID') unless $executed eq $test;
    fatal('RED must be the first phase')
      if exists($phase_map->{$test}{green}) || exists($phase_map->{$test}{adjacent});
  } elsif ($phase eq 'green') {
    fatal('GREEN must execute the primary test ID') unless $executed eq $test;
    my $red = $phase_map->{$test}{red};
    fatal('GREEN requires an accepted RED receipt') unless defined($red) && accepted($red);
    fatal('RED and GREEN content roots must differ') if $red->{root} eq $root;
    for my $key (qw(contract manifest executable argv_template producer)) {
      fatal("RED/GREEN $key identity changed") unless $red->{$key} eq $identity->{$key};
    }
  } else {
    fatal('adjacent phase must execute a distinct test ID') if $executed eq $test;
    my $green = $phase_map->{$test}{green};
    fatal('adjacent phase requires an accepted GREEN receipt')
      unless defined($green) && accepted($green);
    fatal('adjacent phase root must equal GREEN root') unless $green->{root} eq $root;
    for my $key (qw(contract manifest executable argv_template producer)) {
      fatal("GREEN/adjacent $key identity changed") unless $green->{$key} eq $identity->{$key};
    }
  }
}

sub parse_audit {
  my ($raw) = @_;
  my $rows = audit_rows($raw);
  my ($generation, $implementation, $open) = (0, undef, undef);
  my (%used_run, %phase);
  for my $row (@$rows) {
    my ($event, $detail) = @$row;
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=($UINT_RE);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      my ($next, $scopes) = ($1, $2);
      fatal('receipt generation malformed') unless valid_uint($next) && $next > 0;
      fatal('receipt generation is not monotonic') unless $next == $generation + 1;
      $generation = $next;
      if (grep { $_ eq 'implementation' } split /,/, $scopes) {
        $implementation = undef; $open = undef; %phase = ();
      }
      next;
    }
    fatal('spoofed receipt-invalidate event') if $event =~ /receipt-invalidate/;
    if ($event eq 'implementation-start') {
      $detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($ROOT_RE);capability=implementation-v1;base=($OID_RE)\z/
        or fatal('non-canonical implementation-start detail');
      my %v = (attempt => $1, generation => $2, actor => $3, design => $4, base => $5);
      fatal('implementation generation malformed') unless valid_uint($v{generation});
      fatal('implementation-start is not in current generation') unless $v{generation} == $generation;
      fatal('implementation lifecycle already active') if defined($implementation);
      $implementation = \%v;
      next;
    }
    if ($event eq 'implementation-bind') {
      $detail =~ /\Aroot=$ROOT_RE;base=$OID_RE;design=$ROOT_RE;attempt=$ATTEMPT_RE;generation=$UINT_RE;actor=$ACTOR_RE\z/
        or fatal('non-canonical implementation-bind detail');
      next;
    }
    if ($event =~ /\Atdd-run-(start|finish):(red|green|adjacent)\z/) {
      my ($kind, $event_phase) = ($1, $2);
      my $v = parse_common($detail, $kind eq 'finish');
      fatal('TDD event phase/detail mismatch') unless $v->{phase} eq $event_phase;
      fatal('TDD receipt has no active implementation') unless defined($implementation);
      fatal('TDD receipt implementation mismatch') unless $v->{implementation} eq $implementation->{attempt};
      fatal('TDD receipt actor mismatch') unless $v->{actor} eq $implementation->{actor};
      fatal('TDD receipt is not in current generation') unless $v->{generation} == $generation;
      if ($kind eq 'start') {
        fatal('duplicate TDD run ID') if $used_run{$v->{run}}++;
        can_start_phase({ open => $open, phase => \%phase },
          $v->{test}, $v->{phase}, $v->{executed}, $v->{root}, $v);
        $open = $v;
      } else {
        fatal('unmatched TDD finish') unless defined($open);
        same_common($open, $v);
        fatal('TDD phase terminal duplicated') if exists($phase{$v->{test}}{$v->{phase}});
        $phase{$v->{test}}{$v->{phase}} = $v;
        $open = undef;
      }
      next;
    }
    fatal('spoofed or malformed TDD receipt event')
      if $event =~ /tdd-run-(?:start|finish)/ || $detail =~ /tdd-run-(?:start|finish)/;
  }
  return { generation => $generation, implementation => $implementation,
    open => $open, phase => \%phase, used_run => \%used_run, raw => $raw };
}

sub sanitize_git_environment {
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
  $ENV{LC_ALL} = 'C';
  $ENV{LANG} = 'C';
  $ENV{TZ} = 'UTC';
  $ENV{GIT_OPTIONAL_LOCKS} = '0';
  $ENV{GIT_NO_REPLACE_OBJECTS} = '1';
  $ENV{GIT_CONFIG_NOSYSTEM} = '1';
  $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  $ENV{GIT_CONFIG_SYSTEM} = '/dev/null';
  $ENV{GIT_PAGER} = 'cat';
}

sub git_argv {
  my ($root, @args) = @_;
  return ('git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
    '-c', 'core.untrackedCache=false', '-c', 'core.trustctime=true',
    '-c', 'core.checkStat=default', '-c', 'core.ignoreStat=false',
    '-C', $root->{abs}, @args);
}

sub git_capture {
  my ($root, $limit, @args) = @_;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  my @command = git_argv($root, @args);
  open(my $fh, '-|', @command) or fatal('git launch failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('git output read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('git output exceeds safety limit') if length($raw) > $limit;
  }
  close($fh) or fatal('git command failed');
  return $raw;
}

sub exact_git_line {
  my ($raw, $label) = @_;
  $raw =~ /\A([^\r\n]+)\n\z/ or fatal("$label output malformed");
  return $1;
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
  my $top = exact_git_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'),
    'context worktree');
  my $actual_gitdir = exact_git_line(git_capture($root, 16_384,
    'rev-parse', '--absolute-git-dir'), 'context gitdir');
  my $actual_common = exact_git_line(git_capture($root, 16_384,
    'rev-parse', '--git-common-dir'), 'context common-dir');
  my $actual_index = exact_git_line(git_capture($root, 16_384,
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
    unless exact_git_line(git_capture($root, 4096, 'rev-parse', '--verify', 'HEAD^{commit}'),
      'context HEAD') eq $head;
  fatal('internal Git context index tree changed')
    unless exact_git_line(git_capture($root, 4096, 'write-tree'), 'context tree') eq $tree;
}

sub clean_index_tree {
  my ($root) = @_;
  my $flags = git_capture($root, $MAX_GIT_OUTPUT, 'ls-files', '-v', '-z');
  for my $record (split /\x00/, $flags, -1) {
    next if $record eq q{};
    fatal('skip-worktree/assume-unchanged index flags are not allowed')
      if $record =~ /\A(?:[a-z]|S) /;
  }
  my $tree = exact_git_line(git_capture($root, 4096, 'write-tree'), 'write-tree');
  fatal('staged tree GitOid malformed') unless $tree =~ /\A$OID_RE\z/;
  return $tree;
}

sub pin_effective_index {
  my ($root) = @_;
  my $raw_path = exact_git_line(git_capture($root, 16_384,
    'rev-parse', '--git-path', 'index'), 'index path');
  my $path = $raw_path =~ m{\A/} ? $raw_path : "$root->{abs}/$raw_path";
  my $parent = abs_path(dirname($path));
  fatal('git index parent unavailable') unless defined($parent);
  (my $leaf = $path) =~ s{.*/}{};
  $path = "$parent/$leaf";
  my @named = lstat($path);
  fatal('git index must be regular, non-symlink, single-link')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or fatal('git index open failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('git index read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('git index exceeds safety limit') if length($raw) > $MAX_GIT_OUTPUT;
  }
  my @opened = stat($fh);
  fatal('git index identity changed')
    unless @opened && inode_id(\@opened) eq inode_id(\@named);
  return { path => $path, fh => $fh, opened => \@opened,
    size => length($raw), sha => sha256_hex($raw) };
}

sub check_index_pin {
  my ($pin) = @_;
  my @opened = stat($pin->{fh}); my @named = lstat($pin->{path});
  fatal('git index changed during TDD authority operation')
    unless @opened && @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && inode_id(\@opened) eq inode_id($pin->{opened})
      && inode_id(\@named) eq inode_id($pin->{opened})
      && $opened[7] == $pin->{size} && $named[7] == $pin->{size};
  defined(sysseek($pin->{fh}, 0, SEEK_SET)) or fatal('git index seek failed');
  my $raw = q{};
  while (1) {
    my $n = sysread($pin->{fh}, my $buf, 65_536);
    fatal('git index read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('git index exceeds safety limit') if length($raw) > $MAX_GIT_OUTPUT;
  }
  fatal('git index bytes changed during TDD authority operation')
    unless length($raw) == $pin->{size} && sha256_hex($raw) eq $pin->{sha};
}

sub tree_entries {
  my ($root, $tree) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT,
    'ls-tree', '-r', '-z', '--full-tree', $tree);
  my @record = split /\x00/, $raw, -1;
  fatal('staged tree listing is not NUL terminated') unless pop(@record) eq q{};
  fatal('staged tree is empty') unless @record;
  fatal('staged tree path cap exceeded') if @record > $MAX_PATHS;
  my (%entry, $prior);
  for my $record (@record) {
    my ($mode, $type, $oid, $path) =
      $record =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t(.*)\z/s;
    fatal('staged tree record malformed') unless defined($path);
    fatal('staged tree entry type/mode is unsupported')
      unless ($type eq 'blob' && $mode =~ /\A(?:100644|100755|120000)\z/)
        || ($type eq 'commit' && $mode eq '160000');
    safe_rel($path);
    fatal('staged tree is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $path };
    fatal('staged tree path duplicated') if exists($entry{$path});
    $entry{$path} = { mode => $mode, type => $type, oid => $oid };
    $prior = $path;
  }
  return \%entry;
}

sub verify_live_tree_bytes {
  my ($root, $entries, $blobs) = @_;
  for my $path (sort { use bytes; $a cmp $b } keys %$entries) {
    my $mode = $entries->{$path}{mode} eq '100755' ? 0755 : 0644;
    my $raw = read_repo_file($root, $path, $mode);
    my $expected = $blobs->{$entries->{$path}{oid}};
    fatal("live/index path mode or bytes differ: $path")
      unless defined($expected) && $raw eq $expected;
  }
}

sub cat_tree_blobs {
  my ($root, $entries) = @_;
  my %wanted = map { $entries->{$_}{oid} => 1 } keys %$entries;
  my @oid = sort keys %wanted;
  my ($request, $request_path) = tempfile('harness-tdd-cat-file.XXXXXX',
    TMPDIR => 1, UNLINK => 1);
  chmod(0600, $request_path) or fatal('cannot protect cat-file request');
  binmode($request, q{:raw});
  print {$request} "$_\n" for @oid;
  seek($request, 0, 0) or fatal('cannot rewind cat-file request');
  pipe(my $read, my $write) or fatal('cat-file pipe failed');
  my $pid = fork();
  fatal('cat-file fork failed') unless defined($pid);
  if ($pid == 0) {
    close($read);
    open(STDIN, '<&', $request) or POSIX::_exit(125);
    open(STDOUT, '>&', $write) or POSIX::_exit(125);
    close($write);
    chdir(q{/}) or POSIX::_exit(125);
    my @command = git_argv($root, 'cat-file', '--batch');
    exec { $command[0] } @command or POSIX::_exit(125);
  }
  close($write);
  close($request);
  binmode($read, q{:raw});
  my ($buffer, $eof, $total) = (q{}, 0, 0);
  my $fill = sub {
    return 0 if $eof;
    my $n = sysread($read, my $chunk, 65_536);
    fatal('cat-file output read failed') unless defined($n);
    if (!$n) { $eof = 1; return 0 }
    $buffer .= $chunk;
    return $n;
  };
  my $take_line = sub {
    while (1) {
      my $at = index($buffer, "\n");
      if ($at >= 0) {
        fatal('cat-file response header too large') if $at > 4096;
        return substr($buffer, 0, $at + 1, q{});
      }
      fatal('cat-file response header too large') if length($buffer) > 4096;
      $fill->() or fatal('cat-file response truncated');
    }
  };
  my $take_exact = sub {
    my ($size) = @_;
    while (length($buffer) < $size) {
      $fill->() or fatal('cat-file blob truncated');
    }
    return substr($buffer, 0, $size, q{});
  };
  my %blob;
  for my $oid (@oid) {
    my $header = $take_line->();
    $header =~ /\A\Q$oid\E blob (0|[1-9][0-9]*)\n\z/
      or fatal('cat-file response malformed');
    my $size = $1;
    fatal('snapshot blob exceeds 16 MiB') if length($size) > 8 || $size > $MAX_FILE;
    my $bytes = $take_exact->($size);
    fatal('cat-file framing malformed') unless $take_exact->(1) eq "\n";
    $total += $size;
    fatal('snapshot exceeds 512 MiB') if $total > $MAX_SNAPSHOT;
    $blob{$oid} = $bytes;
  }
  $fill->() unless $eof;
  fatal('cat-file returned extra output') if length($buffer);
  close($read) or fatal('cat-file output close failed');
  waitpid($pid, 0) == $pid or fatal('cat-file wait failed');
  fatal('cat-file process failed') unless $? == 0;
  return \%blob;
}

sub materialize_snapshot {
  my ($entries, $blobs) = @_;
  my $path = tempdir('harness-tdd-snapshot.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $path) or fatal('cannot protect execution snapshot');
  my (%made_dir, $total);
  for my $rel (sort { use bytes; $a cmp $b } keys %$entries) {
    my @part = safe_rel($rel);
    my $leaf = pop @part;
    my $dir = $path;
    my $prefix = q{};
    for my $component (@part) {
      $prefix = length($prefix) ? "$prefix/$component" : $component;
      $dir .= "/$component";
      next if $made_dir{$prefix};
      if (!mkdir($dir, 0700)) { fatal('snapshot directory collision') unless $! == EEXIST }
      my @s = lstat($dir);
      fatal('snapshot directory is unsafe')
        unless @s && !S_ISLNK($s[2]) && S_ISDIR($s[2]) && ($s[2] & 07777) == 0700;
      $made_dir{$prefix} = 1;
    }
    my $target = "$dir/$leaf";
    sysopen(my $fh, $target, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)
      or fatal('snapshot file creation failed');
    binmode($fh, q{:raw});
    my $raw = $blobs->{$entries->{$rel}{oid}};
    $total += length($raw);
    fatal('snapshot per-entry materialization exceeds 512 MiB')
      if $total > $MAX_SNAPSHOT;
    my $off = 0;
    while ($off < length($raw)) {
      my $n = syswrite($fh, $raw, length($raw) - $off, $off);
      fatal('snapshot file write failed') unless defined($n) && $n;
      $off += $n;
    }
    my $mode = $entries->{$rel}{mode} eq '100755' ? 0755 : 0644;
    chmod($mode, $fh) == 1 or fatal('snapshot file chmod failed');
    $fh->sync or fatal('snapshot file sync failed');
    close($fh) or fatal('snapshot file close failed');
  }
  return $path;
}

sub snapshot_manifest {
  my ($root_path) = @_;
  my @root = lstat($root_path);
  fatal('execution snapshot root changed')
    unless @root && !S_ISLNK($root[2]) && S_ISDIR($root[2])
      && ($root[2] & 07777) == 0700;
  sysopen(my $root_fh, $root_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('execution snapshot root open failed');
  my @root_opened = stat($root_fh);
  fatal('execution snapshot root identity changed')
    unless @root_opened && inode_id(\@root_opened) eq inode_id(\@root);
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
      fatal('unsafe snapshot name') if $name =~ /[\/\x00-\x1f\x7f]/ || $name eq q{..};
      my $rel = length($rel_dir) ? "$rel_dir/$name" : $name;
      chdir($dir) or fatal('snapshot directory traversal failed');
      my @named = lstat($name);
      fatal('snapshot entry vanished') unless @named;
      if (S_ISDIR($named[2]) && !S_ISLNK($named[2])) {
        fatal('snapshot directory mode changed') unless ($named[2] & 07777) == 0700;
        sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
          or fatal('snapshot directory open failed');
        my @opened = stat($child);
        fatal('snapshot directory identity changed')
          unless @opened && inode_id(\@opened) eq inode_id(\@named)
            && ($opened[2] & 07777) == 0700;
        push @row, "D\t$rel\t0700\n";
        $walk->($child, $rel);
        chdir($dir) or fatal('snapshot directory traversal failed');
        my @after = stat($child);
        my @renamed = lstat($name);
        fatal('snapshot directory changed during scan')
          unless @after && @renamed && !S_ISLNK($renamed[2])
            && inode_id(\@after) eq inode_id(\@opened)
            && inode_id(\@renamed) eq inode_id(\@opened)
            && ($after[2] & 07777) == 0700 && ($renamed[2] & 07777) == 0700;
        close($child) or fatal('snapshot directory close failed');
        next;
      }
      fatal('snapshot contains non-regular or linked entry')
        unless !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
      my $mode = $named[2] & 07777;
      fatal('snapshot file mode changed') unless $mode == 0644 || $mode == 0755;
      fatal('snapshot file exceeds 16 MiB') if $named[7] > $MAX_FILE;
      sysopen(my $fh, $name, O_RDONLY | O_NOFOLLOW) or fatal('snapshot file open failed');
      my @opened = stat($fh);
      fatal('snapshot file identity changed')
        unless @opened && inode_id(\@opened) eq inode_id(\@named);
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
      my @after = stat($fh);
      my @renamed = lstat($name);
      fatal('snapshot file changed during scan')
        unless @after && @renamed && !S_ISLNK($renamed[2])
          && inode_id(\@after) eq inode_id(\@opened)
          && inode_id(\@renamed) eq inode_id(\@opened)
          && $after[7] == length($raw) && $renamed[7] == length($raw)
          && ($after[2] & 07777) == $mode && ($renamed[2] & 07777) == $mode;
      close($fh) or fatal('snapshot file close failed');
      $total += length($raw);
      fatal('snapshot exceeds 512 MiB') if $total > $MAX_SNAPSHOT;
      push @row, join("\t", 'F', $rel, sprintf('%04o', $mode),
        length($raw), sha256_hex($raw)) . "\n";
    }
  };
  $walk->($root_fh, q{});
  my @root_after = stat($root_fh);
  my @root_named = lstat($root_path);
  fatal('execution snapshot root changed during scan')
    unless @root_after && @root_named && !S_ISLNK($root_named[2])
      && inode_id(\@root_after) eq inode_id(\@root_opened)
      && inode_id(\@root_named) eq inode_id(\@root_opened)
      && ($root_after[2] & 07777) == 0700 && ($root_named[2] & 07777) == 0700;
  close($root_fh) or fatal('execution snapshot root close failed');
  return sha256_hex("HARNESS-TDD-SNAPSHOT-V1\n" . join(q{},
    sort { use bytes; $a cmp $b } @row));
}

sub test_manifest_identity {
  my ($root, $spec, $test, $executed, $entries, $blobs) = @_;
  my $path = "$spec/test-manifest-v2.tsv";
  fatal('test manifest absent from staged tree') unless exists($entries->{$path});
  fatal('test manifest mode must be 100644') unless $entries->{$path}{mode} eq '100644';
  my $raw = $blobs->{$entries->{$path}{oid}};
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('test manifest is not UTF-8');
  my @line = split /\n/, $raw, -1;
  fatal('test manifest must end with one LF') unless pop(@line) eq q{};
  fatal('test manifest header mismatch') unless shift(@line) eq "test\trole\tpath";
  my (%seen, %declared, %path_role, $prior);
  for my $line (@line) {
    my @column = split /\t/, $line, -1;
    fatal('test manifest row malformed')
      unless @column == 3 && $column[0] =~ /\A$TEST_RE\z/
        && $column[1] =~ /\A(?:test-logic|sut|fixture|transitive)\z/;
    my ($row_test, $role, $input) = @column;
    safe_rel($input);
    my $key = "$row_test\0$role\0$input";
    fatal('test manifest is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $key };
    fatal('test manifest row duplicated') if $seen{$key}++;
    fatal('test manifest path has conflicting roles')
      if exists($path_role{$row_test}{$input}) && $path_role{$row_test}{$input} ne $role;
    if ($role ne 'sut') {
      fatal('stable test manifest input absent from staged tree')
        unless exists($entries->{$input});
      fatal('stable test manifest input is not a regular blob')
        unless $entries->{$input}{mode} eq '100644' || $entries->{$input}{mode} eq '100755';
    } elsif (exists($entries->{$input})) {
      fatal('SUT manifest path is not a regular blob')
        unless $entries->{$input}{mode} eq '100644' || $entries->{$input}{mode} eq '100755';
    } else {
      require_declared_absent($root, $input);
    }
    $declared{$row_test}{$input} = $role;
    $path_role{$row_test}{$input} = $role;
    $prior = $key;
  }
  fatal('test manifest has no inputs for primary TestId')
    unless defined($declared{$test}) && keys(%{$declared{$test}});
  fatal('executed TestId is absent from closed test manifest')
    unless defined($declared{$executed}) && keys(%{$declared{$executed}});
  my @primary_shape = sort { use bytes; $a cmp $b }
    map { $declared{$test}{$_} . "\0" . $_ } keys %{$declared{$test}};
  my @executed_shape = sort { use bytes; $a cmp $b }
    map { $declared{$executed}{$_} . "\0" . $_ } keys %{$declared{$executed}};
  fatal('primary/adjacent declared test closure differs')
    unless join("\0", @primary_shape) eq join("\0", @executed_shape);
  my @selected = sort { use bytes; $a cmp $b } keys %{$declared{$executed}};
  fatal('executed TestId has no test-logic input')
    unless grep { $declared{$executed}{$_} eq 'test-logic' } @selected;
  my %selected_entries = map { $_ => $entries->{$_} }
    grep { exists($entries->{$_}) } @selected;
  my $selected_blobs = cat_tree_blobs($root, \%selected_entries);
  for my $oid (keys %$selected_blobs) { $blobs->{$oid} = $selected_blobs->{$oid} }
  my $manifest = "HARNESS-TDD-TEST-MANIFEST-V2\nsource\t" . sha256_hex($raw) . "\n";
  for my $input (@selected) {
    my $role = $declared{$executed}{$input};
    if ($role eq 'sut') {
      $manifest .= join("\t", 'input', $role, $input) . "\n";
      next;
    }
    my $blob = $blobs->{$entries->{$input}{oid}};
    fatal("stable test manifest blob unavailable: $input") unless defined($blob);
    $manifest .= join("\t", 'input', $role, $input, $entries->{$input}{mode},
      length($blob), sha256_hex($blob)) . "\n";
  }
  my %selected = map { $_ => $declared{$executed}{$_} } @selected;
  return (sha256_hex($manifest), \%selected);
}

sub is_portable_system_interpreter {
  my ($arg) = @_;
  return 0 unless defined($arg);
  return scalar grep { $arg eq $_ } qw(/usr/bin/perl /bin/bash /bin/sh);
}

sub require_argv_repo_inputs_declared {
  my ($entries, $inputs, @argv) = @_;
  fatal('TDD command argv is empty') unless @argv;

  my $system_interpreter = $argv[0] =~ m{\A/} ? 1 : 0;
  if ($system_interpreter) {
    fatal('absolute TDD executable is not in the script-interpreter allowlist; use a declared repo-local 100755 wrapper')
      unless is_portable_system_interpreter($argv[0]);
    fatal('system interpreter requires one canonical repo test script operand')
      unless @argv >= 2;
    fatal('system interpreter command-string/options are forbidden before the test script')
      if $argv[1] =~ /\A-/;
  }

  my $logic_seen = 0;
  for my $index (0 .. $#argv) {
    next if $system_interpreter && $index == 0;
    my $arg = $argv[$index];
    my $interpreter_script = $system_interpreter && $index == 1;
    next unless $interpreter_script || index($arg, q{/}) >= 0;

    # Slash-bearing operands are repository paths, never opaque options. Otherwise an interpreter
    # could run /tmp/x, ./x or dir/../x while harmless declared test logic merely rides in argv.
    safe_rel($arg);
    fatal("repo path in TDD argv is not a declared test input: $arg")
      unless exists($inputs->{$arg});
    $logic_seen = 1 if $inputs->{$arg} eq 'test-logic';

    if ($interpreter_script) {
      fatal('system interpreter script must be declared test-logic')
        unless $inputs->{$arg} eq 'test-logic';
      fatal('system interpreter script must be a regular staged blob')
        unless exists($entries->{$arg}) && $entries->{$arg}{type} eq 'blob'
          && ($entries->{$arg}{mode} eq '100644' || $entries->{$arg}{mode} eq '100755');
    }
  }
  fatal('TDD argv does not bind a declared test-logic path') unless $logic_seen;
}

sub trusted_source_bytes {
  my ($path, $label) = @_;
  my @named = lstat($path);
  fatal("trusted producer source unavailable: $label")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && $named[3] == 1 && ($named[2] & 07777) == 0644;
  fatal("trusted producer source exceeds 16 MiB: $label") if $named[7] > $MAX_FILE;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW)
    or fatal("trusted producer source open failed: $label");
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal("trusted producer source read failed: $label") unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal("trusted producer source exceeds 16 MiB: $label") if length($raw) > $MAX_FILE;
  }
  my @opened = stat($fh);
  my @again = lstat($path);
  fatal("trusted producer source changed: $label")
    unless @opened && @again && !S_ISLNK($again[2]) && S_ISREG($again[2])
      && $opened[3] == 1 && $again[3] == 1
      && inode_id(\@opened) eq inode_id(\@named)
      && inode_id(\@again) eq inode_id(\@named)
      && ($opened[2] & 07777) == 0644 && ($again[2] & 07777) == 0644
      && $opened[7] == length($raw) && $again[7] == length($raw);
  close($fh) or fatal("trusted producer source close failed: $label");
  return $raw;
}

sub design_bootstrap_manifest {
  my ($root, $spec, $design) = @_;
  my $helper = "$SCRIPT_DIR/architecture-sdd-verify.pl";
  fatal('architecture verifier unavailable for producer authority') unless -f $helper;
  local %ENV = %ENV;
  delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
  open(my $fh, '-|', $^X, $helper, 'manifest', $root->{abs}, $spec)
    or fatal('Design-Root manifest launch failed for producer authority');
  binmode($fh, q{:raw});
  my $manifest = do { local $/; <$fh> // q{} };
  close($fh) or fatal('Design-Root manifest unavailable for producer authority');
  fatal('producer authority Design-Root mismatch') unless sha256_hex($manifest) eq $design;
  my $path = "$spec/producer-bootstrap-v1.tsv";
  my @line = split /\n/, $manifest, -1;
  fatal('Design-Root manifest malformed') unless pop(@line) eq q{}
    && shift(@line) eq 'HARNESS-DESIGN-ROOT-V1';
  my $row;
  for my $line (@line) {
    my ($kind, $candidate, $mode, $size, $sha) = split /\t/, $line, -1;
    next unless defined($sha) && $candidate eq $path;
    fatal('producer bootstrap Design-Root row duplicated') if defined($row);
    fatal('producer bootstrap Design-Root row malformed')
      unless $kind eq 'F' && $mode eq '100644'
        && $size =~ /\A(?:0|[1-9][0-9]*)\z/ && $sha =~ /\A$ROOT_RE\z/;
    $row = { size => $size, sha => $sha };
  }
  return undef unless defined($row);
  my $raw = read_repo_file($root, $path);
  fatal('producer bootstrap bytes differ from Design-Root')
    unless length($raw) == $row->{size} && sha256_hex($raw) eq $row->{sha};
  return $raw;
}

sub parse_bootstrap_producers {
  my ($raw) = @_;
  my @line = split /\n/, $raw, -1;
  fatal('producer-bootstrap-v1.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('producer-bootstrap-v1.tsv header mismatch')
    unless shift(@line) eq "path\tmode\tsha256";
  my @expected = qw(scripts/implementation-tdd-verify.pl scripts/tdd-receipt-v1.pl);
  fatal('producer-bootstrap-v1.tsv producer set mismatch') unless @line == @expected;
  my %sha;
  for my $i (0 .. $#expected) {
    my @c = split /\t/, $line[$i], -1;
    fatal('producer-bootstrap-v1.tsv row malformed')
      unless @c == 3 && $c[0] eq $expected[$i]
        && $c[1] eq '100644' && $c[2] =~ /\A$ROOT_RE\z/;
    $sha{$c[0]} = $c[2];
  }
  return \%sha;
}

sub base_producer_bytes {
  my ($root, $base, $repo_path) = @_;
  my $listed = git_capture($root, 4096, 'ls-tree', '-z', $base, '--', $repo_path);
  return undef if $listed eq q{};
  my ($mode, $type, $oid, $path) =
    $listed =~ /\A([0-7]{6}) ([a-z]+) ($OID_RE)\t(.*)\x00\z/s;
  fatal("base producer tree row malformed: $repo_path") unless defined($path);
  fatal("base producer path/mode/type mismatch: $repo_path")
    unless $path eq $repo_path && $mode eq '100644' && $type eq 'blob';
  return git_capture($root, $MAX_FILE + 1, 'cat-file', 'blob', $oid);
}

sub producer_identity {
  my ($root, $spec, $impl) = @_;
  my %base_raw;
  my $present = 0;
  for my $name (qw(tdd-receipt-v1.pl implementation-tdd-verify.pl)) {
    my $raw = base_producer_bytes($root, $impl->{base}, "scripts/$name");
    $base_raw{$name} = $raw;
    $present++ if defined($raw);
  }
  fatal('base producer set is partial') if $present != 0 && $present != 2;
  my $bootstrap = design_bootstrap_manifest($root, $spec, $impl->{design});
  fatal('producer bootstrap is forbidden when producer exists in base')
    if $present == 2 && defined($bootstrap);
  my $bootstrap_sha = $present == 0
    ? parse_bootstrap_producers(defined($bootstrap) ? $bootstrap
        : fatal('producer absent from base and reviewed producer-bootstrap-v1.tsv is missing'))
    : undef;
  my $manifest = "HARNESS-TDD-PRODUCER-V1\n";
  for my $name (qw(tdd-receipt-v1.pl implementation-tdd-verify.pl)) {
    my $live = trusted_source_bytes("$SCRIPT_DIR/$name", $name);
    if ($present == 2) {
      fatal("live trusted producer differs from immutable base: $name")
        unless $live eq $base_raw{$name};
    } else {
      fatal("live trusted producer differs from reviewed bootstrap: $name")
        unless sha256_hex($live) eq $bootstrap_sha->{"scripts/$name"};
    }
    $manifest .= join("\t", $name, length($live), sha256_hex($live)) . "\n";
  }
  return sha256_hex($manifest);
}

sub read_executable_file {
  my ($path) = @_;
  my @named = lstat($path);
  fatal('TDD executable must be regular, non-symlink, single-link and executable')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && $named[3] == 1 && ($named[2] & 0111);
  fatal('TDD executable exceeds 16 MiB') if $named[7] > $MAX_FILE;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or fatal('TDD executable open failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('TDD executable read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('TDD executable exceeds 16 MiB') if length($raw) > $MAX_FILE;
  }
  close($fh) or fatal('TDD executable close failed');
  my @again = lstat($path);
  fatal('TDD executable changed during identity read')
    unless @again && inode_id(\@again) eq inode_id(\@named)
      && $again[7] == length($raw) && ($again[2] & 0111);
  return sha256_hex($raw);
}

sub executable_identity {
  my ($snapshot, $entries, $inputs, $arg) = @_;
  if ($arg =~ m{\A/}) {
    fatal('absolute TDD executable is not in the script-interpreter allowlist; use a declared repo-local 100755 wrapper')
      unless is_portable_system_interpreter($arg);
    my $canonical = abs_path($arg);
    fatal('host executable unavailable') unless defined($canonical);
    return ($canonical, read_executable_file($canonical));
  }
  safe_rel($arg);
  fatal('repo-local executable must contain a path separator') unless $arg =~ m{/};
  fatal('repo-local executable is not declared test-logic')
    unless defined($inputs->{$arg}) && $inputs->{$arg} eq 'test-logic';
  fatal('repo-local executable absent or non-executable in staged tree')
    unless exists($entries->{$arg}) && $entries->{$arg}{mode} eq '100755';
  return ("$snapshot/$arg", read_executable_file("$snapshot/$arg"));
}

sub argv_template_digest {
  my ($executed, @argv) = @_;
  fatal('TDD command argv is empty') unless @argv;
  fatal('TDD command argv has too many elements') if @argv > 64;
  my $seen = 0;
  my $total = 0;
  my @normalized;
  for my $arg (@argv) {
    if ($arg eq $executed) {
      ++$seen;
      push @normalized, '${HARNESS_EXECUTED_TEST_ID}';
    } else {
      push @normalized, $arg;
    }
    $total += length($arg);
    fatal('TDD argv exceeds 64 KiB') if $total > 65_536;
  }
  fatal('TDD argv must contain executed TestId exactly once') unless $seen == 1;
  my $manifest = "HARNESS-TDD-ARGV-TEMPLATE-V1\n";
  for my $arg (@normalized) {
    fatal('TDD argv element exceeds 4096 bytes') if length($arg) > 4096;
    $manifest .= length($arg) . "\t" . sha256_hex($arg) . "\n";
  }
  return sha256_hex($manifest);
}

sub content_authority {
  my ($root, $spec, $impl) = @_;
  my $helper = "$SCRIPT_DIR/implementation-tdd-verify.pl";
  fatal('implementation verifier unavailable') unless -f $helper;
  local %ENV = %ENV;
  delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
  open(my $fh, '-|', $^X, $helper, 'content-contract', $root->{abs}, $spec,
    $impl->{base}, $impl->{design}, $impl->{attempt})
      or fatal('implementation content verifier launch failed');
  my $out = do { local $/; <$fh> // q{} };
  close($fh) or fatal('implementation content authority is not verifiable');
  $out =~ /\AContent-Root: ($ROOT_RE)\nExpected-Contract-SHA256: ($ROOT_RE)\n\z/
    or fatal('implementation content authority output malformed');
  return ($1, $2);
}

sub resolve_executable {
  my ($root, $arg) = @_;
  fatal('executable argv contains control byte') if $arg =~ /[\x00-\x1f\x7f]/;
  my $path;
  if ($arg =~ m{\A/}) {
    fatal('absolute TDD executable is not in the script-interpreter allowlist; use a declared repo-local 100755 wrapper')
      unless is_portable_system_interpreter($arg);
    $path = abs_path($arg);
    fatal('host executable unavailable') unless defined($path);
  } else {
    safe_rel($arg);
    fatal('repo-local executable must contain a path separator') unless $arg =~ m{/};
    $path = "$root->{abs}/$arg";
  }
  my @s = lstat($path);
  fatal('TDD executable must be regular, non-symlink, single-link and executable')
    unless @s && !S_ISLNK($s[2]) && S_ISREG($s[2]) && $s[3] == 1 && ($s[2] & 0111);
  return $path;
}

sub close_inherited_fds {
  for my $directory (qw(/proc/self/fd /dev/fd)) {
    next unless opendir(my $dh, $directory);
    my $scanner = fileno($dh);
    my @fd = grep { /\A[0-9]+\z/ && $_ > 2 && $_ != $scanner } readdir($dh);
    closedir($dh) or exit 125;
    POSIX::close($_) for @fd;
    return;
  }
  my $maximum = POSIX::sysconf(POSIX::_SC_OPEN_MAX());
  exit 125 unless defined($maximum) && $maximum >= 3 && $maximum <= 16_777_216;
  POSIX::close($_) for 3 .. $maximum - 1;
}

sub cleanup_scratch {
  my ($scratch, $scratch_fh, $opened) = @_;
  my @named = lstat($scratch);
  my @held = stat($scratch_fh);
  fatal('TDD scratch identity changed before cleanup')
    unless @named && @held && !S_ISLNK($named[2]) && S_ISDIR($named[2])
      && inode_id(\@named) eq inode_id($opened) && inode_id(\@held) eq inode_id($opened)
      && $named[4] == $< && $held[4] == $<;
  chmod(0700, $scratch_fh) == 1 or fatal('TDD scratch chmod before cleanup failed');
  close($scratch_fh) or fatal('TDD scratch descriptor close failed');
  my @again = lstat($scratch);
  fatal('TDD scratch identity changed at cleanup boundary')
    unless @again && !S_ISLNK($again[2]) && S_ISDIR($again[2])
      && inode_id(\@again) eq inode_id($opened) && ($again[2] & 07777) == 0700;
  my $errors;
  remove_tree($scratch, { safe => 1, error => \$errors });
  fatal('TDD scratch cleanup failed')
    if (defined($errors) && @$errors) || lstat($scratch);
}

sub run_command {
  my ($root, $expected_executable, @argv) = @_;
  my $exe = resolve_executable($root, $argv[0]);
  fatal('TDD executable canonical path changed before execution')
    unless $exe eq $expected_executable;
  my $scratch = tempdir('harness-tdd-run.XXXXXX', TMPDIR => 1, CLEANUP => 1);
  chmod(0700, $scratch) or fatal('cannot protect TDD scratch directory');
  sysopen(my $scratch_fh, $scratch, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('TDD scratch descriptor open failed');
  my @scratch_opened = stat($scratch_fh);
  fatal('TDD scratch descriptor is unsafe')
    unless @scratch_opened && S_ISDIR($scratch_opened[2])
      && ($scratch_opened[2] & 07777) == 0700 && $scratch_opened[4] == $<;
  pipe(my $out_r, my $out_w) or fatal('stdout pipe failed');
  pipe(my $err_r, my $err_w) or fatal('stderr pipe failed');
  pipe(my $ready_r, my $ready_w) or fatal('TDD supervisor ready pipe failed');
  pipe(my $status_r, my $status_w) or fatal('TDD supervisor status pipe failed');
  pipe(my $life_r, my $life_w) or fatal('TDD runtime liveness pipe failed');
  my $life_flags = fcntl($life_w, F_GETFD, 0);
  defined($life_flags) && defined(fcntl($life_w, F_SETFD, $life_flags | FD_CLOEXEC))
    or fatal('TDD runtime liveness CLOEXEC failed');
  my $start = monotonic_now();
  my $deadline = $start + $PROCESS_TIMEOUT;
  # Cancellation stays blocked until the child has completed setsid(), acknowledged the exact
  # owned PGID, and the runtime has published that PGID to its cancellation handler.
  my ($cancel_set, $prior_cancel) = block_cancellation('TDD process launch');
  my $pid = fork();
  unless (defined($pid)) {
    close($life_r); close($life_w);
    restore_cancellation($prior_cancel, undef, 'TDD process launch');
    fatal('TDD process fork failed');
  }
  if ($pid == 0) {
    close($out_r); close($err_r); close($ready_r); close($status_r); close($life_w);
    setsid() >= 0 or POSIX::_exit(125);
    $SIG{PIPE} = 'IGNORE';
    my $abort_group = sub {
      kill 'KILL', -$$;
      POSIX::_exit(125);
    };
    syswrite($ready_w, "1", 1) == 1 or $abort_group->();
    close($ready_w) or $abort_group->();
    sigprocmask(SIG_SETMASK, $prior_cancel) or $abort_group->();

    my $command = fork();
    $abort_group->() unless defined($command);
    if ($command == 0) {
      $SIG{PIPE} = 'DEFAULT';
      close($status_w); close($life_r);
      open(STDIN, '<', '/dev/null') or POSIX::_exit(125);
      open(STDOUT, '>&', $out_w) or POSIX::_exit(125);
      open(STDERR, '>&', $err_w) or POSIX::_exit(125);
      close($out_w); close($err_w);
      chdir($root->{abs}) or POSIX::_exit(125);
      %ENV = (
        PATH => '/usr/bin:/bin:/usr/sbin:/sbin', LC_ALL => 'C', LANG => 'C', TZ => 'UTC',
        HOME => $scratch, TMPDIR => $scratch,
        GIT_CONFIG_NOSYSTEM => '1', GIT_CONFIG_GLOBAL => '/dev/null',
        GIT_CONFIG_SYSTEM => '/dev/null', GIT_NO_REPLACE_OBJECTS => '1',
        GIT_OPTIONAL_LOCKS => '0',
      );
      close_inherited_fds();
      exec { $exe } @argv or POSIX::_exit(125);
    }

    close($out_w); close($err_w);
    my $parent_watch = IO::Select->new($life_r);
    my $command_wait_status;
    while (1) {
      my $got = waitpid($command, WNOHANG);
      if ($got == $command) { $command_wait_status = $?; last }
      if ($got == -1) {
        next if $! == EINTR;
        $abort_group->();
      }
      for my $fh ($parent_watch->can_read(0.05)) {
        my $n = sysread($fh, my $byte, 1);
        next if !defined($n) && $! == EINTR;
        $abort_group->();
      }
    }
    my $message = $command_wait_status . "\n";
    my $offset = 0;
    while ($offset < length($message)) {
      my $written = syswrite($status_w, $message, length($message) - $offset, $offset);
      $abort_group->() unless defined($written) && $written > 0;
      $offset += $written;
    }
    close($status_w) or $abort_group->();

    # The unreaped session leader pins PID/PGID ownership until the parent has terminated the exact
    # initial owned process group. A trusted test deliberately changing process group or calling
    # setsid(2) crosses the documented trusted-host boundary and is outside this portable guarantee.
    while (1) {
      for my $fh ($parent_watch->can_read()) {
        my $n = sysread($fh, my $byte, 1);
        next if !defined($n) && $! == EINTR;
        $abort_group->();
      }
    }
  }
  close($out_w); close($err_w); close($ready_w); close($status_w); close($life_r);

  my ($timeout, $overflow, $status_invalid, $terminating) = (0, 0, 0, 0);
  my $drain_deadline;
  my $leader_ready = 0;
  my $ready_wait = $deadline - monotonic_now();
  $ready_wait = 0 if $ready_wait < 0;
  my @ready = IO::Select->new($ready_r)->can_read($ready_wait);
  if (@ready) {
    my $n = sysread($ready_r, my $value, 1);
    $leader_ready = 1 if defined($n) && $n == 1 && $value eq q{1};
  } else {
    $timeout = 1;
  }
  close($ready_r);

  # Only the one-byte post-setsid acknowledgement authorizes group-directed signals.  Keep the
  # leader unreaped until the final signal boundary so the numeric PID/PGID cannot be recycled.
  local $ACTIVE_PROCESS_GROUP = $leader_ready ? $pid : undef;

  my $terminate_group = sub {
    return if $terminating++;
    if ($leader_ready) {
      # Positive then negative signals are safe while the exact leader is live or an unreaped
      # zombie: its numeric PID cannot be recycled between these operations.
      kill 'TERM', $pid;
      kill 'TERM', -$pid;
    } else {
      kill 'TERM', $pid;
    }
    sleep 0.05;
    if ($leader_ready) {
      kill 'KILL', $pid;
      kill 'KILL', -$pid;
    } else {
      kill 'KILL', $pid;
    }
    $drain_deadline = monotonic_now() + 1;
  };
  $terminate_group->() unless $leader_ready;
  restore_cancellation($prior_cancel, $leader_ready ? $pid : undef,
    'TDD process launch');

  for my $fh ($out_r, $err_r, $status_r) {
    my $flags = fcntl($fh, F_GETFL, 0);
    unless (defined($flags) && fcntl($fh, F_SETFL, $flags | O_NONBLOCK)) {
      if ($leader_ready) { stop_process_group($pid) }
      else {
        $terminate_group->();
        $ACTIVE_PROCESS_GROUP = undef;
        while (1) {
          my $got = waitpid($pid, 0);
          last if $got == $pid || ($got == -1 && $! == ECHILD);
          next if $got == -1 && $! == EINTR;
          last;
        }
      }
      fatal('cannot configure receipt stream');
    }
  }
  my $selector = IO::Select->new($out_r, $err_r, $status_r);
  my %kind = (fileno($out_r) => 'stdout', fileno($err_r) => 'stderr',
    fileno($status_r) => 'status');
  my %data = (stdout => q{}, stderr => q{});
  my ($status_raw, $command_status);
  $status_raw = q{};
  while ($selector->count) {
    my $now = monotonic_now();
    if (!$terminating && $now >= $deadline) {
      $timeout = 1;
      $terminate_group->();
    }
    if ($terminating && $selector->count && monotonic_now() >= $drain_deadline) {
      for my $fh ($selector->handles) {
        $selector->remove($fh);
        close($fh);
      }
    }
    for my $fh ($selector->can_read(0.05)) {
      my $stream = $kind{fileno($fh)};
      my $n = sysread($fh, my $buf, 65_536);
      if (!defined($n)) {
        next if $! == EAGAIN || $! == EWOULDBLOCK;
        if ($stream eq 'status') { $status_invalid = 1 }
        else { $overflow = 1 }
        $selector->remove($fh); close($fh); $terminate_group->(); next;
      }
      if (!$n) {
        $selector->remove($fh); close($fh);
        if ($stream eq 'status') {
          if ($status_raw =~ /\A([0-9]{1,10})\n\z/ && $1 <= 65_535) {
            $command_status = 0 + $1;
          } else {
            $status_invalid = 1;
          }
          # Normal completion is a terminal boundary too: kill the pinned owned group before
          # snapshot/scratch verification, even when descendants closed all three stdio streams.
          $terminate_group->();
        }
        next;
      }
      if ($stream eq 'status') {
        $status_raw .= $buf;
        if (length($status_raw) > 32) {
          $status_invalid = 1;
          $selector->remove($fh); close($fh); $terminate_group->();
        }
        next;
      }
      $data{$stream} .= $buf;
      if (length($data{$stream}) > $MAX_STREAM) {
        $overflow = 1;
        $data{$stream} = substr($data{$stream}, 0, $MAX_STREAM);
        $terminate_group->();
      }
    }
  }
  # Cancellation is blocked across the terminal signals, authority drop and waitpid.  Once the
  # exact leader is reaped, neither the mainline nor a deferred handler retains signalling power.
  my ($reap_set, $prior_reap) = block_cancellation('TDD supervisor reap');
  $terminate_group->() unless $terminating;
  $ACTIVE_PROCESS_GROUP = undef;
  my $leader_status;
  while (1) {
    my $got = waitpid($pid, 0);
    if ($got == $pid) { $leader_status = $?; last }
    next if $got == -1 && $! == EINTR;
    fatal('TDD supervisor wait failed');
  }
  close($life_w) or fatal('TDD runtime liveness close failed');
  restore_cancellation($prior_reap, undef, 'TDD supervisor reap');
  my $status = defined($command_status) ? $command_status : $leader_status;
  my $duration = int((monotonic_now() - $start) * 1000 + 0.5);
  $duration = $MAX_GENERATION if $duration > $MAX_GENERATION;
  my $exit = $timeout ? 'timeout'
    : ($status & 127) ? 'signal-' . ($status & 127)
    : (($status >> 8) & 255);
  cleanup_scratch($scratch, $scratch_fh, \@scratch_opened);

  my $reserved_count = () =
    ($data{stdout} =~ /(?:(?<=\n)|\A)\QHARNESS-TDD-RESULT-V1\E/g);
  my @protocol = ($data{stdout} =~ /(?:(?<=\n)|\A)HARNESS-TDD-RESULT-V1\t($TEST_RE)\t(assertion-failed|assertion-passed)\t($ROOT_RE)\n/g);
  my ($executed, $observed, $signature);
  my $reserved_invalid = $reserved_count > 0
    && !($reserved_count == 1 && @protocol == 3);
  if ($reserved_count == 1 && @protocol == 3) {
    ($executed, $observed, $signature) = @protocol;
  }
  my $result;
  if ($timeout) { $result = 'timeout'; $signature = 'none' }
  elsif ($overflow) { $result = 'invalid-output'; $signature = 'none' }
  elsif ($status_invalid) { $result = 'setup-failed'; $signature = 'none' }
  elsif ($reserved_invalid) { $result = 'invalid-output'; $signature = 'none' }
  elsif (!defined($observed)) {
    $result = $exit =~ /\A(?:[1-9][0-9]*|signal-)/ ? 'setup-failed' : 'invalid-output';
    $signature = 'none';
  } else { $result = $observed }
  return {
    result => $result, exit => "$exit", signature => $signature,
    executed => $executed, stdout => sha256_hex($data{stdout}),
    stderr => sha256_hex($data{stderr}), duration => $duration,
  };
}

sub split_argv {
  my (@arg) = @_;
  my $seen = 0;
  my (@head, @argv);
  for my $v (@arg) {
    if (!$seen && $v eq '--') { $seen = 1; next }
    push @{$seen ? \@argv : \@head}, $v;
  }
  fatal('missing -- before TDD argv') unless $seen;
  fatal('TDD command argv is empty') unless @argv;
  return (\@head, \@argv);
}

sub dispatch_runtime_command {
sanitize_git_environment();
my $command = shift(@ARGV) // fatal('missing command');

if ($command eq 'verify-producer') {
  @ARGV == 4 or fatal('usage: verify-producer <repo> <SPEC> <base> <Design-Root>');
  my ($root_arg, $spec, $base, $design) = @ARGV;
  $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/
    or fatal('SPEC_DIR grammar mismatch');
  $base =~ /\A$OID_RE\z/ && $design =~ /\A$ROOT_RE\z/
    or fatal('producer authority identity malformed');
  my $root = open_root($root_arg);
  configure_internal_git_context($root);
  my $impl = { base => $base, design => $design };
  print producer_identity($root, $spec, $impl) . "\n";
  runtime_exit(0);
}

if ($command eq 'run') {
  my ($head, $argv) = split_argv(@ARGV);
  @$head == 8 or fatal('usage: run <repo> <SPEC> <test> <phase> <executed> <run> <implementation> <actor> -- <argv...>');
  my ($root_arg, $spec, $test, $phase, $executed, $run, $implementation, $actor) = @$head;
  $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/ or fatal('SPEC_DIR grammar mismatch');
  $test =~ /\A$TEST_RE\z/ && $executed =~ /\A$TEST_RE\z/ or fatal('TestId malformed');
  $phase =~ /\A(?:red|green|adjacent)\z/ or fatal('phase malformed');
  $run =~ /\A$ATTEMPT_RE\z/ && $implementation =~ /\A$ATTEMPT_RE\z/ or fatal('attempt malformed');
  $actor =~ /\A$ACTOR_RE\z/ or fatal('actor malformed');
  my $root = open_root($root_arg);
  configure_internal_git_context($root);
  my $top = exact_git_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'git root');
  fatal('repo root is not canonical git toplevel') unless abs_path($top) eq $root->{abs};
  my $raw = read_repo_file($root, "$spec/audit.md");
  my $parsed = parse_audit($raw);
  my $impl = $parsed->{implementation};
  fatal('current implementation-start absent') unless defined($impl);
  fatal('implementation attempt mismatch') unless $impl->{attempt} eq $implementation;
  fatal('TDD actor must equal implementation actor') unless $impl->{actor} eq $actor;
  fatal('duplicate TDD run ID') if $parsed->{used_run}{$run};
  my $tree = clean_index_tree($root);
  my $index_pin = pin_effective_index($root);
  my $entries = tree_entries($root, $tree);
  my $manifest_path = "$spec/test-manifest-v2.tsv";
  fatal('test manifest absent from staged tree') unless exists($entries->{$manifest_path});
  fatal('test manifest is not a regular 100644 blob')
    unless $entries->{$manifest_path}{type} eq 'blob'
      && $entries->{$manifest_path}{mode} eq '100644';
  my %manifest_entry = ($manifest_path => $entries->{$manifest_path});
  my $blobs = cat_tree_blobs($root, \%manifest_entry);
  my ($manifest_sha, $inputs) =
    test_manifest_identity($root, $spec, $test, $executed, $entries, $blobs);
  require_argv_repo_inputs_declared($entries, $inputs, @$argv);
  my %snapshot_entries = map { $_ => $entries->{$_} }
    grep { exists($entries->{$_}) } keys %$inputs;
  verify_live_tree_bytes($root, \%snapshot_entries, $blobs);
  my ($root_value, $contract) = content_authority($root, $spec, $impl);
  my $snapshot_path = materialize_snapshot(\%snapshot_entries, $blobs);
  my $snapshot = open_root($snapshot_path);
  my $snapshot_before = snapshot_manifest($snapshot_path);
  my ($executable_path, $executable_sha) =
    executable_identity($snapshot_path, \%snapshot_entries, $inputs, $argv->[0]);
  my $argv_template = argv_template_digest($executed, @$argv);
  my $producer = producer_identity($root, $spec, $impl);
  my %identity = (contract => $contract, manifest => $manifest_sha, executable => $executable_sha,
    argv_template => $argv_template, producer => $producer);
  can_start_phase($parsed, $test, $phase, $executed, $root_value, \%identity);
  my $start_detail = join(q{;}, "test=$test", "phase=$phase", "executed=$executed", "run=$run",
    "generation=$parsed->{generation}", "implementation=$implementation", "actor=$actor",
    "root=$root_value", "contract=$contract", "tree=$tree", "test-manifest=$manifest_sha",
    "executable=$executable_sha", "argv-template=$argv_template", "producer=$producer",
    "timeout=$TIMEOUT");

  my $result = run_command($snapshot, $executable_path, @$argv);
  my $snapshot_after = snapshot_manifest($snapshot_path);
  fatal('execution snapshot path/mode/bytes changed') unless $snapshot_after eq $snapshot_before;
  my ($executable_path_after, $executable_after) =
    executable_identity($snapshot_path, \%snapshot_entries, $inputs, $argv->[0]);
  fatal('TDD executable identity changed during execution')
    unless $executable_path_after eq $executable_path
      && $executable_after eq $executable_sha;
  fatal('staged tree or live/index cleanliness changed during TDD execution')
    unless clean_index_tree($root) eq $tree;
  check_index_pin($index_pin);
  verify_live_tree_bytes($root, \%snapshot_entries, $blobs);
  fatal('audit changed during TDD execution')
    unless read_repo_file($root, "$spec/audit.md") eq $raw;
  my ($root_after, $contract_after) = content_authority($root, $spec, $impl);
  fatal('content root changed during TDD execution') unless $root_after eq $root_value;
  fatal('expected-contract digest changed during TDD execution')
    unless $contract_after eq $contract;
  fatal('trusted TDD producer changed during execution')
    unless producer_identity($root, $spec, $impl) eq $producer;
  check_root($root);
  check_index_pin($index_pin);
  close($index_pin->{fh}) or fatal('git index close failed');
  my $observed_signature = $result->{signature};
  if (defined($result->{executed}) && $result->{executed} ne $executed) {
    $result->{result} = 'invalid-output'; $observed_signature = 'none';
  }
  my $finish_detail = join(q{;}, $start_detail,
    "result=$result->{result}", "exit=$result->{exit}",
    "signature=$observed_signature", "stdout=$result->{stdout}", "stderr=$result->{stderr}",
    "duration-ms=$result->{duration}");
  my $terminal = parse_common($finish_detail, 1);
  my $ok = accepted($terminal) ? 'yes' : 'no';
  print "Start-Detail: $start_detail\nFinish-Detail: $finish_detail\n";
  print "Audit-SHA256: " . sha256_hex($raw) . "\nAccepted: $ok\n";
  runtime_exit(0);
}

if ($command eq 'verify-chain') {
  @ARGV == 3 or fatal('usage: verify-chain <repo> <SPEC> <implementation-attempt>');
  my ($root_arg, $spec, $implementation) = @ARGV;
  $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/ or fatal('SPEC_DIR grammar mismatch');
  $implementation =~ /\A$ATTEMPT_RE\z/ or fatal('implementation attempt malformed');
  my $root = open_root($root_arg);
  configure_internal_git_context($root);
  my $raw = read_repo_file($root, "$spec/audit.md");
  my $parsed = parse_audit($raw);
  fatal('current implementation-start absent') unless defined($parsed->{implementation});
  fatal('implementation attempt mismatch') unless $parsed->{implementation}{attempt} eq $implementation;
  fatal('open TDD receipt prevents verification') if defined($parsed->{open});
  my $producer = producer_identity($root, $spec, $parsed->{implementation});
  for my $test (sort keys %{$parsed->{phase}}) {
    for my $phase (qw(red green adjacent)) {
      next unless my $r = $parsed->{phase}{$test}{$phase};
      fatal('current TDD receipt predates expected-contract authority; rerun implementation TDD')
        if $r->{legacy_contract};
      fatal('TDD receipt producer differs from current trusted producer')
        unless $r->{producer} eq $producer;
      my $detail = join(q{;},
        (map { "$_=$r->{$_}" } qw(test phase executed run generation implementation actor root contract tree)),
        "test-manifest=$r->{manifest}", "executable=$r->{executable}",
        "argv-template=$r->{argv_template}", "producer=$r->{producer}", "timeout=$TIMEOUT",
        "result=$r->{result}", "exit=$r->{exit}",
        "signature=$r->{signature}", "stdout=$r->{stdout}", "stderr=$r->{stderr}",
        "duration-ms=$r->{duration}");
      print "Receipt: $detail\n";
    }
  }
  fatal('audit changed during TDD chain verification')
    unless read_repo_file($root, "$spec/audit.md") eq $raw;
  print "Audit-SHA256: " . sha256_hex($raw) . "\n";
  runtime_exit(0);
}

fatal('usage: tdd-receipt-v1.pl <run|verify-chain|verify-producer> ...');
}

binmode(STDOUT, q{:raw}); binmode(STDERR, q{:raw});
STDOUT->autoflush(1); STDERR->autoflush(1);
enter_dedicated_runtime();
my $dispatch_ok = eval { dispatch_runtime_command(); 1 };
my $dispatch_error = $@;
unless ($dispatch_ok) {
  arm_dedicated_runtime_teardown();
  print STDERR length($dispatch_error) ? $dispatch_error : "tdd-receipt-v1: runtime exception\n";
  runtime_exit(255);
}
fatal('dedicated TDD runtime dispatch returned unexpectedly');
