#!/usr/bin/env perl
# private-temp-dir.pl — descriptor/inode-bound guard and cleanup for private run directories.
#
# Usage:
#   perl scripts/private-temp-dir.pl id      <dir>          # parent-dev:ino|run-dev:ino
#   perl scripts/private-temp-dir.pl guard   <dir> <id>
#   perl scripts/private-temp-dir.pl run     <dir> <id> <stdout-leaf|-> <stderr-leaf|-> -- <command...>
#   perl scripts/private-temp-dir.pl run-bounded <dir> <id> <seconds> \
#     <stdout-leaf|-> <stderr-leaf|-> -- <command...>
#   perl scripts/private-temp-dir.pl run-bounded-fd8 <dir> <id> <seconds> \
#     <stdout-leaf|-> <stderr-leaf|-> -- <command...>  # preserve exactly inherited FD8
#   perl scripts/private-temp-dir.pl run-bounded-test-delay <dir> <id> <seconds> <delay-ms> \
#     <stdout-leaf|-> <stderr-leaf|-> -- <command...>  # focused cleanup-budget self-test
#   perl scripts/private-temp-dir.pl fd-exec <keep-fd-csv|-> -- <command...>
#   perl scripts/private-temp-dir.pl seal-gitdir-config <gitdir> <gitdir-id> <sha1|sha256>
#   perl scripts/private-temp-dir.pl verify-gitdir-config <gitdir> <gitdir-id> \
#     <sha1|sha256> <-|config-record>
#   perl scripts/private-temp-dir.pl config-gitdir-exec-clean <dir> <id> \
#     <credential-leaf> <credential-record> <gitdir> <gitdir-id> <sha1|sha256> \
#     <-|config-record> <objects> -- <command...>
#   perl scripts/private-temp-dir.pl worktree-proof <dir> <id> <gitdir> <worktree> <head> <mode> [spec]
#   perl scripts/private-temp-dir.pl cleanup <dir> <id>
#   perl scripts/private-temp-dir.pl guard-leaves <dir> <id> <-|leaf[,leaf...]>
#
# The helper never recursively follows the visible pathname during cleanup.  It opens the exact
# directory (or finds its renamed inode inside the recorded parent), scrubs children relative to
# pinned directory descriptors, and removes only the directory whose device/inode was recorded.
# A replacement at the old pathname is preserved.  Diagnostics are intentionally metadata-only.
use strict;
use warnings;
use Errno qw(ENOENT EEXIST);
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_RDONLY O_WRONLY O_RDWR O_CREAT O_EXCL O_DIRECTORY O_NOFOLLOW
  F_SETFD S_ISDIR S_ISLNK S_ISREG);
use File::Basename qw(dirname);
use Cwd qw(getcwd);
use IO::Select;
use POSIX ();
use Time::HiRes qw(time sleep);

my (%PROOF_DIR_CACHE, @AUTHORITY_DIR_PINS);
# Parent authors one absolute cleanup envelope. The leader spends at most the work portion and
# keeps the final reserve for a one-byte proof ACK, so load cannot create two racing timeouts.
my $CLEANUP_PROOF_BUDGET_SECONDS = 12;
my $CLEANUP_ACK_RESERVE_SECONDS = 0.50;
my $ENUMERATION_TEST_DELAY_SECONDS = 0;
my $ENUMERATION_TEST_DELAY_USED = 0;

sub oid {
    my (@s) = @_;
    return "$s[0]:$s[1]";
}

sub fail {
    exit 1;
}

# Perl's close-on-exec policy does not cover arbitrary descriptors inherited from the caller.
# Every exec boundary therefore enumerates the kernel FD view and retains only stdio plus the
# explicitly named capability handles.  This is portable to the macOS baseline (/dev/fd) and has
# a bounded /proc/self/fd/sysconf fallback for other runners.
sub close_fds_except {
    my (@keep_handle) = @_;
    my %keep = (0 => 1, 1 => 1, 2 => 1);
    for my $handle (@keep_handle) {
        my $fd = ref($handle) ? fileno($handle) : $handle;
        fail() unless defined($fd) && $fd =~ /\A[0-9]+\z/;
        $keep{$fd} = 1;
    }
    my @close;
    my $listed = 0;
    for my $fd_root (q{/dev/fd}, q{/proc/self/fd}) {
        next unless opendir(my $fds, $fd_root);
        @close = grep { /\A[0-9]+\z/ && $_ > 2 && !$keep{$_} } readdir($fds);
        closedir($fds) or fail();
        $listed = 1;
        last;
    }
    if (!$listed) {
        my $max = eval { POSIX::sysconf(POSIX::_SC_OPEN_MAX()) };
        fail() unless defined($max) && $max =~ /\A[0-9]+\z/ && $max <= 1_000_000;
        @close = grep { !$keep{$_} } 3 .. $max - 1;
    }
    POSIX::close($_) for @close;
}

sub read_names_bounded {
    my ($dir) = @_;
    chdir($dir) or fail();
    opendir(my $dh, q{.}) or fail();
    my @names;
    my $count = 0;
    while (defined(my $name = readdir($dh))) {
        next if $name eq q{.} || $name eq q{..};
        fail() if ++$count > 100_000;
        push @names, $name;
    }
    closedir($dh) or fail();
    return @names;
}

sub exact_name_present {
    my ($dir, $want) = @_;
    chdir($dir) or fail();
    opendir(my $dh, q{.}) or fail();
    my ($count, $seen) = (0, 0);
    while (defined(my $name = readdir($dh))) {
        next if $name eq q{.} || $name eq q{..};
        fail() if ++$seen > 100_000;
        $count++ if $name eq $want;
    }
    closedir($dh) or fail();
    return $count == 1;
}

sub parse_id {
    my ($raw) = @_;
    fail() unless defined($raw)
      && $raw =~ /\A([0-9]+:[0-9]+)\|([0-9]+:[0-9]+)\z/;
    return ($1, $2);
}

sub open_visible {
    my ($path) = @_;
    sysopen(my $root, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
    my @root_fd = stat($root);
    my @root_path = lstat($path);
    return unless @root_fd && @root_path && S_ISDIR($root_fd[2]) && !S_ISLNK($root_path[2])
      && oid(@root_fd) eq oid(@root_path) && $root_fd[4] == $<
      && ($root_fd[2] & 0777) == 0700;
    chdir($root) or return;
    sysopen(my $parent, q{..}, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
    my @parent_fd = stat($parent);
    return unless @parent_fd && S_ISDIR($parent_fd[2]);
    return ($root, $parent, oid(@parent_fd), oid(@root_fd));
}

sub find_root_in_parent {
    my ($path, $parent_want, $root_want) = @_;
    my $parent_path = dirname($path);
    sysopen(my $parent, $parent_path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
    my @parent_fd = stat($parent);
    my @parent_path = lstat($parent_path);
    return unless @parent_fd && @parent_path && S_ISDIR($parent_fd[2])
      && !S_ISLNK($parent_path[2]) && oid(@parent_fd) eq oid(@parent_path)
      && oid(@parent_fd) eq $parent_want;
    my @names = read_names_bounded($parent);
    for my $name (@names) {
        my @seen = lstat($name);
        next unless @seen && S_ISDIR($seen[2]) && !S_ISLNK($seen[2])
          && oid(@seen) eq $root_want;
        sysopen(my $root, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
        my @opened = stat($root);
        my @again = lstat($name);
        return unless @opened && @again && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
          && oid(@opened) eq $root_want && oid(@again) eq $root_want
          && $opened[4] == $< && ($opened[2] & 0777) == 0700;
        return ($root, $parent, $parent_want, $root_want);
    }
    return;
}

sub locate_exact {
    my ($path, $parent_want, $root_want) = @_;
    my @visible = open_visible($path);
    if (@visible && $visible[2] eq $parent_want && $visible[3] eq $root_want) {
        return (@visible, q{visible});
    }
    my @relocated = find_root_in_parent($path, $parent_want, $root_want);
    return @relocated ? (@relocated, q{relocated}) : ();
}

sub locate_visible_exact {
    my ($path, $parent_want, $root_want) = @_;
    my @visible = open_visible($path);
    return unless @visible && $visible[2] eq $parent_want && $visible[3] eq $root_want;
    return @visible;
}

sub find_name_by_oid {
    my ($parent, $want) = @_;
    my @names = read_names_bounded($parent);
    my @match;
    for my $name (@names) {
        my @seen = lstat($name);
        push @match, $name if @seen && S_ISDIR($seen[2]) && !S_ISLNK($seen[2])
          && oid(@seen) eq $want;
    }
    fail() if @match > 1;
    return @match ? $match[0] : undef;
}

sub scrub_dir {
    my ($dir, $depth) = @_;
    fail() if $depth > 64;
    my @names = read_names_bounded($dir);
    for my $name (@names) {
        chdir($dir) or fail();
        my @seen = lstat($name);
        next if !@seen && $! == ENOENT;
        fail() unless @seen;
        if (S_ISDIR($seen[2]) && !S_ISLNK($seen[2])) {
            my $child_id = oid(@seen);
            sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
            my @opened = stat($child);
            my @again = lstat($name);
            fail() unless @opened && @again && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
              && oid(@opened) eq $child_id && oid(@again) eq $child_id;
            scrub_dir($child, $depth + 1);
            chdir($dir) or fail();
            my $exact_name = find_name_by_oid($dir, $child_id);
            if (defined($exact_name)) {
                rmdir($exact_name) or fail();
            }
        } else {
            unlink($name) or do { next if $! == ENOENT; fail() };
        }
    }
}

sub safe_leaf {
    my ($leaf) = @_;
    fail() unless defined($leaf) && $leaf =~ /\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/;
    return $leaf;
}

sub write_leaf_bytes {
    my ($root, $leaf, $raw) = @_;
    $leaf = safe_leaf($leaf);
    chdir($root) or fail();
    fail() if exact_name_present($root, $leaf);
    my @prior = lstat($leaf);
    fail() if @prior || $! != ENOENT;
    fail() unless defined($raw) && length($raw) <= 32 * 1024 * 1024;
    sysopen(my $out, $leaf, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0600) or fail();
    my $off = 0;
    while ($off < length($raw)) {
        my $n = syswrite($out, $raw, length($raw) - $off, $off);
        fail() unless defined($n) && $n > 0;
        $off += $n;
    }
    chmod(0600, $out) or fail();
    $out->sync or fail();
    my @opened = stat($out);
    close($out) or fail();
    my @named = lstat($leaf);
    fail() unless @opened && @named && S_ISREG($opened[2]) && !S_ISLNK($named[2])
      && $opened[3] == 1 && oid(@opened) eq oid(@named) && ($opened[2] & 0777) == 0600;
    return oid(@opened) . q{|} . sha256_hex($raw) . q{|} . length($raw);
}

sub write_leaf_from_stdin {
    my ($root, $leaf) = @_;
    my $raw = q{};
    while (1) {
        my $n = sysread(STDIN, my $buf, 65_536);
        fail() unless defined($n);
        last unless $n;
        $raw .= $buf;
        fail() if length($raw) > 32 * 1024 * 1024;
    }
    print write_leaf_bytes($root, $leaf, $raw);
}

sub open_leaf_verified {
    my ($root, $leaf, $record) = @_;
    $leaf = safe_leaf($leaf);
    fail() unless defined($record)
      && $record =~ /\A([0-9]+:[0-9]+)\|([0-9a-f]{64})\|([0-9]+)\z/;
    my ($want_id, $want_sha, $want_len) = ($1, $2, $3);
    fail() if $want_len > 32 * 1024 * 1024;
    chdir($root) or fail();
    fail() unless exact_name_present($root, $leaf);
    sysopen(my $in, $leaf, O_RDONLY | O_NOFOLLOW) or fail();
    my @opened = stat($in);
    my @named = lstat($leaf);
    fail() unless @opened && @named && S_ISREG($opened[2]) && !S_ISLNK($named[2])
      && $opened[3] == 1 && oid(@opened) eq $want_id && oid(@named) eq $want_id
      && ($opened[2] & 0777) == 0600;
    my $raw = q{};
    while (1) {
        my $n = sysread($in, my $buf, 65_536);
        fail() unless defined($n);
        last unless $n;
        $raw .= $buf;
        fail() if length($raw) > 32 * 1024 * 1024;
    }
    my @after = stat($in);
    my @again = lstat($leaf);
    fail() unless exact_name_present($root, $leaf)
      && @after && @again && oid(@after) eq $want_id && oid(@again) eq $want_id
      && length($raw) == $want_len && sha256_hex($raw) eq $want_sha;
    return ($in, $raw);
}

sub read_leaf_verified {
    my ($root, $leaf, $record) = @_;
    my ($in, $raw) = open_leaf_verified($root, $leaf, $record);
    close($in) or fail();
    print $raw;
}

sub canonical_sha256_gitdir_config {
    return "[core]\n\trepositoryformatversion = 1\n\tbare = true\n"
      . "[extensions]\n\tobjectformat = sha256\n";
}

sub gitdir_config_bound {
    my ($gitdir, $object_format, $record) = @_;
    chdir($gitdir) or fail();
    fail() unless $object_format eq q{sha1} || $object_format eq q{sha256};
    my %forbidden = map { $_ => 1 } qw(config.worktree commondir);
    $forbidden{config} = 1 if $object_format eq q{sha1};
    for my $name (read_names_bounded($gitdir)) {
        fail() if $forbidden{$name};
    }
    if ($object_format eq q{sha1}) {
        fail() unless defined($record) && $record eq q{-};
        return;
    }
    my ($config, $raw) = open_leaf_verified($gitdir, q{config}, $record);
    fail() unless $raw eq canonical_sha256_gitdir_config();
    return $config;
}

# git-init needs a local config while it creates the repository skeleton. SHA-1 exact commands do
# not. SHA-256 requires extensions.objectFormat in local config, so replace init output with one
# canonical 0600 leaf containing only repository format/bare/object-format. No include, URL,
# transport or credential key is possible. A completed pathname replacement is checked immediately
# before exec. Git then reopens the pathname itself; post-proof same-UID mutation therefore remains
# an explicit trusted-tool/host boundary until the executor provides OS-level isolation.
sub seal_gitdir_config {
    my ($gitdir, $object_format) = @_;
    fail() unless $object_format eq q{sha1} || $object_format eq q{sha256};
    chdir($gitdir) or fail();
    fail() unless exact_name_present($gitdir, q{config});
    sysopen(my $config, q{config}, O_RDONLY | O_NOFOLLOW) or fail();
    my @opened = stat($config);
    my @named = lstat(q{config});
    fail() unless @opened && @named && S_ISREG($opened[2]) && !S_ISLNK($named[2])
      && $opened[3] == 1 && $opened[4] == $< && oid(@opened) eq oid(@named);
    close($config) or fail();
    my @again = lstat(q{config});
    fail() unless @again && oid(@again) eq oid(@named);
    unlink(q{config}) or fail();
    if ($object_format eq q{sha256}) {
        my $record = write_leaf_bytes(
          $gitdir, q{config}, canonical_sha256_gitdir_config());
        my ($config) = gitdir_config_bound($gitdir, $object_format, $record);
        close($config) or fail();
        print $record;
    } else {
        gitdir_config_bound($gitdir, $object_format, q{-});
        print q{-};
    }
}

# Execute a command without exposing redirect pathnames to the child. Both streams are drained
# through pipes with hard bounds, then committed as O_EXCL leaves below the descriptor-pinned
# private root. The returned records bind inode + digest + length for later reads.
sub capture_exec_unbounded {
    my ($env, $cwd, $keep, @command) = @_;
    fail() unless @command;
    pipe(my $stdout_r, my $stdout_w) or fail();
    pipe(my $stderr_r, my $stderr_w) or fail();
    my $pid = fork();
    fail() unless defined($pid);
    if ($pid == 0) {
        close($stdout_r) or exit 127;
        close($stderr_r) or exit 127;
        open(STDOUT, q{>&}, $stdout_w) or exit 127;
        open(STDERR, q{>&}, $stderr_w) or exit 127;
        close($stdout_w) or exit 127;
        close($stderr_w) or exit 127;
        if (defined($cwd)) {
            chdir($cwd) or exit 127;
        }
        %ENV = %$env if defined($env);
        for my $fh (@{$keep // []}) {
            fcntl($fh, F_SETFD, 0) or exit 127;
        }
        close_fds_except(@{$keep // []});
        exec { $command[0] } @command or exit 127;
    }
    close($stdout_w) or fail();
    close($stderr_w) or fail();
    my $selector = IO::Select->new($stdout_r, $stderr_r);
    my %target = (fileno($stdout_r) => \my $stdout, fileno($stderr_r) => \my $stderr);
    $stdout = q{};
    $stderr = q{};
    while ($selector->count) {
        for my $fh ($selector->can_read) {
            my $n = sysread($fh, my $buf, 65_536);
            if (!defined($n)) {
                kill q{KILL}, $pid;
                waitpid($pid, 0);
                fail();
            }
            if ($n == 0) {
                $selector->remove($fh);
                close($fh) or fail();
                next;
            }
            ${$target{fileno($fh)}} .= $buf;
            if (length($stdout) > 32 * 1024 * 1024 || length($stderr) > 32 * 1024 * 1024) {
                kill q{KILL}, $pid;
                waitpid($pid, 0);
                fail();
            }
        }
    }
    waitpid($pid, 0) == $pid or fail();
    my $status = $?;
    my $rc = ($status & 127) ? 128 + ($status & 127) : ($status >> 8);
    return ($rc, $stdout, $stderr);
}

sub darwin_ps_pids {
    my ($deadline) = @_;
    return unless defined($deadline) && $deadline > time();
    pipe(my $reader, my $writer) or return;
    my $pid = fork();
    return unless defined($pid);
    if ($pid == 0) {
        close($reader) or POSIX::_exit(125);
        open(STDOUT, q{>&}, $writer) or POSIX::_exit(125);
        close($writer) or POSIX::_exit(125);
        open(STDERR, q{>}, q{/dev/null}) or POSIX::_exit(125);
        %ENV = (PATH => q{/usr/bin:/bin}, LANG => q{C}, LC_ALL => q{C});
        close_fds_except();
        exec { q{/bin/ps} } q{/bin/ps}, q{-axo}, q{pid=} or POSIX::_exit(125);
    }
    close($writer) or return;
    my $raw = q{};
    my $reaped = 0;
    my $selector = IO::Select->new($reader);
    while (time() < $deadline) {
        my $left = $deadline - time();
        last unless $left > 0;
        my $slice = $left < 0.05 ? $left : 0.05;
        for my $fh ($selector->can_read($slice)) {
            my $n = sysread($fh, my $buf, 65_536);
            return unless defined($n);
            if ($n == 0) { $selector->remove($fh); last }
            $raw .= $buf;
            return if length($raw) > 32 * 1024 * 1024;
        }
        if (!$reaped) {
            my $found = waitpid($pid, POSIX::WNOHANG());
            return if $found == -1;
            $reaped = 1 if $found == $pid;
        }
        last if $reaped && !$selector->can_read(0);
    }
    if (!$reaped) {
        kill(q{KILL}, $pid);
        waitpid($pid, 0);
        return;
    }
    # The child is reaped, so every byte it wrote is already buffered. Do not wait for EOF: Darwin
    # Perl safe-signal bookkeeping can transiently retain a duplicate writer after caught TERM.
    while ($selector->can_read(0)) {
        my $n = sysread($reader, my $buf, 65_536);
        last unless defined($n) && $n > 0;
        $raw .= $buf;
        return if length($raw) > 32 * 1024 * 1024;
    }
    close($reader);
    return grep { /\A[1-9][0-9]*\z/ } map {
        my $pid = $_; $pid =~ s/^\s+|\s+$//g; $pid
    } split(/\n/, $raw, -1);
}

# Return every live member of the exact POSIX session while its leader is still pinned. Linux
# exposes SID directly in /proc/<pid>/stat. Darwin's ps(1) reports sess=0 for a detached setsid
# session, so the leader (which is itself inside the session) enumerates PIDs and asks getsid(2)
# directly. A child may change PGID freely; only a deliberate setsid(2) leaves this ownership set.
sub owned_session_members {
    my ($sid, $deadline) = @_;
    fail() unless defined($sid) && $sid =~ /\A[1-9][0-9]*\z/
      && defined($deadline) && $deadline > 0;
    if ($ENUMERATION_TEST_DELAY_SECONDS > 0 && !$ENUMERATION_TEST_DELAY_USED++) {
        my $left = $deadline - time();
        return unless $left > $ENUMERATION_TEST_DELAY_SECONDS;
        sleep($ENUMERATION_TEST_DELAY_SECONDS);
    }
    return unless time() < $deadline;
    my %member;
    if ($^O eq q{linux} && -d q{/proc}) {
        opendir(my $proc, q{/proc}) or return;
        my @pid = grep { /\A[1-9][0-9]*\z/ } readdir($proc);
        closedir($proc) or return;
        for my $pid (@pid) {
            return unless time() < $deadline;
            next unless open(my $stat, q{<}, "/proc/$pid/stat");
            local $/;
            my $raw = <$stat> // q{};
            close($stat) or next;
            # comm is parenthesized and may itself contain spaces or ')'; greedily consume it and
            # then parse state, ppid, pgrp and session from the fixed fields that follow.
            my ($found_sid) = $raw =~ /\A[0-9]+ \(.*\) [A-Za-z] [0-9]+ [0-9]+ ([0-9]+) /s;
            $member{$pid} = 1 if defined($found_sid) && $found_sid == $sid;
        }
    } elsif ($^O eq q{darwin}) {
        my @pid = darwin_ps_pids($deadline);
        return unless @pid;
        for my $pid (@pid) {
            return unless time() < $deadline;
            local $! = 0;
            # SYS_getsid is 310 in Darwin's stable BSD syscall table. pid 0 is required for the
            # current leader because older Darwin kernels reject a just-execed self PID briefly.
            my $found_sid = syscall(310, $pid == $$ ? 0 : $pid);
            $member{$pid} = 1 if $found_sid >= 0 && $found_sid == $sid;
        }
    } else {
        return unless time() < $deadline;
        my %ps_env = (PATH => q{/usr/bin:/bin}, LANG => q{C}, LC_ALL => q{C});
        my ($rc, $stdout) = capture_exec_unbounded(
          \%ps_env, undef, [], q{/bin/ps}, q{-axo}, q{pid=,sid=});
        return if $rc != 0;
        for my $row (split(/\n/, $stdout, -1)) {
            return unless time() < $deadline;
            my ($pid, $found_sid) = $row =~ /^\s*([0-9]+)\s+([0-9]+)\s*$/;
            $member{$pid} = 1 if defined($found_sid) && $found_sid == $sid;
        }
    }
    return sort { $a <=> $b } keys(%member);
}

sub pid_in_owned_session {
    my ($pid, $sid, $deadline) = @_;
    return 0 unless defined($pid) && $pid =~ /\A[1-9][0-9]*\z/;
    return 0 unless defined($deadline) && time() < $deadline;
    if ($^O eq q{linux} && -d q{/proc}) {
        return 0 unless open(my $stat, q{<}, "/proc/$pid/stat");
        local $/;
        my $raw = <$stat> // q{};
        close($stat) or return 0;
        my ($found_sid) = $raw =~ /\A[0-9]+ \(.*\) [A-Za-z] [0-9]+ [0-9]+ ([0-9]+) /s;
        return defined($found_sid) && $found_sid == $sid;
    }
    if ($^O eq q{darwin}) {
        local $! = 0;
        my $found_sid = syscall(310, $pid == $$ ? 0 : $pid);
        return $found_sid >= 0 && $found_sid == $sid;
    }
    return grep { $_ == $pid } owned_session_members($sid, $deadline);
}

sub quiesce_owned_session {
    my ($sid, $direct, $direct_reaped_ref, $deadline) = @_;
    return 0 unless defined($deadline) && time() < $deadline;
    my $reap_direct = sub {
        return if $$direct_reaped_ref;
        my $found = waitpid($direct, POSIX::WNOHANG());
        $$direct_reaped_ref = 1 if $found == $direct || $found == -1;
    };
    my @member = owned_session_members($sid, $deadline);
    return 0 unless grep { $_ == $sid } @member;

    # TERM every exact same-session PID, not merely the original PGID. Re-check SID immediately
    # before each positive-PID signal; the live leader pins the SID while descendants converge.
    for my $pid (@member) {
        next if $pid == $sid;
        kill(q{TERM}, $pid) if pid_in_owned_session($pid, $sid, $deadline);
    }
    my $left = $deadline - time();
    return 0 unless $left > 0.20;
    sleep(0.20);

    my $stable = 0;
    for (1 .. 200) {
        return 0 unless time() < $deadline;
        $reap_direct->();
        @member = owned_session_members($sid, $deadline);
        return 0 unless grep { $_ == $sid } @member;
        my @other = grep { $_ != $sid } @member;
        for my $pid (@other) {
            kill(q{KILL}, $pid) if pid_in_owned_session($pid, $sid, $deadline);
        }
        $stable = @other ? 0 : $stable + 1;
        return 1 if $stable >= 2;
        $left = $deadline - time();
        return 0 unless $left > 0;
        sleep($left < 0.01 ? $left : 0.01);
    }
    return 0;
}

sub capture_exec_bounded {
    my ($env, $cwd, $keep, $seconds, @command) = @_;
    fail() unless @command && defined($seconds) && $seconds =~ /\A[0-9]+\z/;
    pipe(my $stdout_r, my $stdout_w) or fail();
    pipe(my $stderr_r, my $stderr_w) or fail();
    pipe(my $ready_r, my $ready_w) or fail();
    pipe(my $start_r, my $start_w) or fail();
    pipe(my $status_r, my $status_w) or fail();
    pipe(my $cleanup_request_r, my $cleanup_request_w) or fail();
    pipe(my $cleanup_r, my $cleanup_w) or fail();
    my $leader = fork();
    fail() unless defined($leader);
    if ($leader == 0) {
        close($stdout_r) or POSIX::_exit(125);
        close($stderr_r) or POSIX::_exit(125);
        close($ready_r) or POSIX::_exit(125);
        close($start_w) or POSIX::_exit(125);
        close($status_r) or POSIX::_exit(125);
        close($cleanup_request_w) or POSIX::_exit(125);
        close($cleanup_r) or POSIX::_exit(125);
        my @leader_keep = ($stdout_w, $stderr_w, $ready_w, $start_r, $status_w,
          $cleanup_request_r, $cleanup_w, @{$keep // []});
        push @leader_keep, $cwd if defined($cwd);
        close_fds_except(@leader_keep);
        POSIX::setsid() >= 0 or POSIX::_exit(125);
        my $stopping = 0;
        $SIG{TERM} = $SIG{HUP} = $SIG{INT} = sub { $stopping = 1 };
        syswrite($ready_w, q{1}, 1) == 1 or POSIX::_exit(125);
        close($ready_w) or POSIX::_exit(125);
        my $start = q{};
        my $start_n = sysread($start_r, $start, 1);
        close($start_r) or POSIX::_exit(125);
        POSIX::_exit(125) unless defined($start_n) && $start_n == 1 && $start eq q{1};
        my $command = fork();
        POSIX::_exit(125) unless defined($command);
        if ($command == 0) {
            close($status_w) or POSIX::_exit(125);
            close($cleanup_request_r) or POSIX::_exit(125);
            close($cleanup_w) or POSIX::_exit(125);
            open(STDOUT, q{>&}, $stdout_w) or POSIX::_exit(125);
            open(STDERR, q{>&}, $stderr_w) or POSIX::_exit(125);
            close($stdout_w) or POSIX::_exit(125);
            close($stderr_w) or POSIX::_exit(125);
            $SIG{TERM} = $SIG{INT} = $SIG{HUP} = $SIG{ALRM} = q{DEFAULT};
            if (defined($cwd)) {
                chdir($cwd) or POSIX::_exit(127);
            }
            %ENV = %$env if defined($env);
            for my $fh (@{$keep // []}) {
                fcntl($fh, F_SETFD, 0) or POSIX::_exit(127);
            }
            close_fds_except(@{$keep // []});
            exec { $command[0] } @command or POSIX::_exit(127);
        }
        close($stdout_w) or POSIX::_exit(125);
        close($stderr_w) or POSIX::_exit(125);
        my $direct_reaped = 0;
        while (!$stopping) {
            my $found = waitpid($command, POSIX::WNOHANG());
            if ($found == $command) {
                $direct_reaped = 1;
                my $message = $? . "\n";
                syswrite($status_w, $message, length($message)) == length($message)
                  or POSIX::_exit(125);
                close($status_w) or POSIX::_exit(125);
                last;
            }
            POSIX::_exit(125) if $found == -1;
            sleep(0.01);
        }
        # Some Darwin Perl builds restart a long sleep after a caught signal. Poll so TERM always
        # advances to causal session cleanup within a bounded interval.
        while (!$stopping) { sleep(0.05) }
        # The deadline is parent-authored after command completion/timeout, not independently
        # reconstructed here. Enumeration and ACK therefore share one causal time envelope.
        my $deadline_wire = q{};
        while ($deadline_wire !~ /\n/) {
            my $n = sysread($cleanup_request_r, my $buf, 64);
            POSIX::_exit(125) unless defined($n) && $n > 0;
            $deadline_wire .= $buf;
            POSIX::_exit(125) if length($deadline_wire) > 32;
        }
        close($cleanup_request_r) or POSIX::_exit(125);
        POSIX::_exit(125) unless $deadline_wire =~ /\A([0-9]+\.[0-9]{6})\n\z/;
        my $proof_deadline = 0 + $1;
        my $work_deadline = $proof_deadline - $CLEANUP_ACK_RESERVE_SECONDS;
        my $clean = time() < $work_deadline
          ? quiesce_owned_session($$, $command, \$direct_reaped, $work_deadline) : 0;
        $clean = 0 unless time() < $proof_deadline;
        my $ack = $clean ? q{1} : q{0};
        syswrite($cleanup_w, $ack, 1) == 1 or POSIX::_exit(125);
        close($cleanup_w) or POSIX::_exit(125);
        # The exact live leader remains the SID pin until the parent consumes the cleanup proof.
        while (1) { sleep(3600) }
    }

    close($stdout_w) or fail();
    close($stderr_w) or fail();
    close($ready_w) or fail();
    close($start_r) or fail();
    close($status_w) or fail();
    close($cleanup_request_r) or fail();
    close($cleanup_w) or fail();
    my $deadline = $seconds > 0 ? time() + $seconds : undef;
    my $leader_ready = 0;
    my $terminated = 0;
    my $reap = sub {
        for (1 .. 20) {
            my $found = waitpid($leader, POSIX::WNOHANG());
            return if $found == $leader || $found == -1;
            sleep(0.05);
        }
    };
    my $terminate = sub {
        return if $terminated++;
        my $cleanup_proven = 0;
        if ($leader_ready) {
            my $proof_deadline = time() + $CLEANUP_PROOF_BUDGET_SECONDS;
            my $deadline_wire = sprintf("%.6f\n", $proof_deadline);
            my $request_ok = syswrite(
              $cleanup_request_w, $deadline_wire, length($deadline_wire));
            $request_ok = defined($request_ok) && $request_ok == length($deadline_wire);
            close($cleanup_request_w) or $request_ok = 0;
            kill(q{TERM}, $leader);
            my $cleanup_select = IO::Select->new($cleanup_r);
            my $left = $proof_deadline - time();
            my @cleanup_ready = $left > 0 ? $cleanup_select->can_read($left) : ();
            if ($request_ok && @cleanup_ready) {
                my $ack = q{};
                my $ack_n = sysread($cleanup_r, $ack, 1);
                $cleanup_proven = 1 if defined($ack_n) && $ack_n == 1 && $ack eq q{1};
            }
        } else {
            close($cleanup_request_w);
            kill(q{TERM}, $leader);
        }
        close($cleanup_r);
        if ($leader_ready) {
            kill(q{KILL}, $leader);
            kill(q{KILL}, -$leader);
        } else {
            kill(q{KILL}, $leader);
        }
        $reap->();
        return !$leader_ready || $cleanup_proven;
    };
    my $remaining = sub {
        return undef unless defined($deadline);
        my $left = $deadline - time();
        return $left > 0 ? $left : 0;
    };
    my $wait_for = sub {
        my ($selector) = @_;
        my $left = $remaining->();
        return defined($left) ? $selector->can_read($left) : $selector->can_read();
    };

    my $ready_select = IO::Select->new($ready_r);
    my @ready = $wait_for->($ready_select);
    if (!@ready) {
        close($ready_r);
        close($start_w);
        close($status_r);
        close($stdout_r);
        close($stderr_r);
        $terminate->();
        return (124, q{}, q{});
    }
    my $ready_byte = q{};
    my $ready_n = sysread($ready_r, $ready_byte, 1);
    close($ready_r) or fail();
    if (!defined($ready_n) || $ready_n != 1 || $ready_byte ne q{1}) {
        close($start_w);
        close($status_r);
        close($stdout_r);
        close($stderr_r);
        $terminate->();
        fail();
    }
    $leader_ready = 1;
    syswrite($start_w, q{1}, 1) == 1 or do { $terminate->(); fail() };
    close($start_w) or do { $terminate->(); fail() };

    my ($stdout, $stderr, $status) = (q{}, q{}, q{});
    my ($status_fd, $stdout_fd, $stderr_fd) =
      (fileno($status_r), fileno($stdout_r), fileno($stderr_r));
    my ($status_open, $stdout_open, $stderr_open) = (1, 1, 1);
    my $selector = IO::Select->new($status_r, $stdout_r, $stderr_r);
    my ($timed_out, $capture_failed) = (0, 0);
    while ($status !~ /\n/) {
        if (defined($deadline) && time() >= $deadline) {
            $timed_out = 1;
            last;
        }
        my @readable = $wait_for->($selector);
        if (!@readable) { $timed_out = 1; last }
        for my $fh (@readable) {
            if (defined($deadline) && time() >= $deadline) {
                $timed_out = 1;
                last;
            }
            my $n = sysread($fh, my $buf, 65_536);
            if (!defined($n)) { $capture_failed = 1; last }
            if ($n == 0) {
                $selector->remove($fh);
                my $closed_fd = fileno($fh);
                close($fh);
                $status_open = 0 if $closed_fd == $status_fd;
                $stdout_open = 0 if $closed_fd == $stdout_fd;
                $stderr_open = 0 if $closed_fd == $stderr_fd;
                if ($closed_fd == $status_fd && $status !~ /\n/) {
                    $capture_failed = 1;
                }
                next;
            }
            if (fileno($fh) == $status_fd) {
                $status .= $buf;
                $capture_failed = 1 if length($status) > 32;
            } elsif (fileno($fh) == $stdout_fd) {
                $stdout .= $buf;
                $capture_failed = 1 if length($stdout) > 32 * 1024 * 1024;
            } else {
                $stderr .= $buf;
                $capture_failed = 1 if length($stderr) > 32 * 1024 * 1024;
            }
        }
        last if $capture_failed || $timed_out;
    }
    $capture_failed = 1 unless $terminate->();

    # The direct command has exited (or timed out) and the owned SID is proven leader-only. Drain only bytes
    # already buffered; a child that deliberately daemonized into another session is outside the
    # trusted transport contract and cannot keep this capture waiting on its inherited pipe.
    for my $stream ([$stdout_r, $stdout_fd, \$stdout_open],
      [$stderr_r, $stderr_fd, \$stderr_open]) {
        my ($fh, $fd, $is_open) = @$stream;
        next unless $$is_open;
        my $drain = IO::Select->new($fh);
        # One owned pipe can hold only bounded kernel-buffered data now that the SID is quiescent.
        # Cap read operations as well: a deliberate setsid escape may still write continuously.
        for (1 .. 64) {
            last unless $drain->can_read(0);
            my $n = sysread($fh, my $buf, 65_536);
            last unless defined($n) && $n > 0;
            if ($fd == $stdout_fd) { $stdout .= $buf }
            else { $stderr .= $buf }
            $capture_failed = 1 if length($stdout) > 32 * 1024 * 1024
              || length($stderr) > 32 * 1024 * 1024;
        }
        close($fh);
        $$is_open = 0;
    }
    close($status_r) if $status_open;
    fail() if $capture_failed;
    return (124, $stdout, $stderr) if $timed_out;
    fail() unless $status =~ /\A([0-9]{1,10})\n\z/ && $1 <= 65_535;
    my $raw = $1;
    my $rc = ($raw & 127) ? 128 + ($raw & 127) : ($raw >> 8);
    return ($rc, $stdout, $stderr);
}

sub capture_to_leaves {
    my ($root, $cwd, $timeout, $keep, $stdout_leaf, $stderr_leaf, @command) = @_;
    my $auto = $stdout_leaf eq q{-} && $stderr_leaf eq q{-};
    fail() if ($stdout_leaf eq q{-}) != ($stderr_leaf eq q{-});
    if ($auto) {
        my $token = random_hex();
        $stdout_leaf = "command.$token.out";
        $stderr_leaf = "command.$token.err";
    }
    safe_leaf($stdout_leaf);
    safe_leaf($stderr_leaf);
    fail() if $stdout_leaf eq $stderr_leaf;
    my %child_env = %ENV;
    my ($rc, $stdout, $stderr) = defined($timeout)
      ? capture_exec_bounded(\%child_env, $cwd, $keep, $timeout, @command)
      : capture_exec_unbounded(\%child_env, $cwd, $keep, @command);
    my $stdout_record = write_leaf_bytes($root, $stdout_leaf, $stdout);
    my $stderr_record = write_leaf_bytes($root, $stderr_leaf, $stderr);
    print $auto
      ? join("\t", $rc, $stdout_leaf, $stdout_record, $stderr_leaf, $stderr_record)
      : join("\t", $rc, $stdout_record, $stderr_record);
}

sub read_fd_bounded {
    my ($fh) = @_;
    sysseek($fh, 0, 0) or fail();
    my $raw = q{};
    while (1) {
        my $n = sysread($fh, my $buf, 65_536);
        fail() unless defined($n);
        last unless $n;
        $raw .= $buf;
        fail() if length($raw) > 32 * 1024 * 1024;
    }
    return $raw;
}

sub random_hex {
    sysopen(my $random, q{/dev/urandom}, O_RDONLY) or fail();
    my $raw = q{};
    while (length($raw) < 12) {
        my $n = sysread($random, my $buf, 12 - length($raw));
        fail() unless defined($n) && $n > 0;
        $raw .= $buf;
    }
    close($random) or fail();
    return unpack(q{H*}, $raw);
}

sub make_private_child_dir {
    my ($parent, $fixed, $random_prefix) = @_;
    chdir($parent) or fail();
    for (1 .. 32) {
        my $name = defined($fixed) ? $fixed
          : safe_leaf($random_prefix // q{exact-tree}) . q{.} . random_hex();
        if (!mkdir($name, 0700)) {
            fail() if defined($fixed) || $! != EEXIST;
            next;
        }
        sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
        my @opened = stat($child);
        my @named = lstat($name);
        fail() unless @opened && @named && S_ISDIR($opened[2]) && !S_ISLNK($named[2])
          && oid(@opened) eq oid(@named) && $opened[4] == $<
          && ($opened[2] & 0777) == 0700;
        chdir($child) or fail();
        my $physical = getcwd();
        fail() unless defined($physical) && $physical =~ m{\A/};
        return ($child, $name, $physical, oid(@opened));
    }
    fail();
}

sub pin_directory_path {
    my ($path) = @_;
    sysopen(my $dir, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
    my @opened = stat($dir);
    my @named = lstat($path);
    fail() unless @opened && @named && S_ISDIR($opened[2]) && !S_ISLNK($named[2])
      && oid(@opened) eq oid(@named);
    chdir($dir) or fail();
    my $physical = getcwd();
    fail() unless defined($physical) && $physical =~ m{\A/};
    my @physical = lstat($physical);
    fail() unless @physical && S_ISDIR($physical[2]) && !S_ISLNK($physical[2])
      && oid(@physical) eq oid(@opened);
    push @AUTHORITY_DIR_PINS, [$dir, $physical, oid(@opened)];
    return ($dir, $physical, oid(@opened));
}

sub validate_authority_dir_pins {
    for my $pin (@AUTHORITY_DIR_PINS) {
        my ($dir, $path, $want) = @$pin;
        my @opened = stat($dir);
        my @named = lstat($path);
        fail() unless @opened && @named && S_ISDIR($opened[2]) && !S_ISLNK($named[2])
          && oid(@opened) eq $want && oid(@named) eq $want;
    }
}

sub git_capture {
    my (@args) = @_;
    local %ENV = %ENV;
    for my $name (keys %ENV) {
        delete $ENV{$name} if $name =~ /\AGIT_/;
    }
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    $ENV{GIT_CONFIG_GLOBAL} = q{/dev/null};
    $ENV{GIT_CONFIG_SYSTEM} = q{/dev/null};
    $ENV{GIT_NO_REPLACE_OBJECTS} = 1;
    $ENV{GIT_NO_LAZY_FETCH} = 1;
    $ENV{GIT_OPTIONAL_LOCKS} = 0;
    pipe(my $pipe, my $writer) or fail();
    my $pid = fork();
    fail() unless defined($pid);
    if ($pid == 0) {
        close($pipe) or exit 127;
        open(STDOUT, q{>&}, $writer) or exit 127;
        close($writer) or exit 127;
        open(STDERR, q{>}, q{/dev/null}) or exit 127;
        close_fds_except();
        exec { q{git} } q{git}, @args or exit 127;
    }
    close($writer) or fail();
    my $raw = q{};
    while (1) {
        my $n = sysread($pipe, my $buf, 65_536);
        fail() unless defined($n);
        last unless $n;
        $raw .= $buf;
        fail() if length($raw) > 128 * 1024 * 1024;
    }
    close($pipe) or fail();
    waitpid($pid, 0) == $pid or fail();
    fail() if $? != 0;
    return $raw;
}

sub exact_tree_entries {
    my ($git_dir, $head) = @_;
    my ($git, $git_path, $git_id) = pin_directory_path($git_dir);
    my $raw = git_capture(q{--git-dir=} . $git_path, q{ls-tree}, q{-r}, q{-z},
      q{--full-tree}, $head);
    my @after = stat($git);
    my @named = lstat($git_path);
    fail() unless @after && @named && S_ISDIR($after[2]) && !S_ISLNK($named[2])
      && oid(@after) eq $git_id && oid(@named) eq $git_id;
    my @entry;
    my %seen;
    my $oid_re = length($head) == 40 ? qr/[0-9a-f]{40}/ : qr/[0-9a-f]{64}/;
    for my $row (split(/\0/, $raw, -1)) {
        next if $row eq q{};
        my ($mode, $type, $object, $path) =
          $row =~ /\A([0-7]{6}) (blob|commit) ($oid_re)\t(.+)\z/s;
        fail() unless defined($path) && !$seen{$path}++
          && $path !~ /\0/ && $path !~ m{(?:\A|/)\.\.?(/|\z)};
        fail() unless ($type eq q{blob} && $mode =~ /\A(?:100644|100755|120000)\z/)
          || ($type eq q{commit} && $mode eq q{160000});
        push @entry, { mode => $mode, type => $type, oid => $object, path => $path };
        fail() if @entry > 1_000_000;
    }
    return @entry;
}

sub proof_directory_cache {
    my ($dir) = @_;
    my @opened = stat($dir);
    fail() unless @opened && S_ISDIR($opened[2]);
    my $key = oid(@opened);
    return $PROOF_DIR_CACHE{$key} if exists $PROOF_DIR_CACHE{$key};
    chdir($dir) or fail();
    opendir(my $dh, q{.}) or fail();
    my (%names, $count);
    while (defined(my $name = readdir($dh))) {
        next if $name eq q{.} || $name eq q{..};
        fail() if ++$count > 1_000_000;
        my @named = lstat($name);
        fail() unless @named && !exists($names{$name});
        $names{$name} = stat_identity(@named);
    }
    closedir($dh) or fail();
    my $cache = { dir => $dir, id => $key, names => \%names };
    $PROOF_DIR_CACHE{$key} = $cache;
    return $cache;
}

sub proof_name_identity {
    my ($dir, $name) = @_;
    my $cache = proof_directory_cache($dir);
    return $cache->{names}{$name};
}

sub validate_proof_directory_caches {
    for my $cache (values %PROOF_DIR_CACHE) {
        my $dir = $cache->{dir};
        my @opened = stat($dir);
        fail() unless @opened && S_ISDIR($opened[2]) && oid(@opened) eq $cache->{id};
        chdir($dir) or fail();
        opendir(my $dh, q{.}) or fail();
        my (%now, $count);
        while (defined(my $name = readdir($dh))) {
            next if $name eq q{.} || $name eq q{..};
            fail() if ++$count > 1_000_000;
            my @named = lstat($name);
            fail() unless @named && !exists($now{$name});
            $now{$name} = stat_identity(@named);
        }
        closedir($dh) or fail();
        fail() unless keys(%now) == keys(%{$cache->{names}});
        for my $name (keys %now) {
            fail() unless exists($cache->{names}{$name})
              && $cache->{names}{$name} eq $now{$name};
        }
    }
}

sub open_parent_for_path {
    my ($root, $path) = @_;
    my @part = split(m{/}, $path, -1);
    fail() unless @part && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
    my $leaf = pop @part;
    my $dir = $root;
    chdir($dir) or fail();
    for my $component (@part) {
        my $cached = proof_name_identity($dir, $component);
        return unless defined($cached);
        chdir($dir) or fail();
        my @named = lstat($component);
        return unless @named && stat_identity(@named) eq $cached
          && S_ISDIR($named[2]) && !S_ISLNK($named[2]);
        sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return;
        my @opened = stat($next);
        my @again = lstat($component);
        return unless @opened && @again && stat_identity(@again) eq $cached
          && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
          && oid(@opened) eq oid(@again) && oid(@opened) eq oid(@named);
        proof_directory_cache($next);
        $dir = $next;
        chdir($dir) or fail();
    }
    return ($dir, $leaf);
}

# Resolve an already-validated repository-relative directory while distinguishing a proven
# absence from an unsafe or changing pathname.  Absence is authoritative because every visited
# parent is cached and revalidated after the proof; a symlink, non-directory, or identity change
# remains fail-closed.
sub open_directory_if_present {
    my ($root, $path) = @_;
    my @part = split(m{/}, $path, -1);
    fail() unless @part && !grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
    my $dir = $root;
    chdir($dir) or fail();
    for my $component (@part) {
        my $cached = proof_name_identity($dir, $component);
        return (0) unless defined($cached);
        chdir($dir) or fail();
        my @named = lstat($component);
        fail() unless @named && stat_identity(@named) eq $cached
          && S_ISDIR($named[2]) && !S_ISLNK($named[2]);
        sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
        my @opened = stat($next);
        my @again = lstat($component);
        fail() unless @opened && @again && stat_identity(@again) eq $cached
          && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
          && oid(@opened) eq oid(@again) && oid(@opened) eq oid(@named);
        proof_directory_cache($next);
        $dir = $next;
        chdir($dir) or fail();
    }
    return (1, $dir);
}

sub stat_identity {
    my (@s) = @_;
    return join(q{:}, @s[0, 1, 2, 3, 4, 7, 9, 10]);
}

sub submodule_index_exact {
    my ($sub_path, $expected, $oid_len) = @_;
    my $raw = git_capture(q{-C}, $sub_path, q{ls-files}, q{-s}, q{-z});
    my (%index, %want);
    for my $entry (@$expected) {
        $want{$entry->{path}} = $entry->{mode} . q{|} . $entry->{oid};
    }
    my $oid_re = $oid_len == 40 ? qr/[0-9a-f]{40}/ : qr/[0-9a-f]{64}/;
    for my $row (split(/\0/, $raw, -1)) {
        next if $row eq q{};
        my ($mode, $object, $stage, $path) =
          $row =~ /\A([0-7]{6}) ($oid_re) ([0-3])\t(.+)\z/s;
        return 0 unless defined($path) && $stage eq q{0} && !$index{$path}++
          && exists($want{$path}) && $want{$path} eq "$mode|$object";
    }
    return 0 unless keys(%index) == keys(%want);
    my $flags = git_capture(q{-C}, $sub_path, q{ls-files}, q{-v}, q{-z});
    for my $row (split(/\0/, $flags, -1)) {
        next if $row eq q{};
        return 0 if $row =~ /\A(?:[a-z]|S) /;
    }
    return 1;
}

sub gitlink_matches {
    my ($root, $entry, $depth) = @_;
    return 0 if $depth > 16;
    my @parent = open_parent_for_path($root, $entry->{path});
    return 0 unless @parent;
    my ($parent, $leaf) = @parent;
    chdir($parent) or fail();
    my $leaf_cached = proof_name_identity($parent, $leaf);
    return 0 unless defined($leaf_cached);
    chdir($parent) or fail();
    my @named = lstat($leaf);
    return 0 unless @named && stat_identity(@named) eq $leaf_cached
      && S_ISDIR($named[2]) && !S_ISLNK($named[2]);
    sysopen(my $sub, $leaf, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or return 0;
    my @opened = stat($sub);
    my @again = lstat($leaf);
    return 0 unless @opened && @again && stat_identity(@again) eq $leaf_cached
      && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
      && oid(@opened) eq oid(@again) && oid(@opened) eq oid(@named);
    chdir($sub) or fail();
    my $sub_path = getcwd();
    return 0 unless defined($sub_path) && $sub_path =~ m{\A/};
    my @physical = lstat($sub_path);
    return 0 unless @physical && S_ISDIR($physical[2]) && !S_ISLNK($physical[2])
      && oid(@physical) eq oid(@opened);
    my $sub_cache = proof_directory_cache($sub);
    my $dotgit = $sub_cache->{names}{q{.git}};
    return 0 unless defined($dotgit);
    my $git_dir = git_capture(q{-C}, $sub_path, q{rev-parse}, q{--absolute-git-dir});
    chdir($sub) or fail();
    my @dotgit_after = lstat(q{.git});
    return 0 unless @dotgit_after && stat_identity(@dotgit_after) eq $dotgit;
    $git_dir =~ s/\n\z//;
    return 0 if $git_dir eq q{} || $git_dir !~ m{\A/} || $git_dir =~ /\n/;
    my $live_head = git_capture(q{-C}, $sub_path, q{rev-parse}, q{--verify}, q{HEAD^{commit}});
    $live_head =~ s/\n\z//;
    return 0 unless $live_head eq $entry->{oid};
    my @nested = exact_tree_entries($git_dir, $entry->{oid});
    return 0 unless submodule_index_exact($sub_path, \@nested, length($entry->{oid}));
    my $bits = length($entry->{oid}) == 40 ? 1 : 256;
    for my $nested (@nested) {
        return 0 unless raw_entry_matches($sub, $nested, $bits, $depth + 1);
    }
    my (%tracked, %modes);
    for my $nested (@nested) {
        $tracked{$nested->{path}} = 1;
        $modes{$nested->{path}} = $nested->{mode};
    }
    my @extra;
    my $count = 0;
    untracked_walk($sub, q{}, \%tracked, \%modes, \@extra, \$count, 0, 1);
    return 0 if @extra;
    my @after = stat($sub);
    @physical = lstat($sub_path);
    return @after && @physical && S_ISDIR($after[2]) && !S_ISLNK($physical[2])
      && oid(@after) eq oid(@opened) && oid(@physical) eq oid(@opened);
}

sub raw_entry_matches {
    my ($root, $entry, $bits, $depth) = @_;
    $depth //= 0;
    return gitlink_matches($root, $entry, $depth) if $entry->{type} eq q{commit};
    my @parent = open_parent_for_path($root, $entry->{path});
    return 0 unless @parent;
    my ($dir, $leaf) = @parent;
    chdir($dir) or fail();
    my $leaf_cached = proof_name_identity($dir, $leaf);
    return 0 unless defined($leaf_cached);
    chdir($dir) or fail();
    my @named = lstat($leaf);
    return 0 unless @named && stat_identity(@named) eq $leaf_cached;
    if ($entry->{mode} eq q{120000}) {
        return 0 unless S_ISLNK($named[2]);
        my $before = stat_identity(@named);
        my $target = readlink($leaf);
        return 0 unless defined($target);
        my @again = lstat($leaf);
        return 0 unless @again && stat_identity(@again) eq $leaf_cached
          && S_ISLNK($again[2]) && stat_identity(@again) eq $before;
        my $sha = Digest::SHA->new($bits);
        $sha->add(q{blob } . length($target) . "\0", $target);
        return $sha->hexdigest eq $entry->{oid};
    }
    return 0 unless S_ISREG($named[2]) && !S_ISLNK($named[2]);
    sysopen(my $in, $leaf, O_RDONLY | O_NOFOLLOW) or return 0;
    my @opened = stat($in);
    @named = lstat($leaf);
    return 0 unless @opened && @named && S_ISREG($opened[2]) && !S_ISLNK($named[2])
      && stat_identity(@opened) eq stat_identity(@named);
    # Git's executable bit is the owner-exec bit, not "any execute bit". A live 0645 file must
    # not satisfy a committed 100755 entry merely because group/other execute remains set.
    my $actual_mode = ($opened[2] & 0100) ? q{100755} : q{100644};
    return 0 unless $actual_mode eq $entry->{mode};
    my $sha = Digest::SHA->new($bits);
    $sha->add(q{blob } . $opened[7] . "\0");
    my $read = 0;
    while (1) {
        my $n = sysread($in, my $buf, 65_536);
        return 0 unless defined($n);
        last unless $n;
        $read += $n;
        return 0 if $read > $opened[7];
        $sha->add($buf);
    }
    my @after = stat($in);
    my @again = lstat($leaf);
    close($in) or return 0;
    return 0 unless $read == $opened[7] && @after && @again
      && stat_identity(@again) eq $leaf_cached
      && stat_identity(@after) eq stat_identity(@opened)
      && stat_identity(@again) eq stat_identity(@opened);
    return $sha->hexdigest eq $entry->{oid};
}

sub untracked_walk {
    my ($dir, $prefix, $tracked, $modes, $out, $count, $depth, $ignore_root_git) = @_;
    fail() if $depth > 64;
    my $cache = proof_directory_cache($dir);
    for my $name (keys(%{$cache->{names}})) {
        next if $ignore_root_git && $depth == 0 && $prefix eq q{} && $name eq q{.git};
        fail() if ++$$count > 100_000;
        chdir($dir) or fail();
        my @named = lstat($name);
        fail() unless @named && stat_identity(@named) eq $cache->{names}{$name};
        my $rel = length($prefix) ? "$prefix/$name" : $name;
        if (S_ISDIR($named[2]) && !S_ISLNK($named[2])) {
            next if ($modes->{$rel} // q{}) eq q{160000};
            sysopen(my $child, $name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
            my @opened = stat($child);
            my @again = lstat($name);
            fail() unless @opened && @again && stat_identity(@again) eq $cache->{names}{$name}
              && S_ISDIR($opened[2]) && !S_ISLNK($again[2])
              && oid(@opened) eq oid(@again) && oid(@opened) eq oid(@named);
            proof_directory_cache($child);
            untracked_walk($child, $rel, $tracked, $modes, $out, $count, $depth + 1,
              $ignore_root_git);
        } elsif (!$tracked->{$rel}) {
            push @$out, $rel;
        }
    }
}

sub raw_worktree_proof {
    my ($private_root, $git_dir, $work_tree, $head, $mode, $spec_rel) = @_;
    fail() unless defined($git_dir) && defined($work_tree)
      && defined($head) && $head =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/
      && defined($mode) && $mode =~ /\A(?:clean|paths|untracked)\z/;
    fail() if $mode eq q{untracked} && (!defined($spec_rel)
      || ($spec_rel ne q{agents}
        && $spec_rel !~ m{\Aspecs/[0-9]{3}-[a-z0-9][a-z0-9-]*\z}));
    my ($work, $work_path, $work_id) = pin_directory_path($work_tree);
    my @entry = exact_tree_entries($git_dir, $head);
    my $bits = length($head) == 40 ? 1 : 256;
    if ($mode eq q{clean} || $mode eq q{paths}) {
        my @changed;
        for my $entry (@entry) {
            push @changed, $entry->{path} unless raw_entry_matches($work, $entry, $bits);
        }
        my @after = stat($work);
        my @named = lstat($work_path);
        validate_proof_directory_caches();
        validate_authority_dir_pins();
        fail() unless @after && @named && S_ISDIR($after[2]) && !S_ISLNK($named[2])
          && oid(@after) eq $work_id && oid(@named) eq $work_id;
        if ($mode eq q{paths}) {
            my $out = join(q{}, map { $_ . "\0" } @changed);
            fail() if length($out) > 32 * 1024 * 1024;
            return (0, $out);
        }
        return (@changed ? 1 : 0, q{});
    }
    my (%tracked, %modes);
    for my $entry (@entry) {
        $tracked{$entry->{path}} = 1;
        $modes{$entry->{path}} = $entry->{mode};
    }
    my @out;
    my $count = 0;
    my ($spec_present, $spec_parent) = open_directory_if_present($work, $spec_rel);
    if ($spec_present) {
        untracked_walk($spec_parent, $spec_rel, \%tracked, \%modes, \@out, \$count, 0, 0);
    }
    my @after = stat($work);
    my @named = lstat($work_path);
    validate_proof_directory_caches();
    validate_authority_dir_pins();
    fail() unless @after && @named && S_ISDIR($after[2]) && !S_ISLNK($named[2])
      && oid(@after) eq $work_id && oid(@named) eq $work_id;
    my $output = join(q{}, map { $_ . "\0" } @out);
    fail() if length($output) > 32 * 1024 * 1024;
    return (0, $output);
}

sub clean_git_env {
    my ($extra) = @_;
    my %child = %ENV;
    delete @child{grep { /\AGIT_/ } keys(%child)};
    $child{GIT_CONFIG_NOSYSTEM} = 1;
    $child{GIT_CONFIG_GLOBAL} = q{/dev/null};
    $child{GIT_CONFIG_SYSTEM} = q{/dev/null};
    $child{GIT_CONFIG_COUNT} = 0;
    $child{GIT_NO_REPLACE_OBJECTS} = 1;
    $child{GIT_NO_LAZY_FETCH} = 1;
    $child{GIT_OPTIONAL_LOCKS} = 0;
    @child{keys(%$extra)} = values(%$extra) if defined($extra);
    return %child;
}

sub config_quote {
    my ($raw) = @_;
    fail() unless defined($raw) && length($raw) <= 16 * 1024
      && $raw !~ /[\x00-\x1f\x7f]/;
    $raw =~ s/\\/\\\\/g;
    $raw =~ s/"/\\"/g;
    return qq{"$raw"};
}

# Read `git config --global --no-includes --null --get-regexp ^credential\.` output and emit a
# standalone config containing only explicit credential capabilities.  URL rewriting, proxies,
# hooks, includes and every non-auth setting are structurally impossible in the result.
sub filter_credential_config {
    fail() if @ARGV;
    my $raw = q{};
    while (1) {
        my $n = sysread(STDIN, my $buf, 65_536);
        fail() unless defined($n);
        last unless $n;
        $raw .= $buf;
        fail() if length($raw) > 4 * 1024 * 1024;
    }
    my $out = q{};
    for my $record (split(/\0/, $raw, -1)) {
        next if $record eq q{};
        my ($key, $value) = split(/\n/, $record, 2);
        fail() unless defined($value) && $key =~ /\Acredential\.(.+)\z/i;
        my $tail = $1;
        my ($subsection, $name);
        if ($tail =~ /\A(helper|username|usehttppath|interactive)\z/i) {
            ($subsection, $name) = (undef, lc($1));
        } elsif ($tail =~ /\A(.+)\.(helper|username|usehttppath|interactive)\z/i) {
            ($subsection, $name) = ($1, lc($2));
        } else {
            next;
        }
        fail() if defined($subsection) && (length($subsection) > 4096
          || $subsection =~ /[\x00-\x1f\x7f]/);
        if ($name eq q{usehttppath} || $name eq q{interactive}) {
            fail() unless $value =~ /\A(?:true|false|yes|no|on|off|0|1)\z/i;
            $value = $value =~ /\A(?:true|yes|on|1)\z/i ? q{true} : q{false};
        }
        my $section = defined($subsection)
          ? qq{[credential } . config_quote($subsection) . qq{]\n}
          : qq{[credential]\n};
        $out .= $section . qq{\t$name = } . config_quote($value) . qq{\n};
        fail() if length($out) > 4 * 1024 * 1024;
    }
    print $out;
}

sub install_clean_git_env {
    my ($config, $config_path, $object_format, $objects) = @_;
    fail() unless defined($config_path) && $config_path =~ m{\A/}
      && $config_path !~ /[\x00-\x1f\x7f]/;
    my %clean;
    $clean{PATH} = exists($ENV{PATH}) && length($ENV{PATH})
      ? $ENV{PATH} : q{/usr/bin:/bin};
    for my $name (qw(HOME XDG_CONFIG_HOME LANG SSH_AUTH_SOCK)) {
        $clean{$name} = $ENV{$name} if exists($ENV{$name});
    }
    %ENV = %clean;
    $ENV{LC_ALL} = q{C};
    # Git on macOS does not reliably consume /dev/fd/N as a global config. The exact 0600 leaf is
    # already descriptor-verified under a pinned 0700 parent; keep that FD open while Git reads the
    # verified pathname (the documented same-UID post-proof OS-isolation boundary still applies).
    $ENV{GIT_CONFIG_GLOBAL} = $config_path;
    $ENV{GIT_CONFIG_SYSTEM} = q{/dev/null};
    $ENV{GIT_CONFIG_NOSYSTEM} = 1;
    $ENV{GIT_ATTR_NOSYSTEM} = 1;
    $ENV{GIT_NO_REPLACE_OBJECTS} = 1;
    $ENV{GIT_NO_LAZY_FETCH} = 1;
    $ENV{GIT_OPTIONAL_LOCKS} = 0;
    $ENV{GIT_TERMINAL_PROMPT} = 0;

    if (defined($object_format)) {
        fail() unless $object_format eq q{sha1} || $object_format eq q{sha256};
        fail() unless defined($objects) && $objects =~ m{\A/}
          && $objects !~ /[\x00-\x1f\x7f]/;
        my @objects = lstat($objects);
        fail() unless @objects && S_ISDIR($objects[2]) && !S_ISLNK($objects[2]);
        $ENV{GIT_DIR} = q{.};
        $ENV{GIT_OBJECT_DIRECTORY} = $objects;
        $ENV{GIT_DEFAULT_HASH} = $object_format;
    }
    $ENV{GIT_CONFIG_COUNT} = 0;
}

my $cmd = shift @ARGV;
fail() unless defined($cmd);
if ($cmd eq q{credential-filter}) {
    filter_credential_config();
    exit 0;
}
if ($cmd eq q{fd-exec}) {
    fail() unless @ARGV >= 3;
    my ($keep_raw, $separator, @command) = @ARGV;
    fail() unless $separator eq q{--} && @command;
    my @keep;
    if ($keep_raw ne q{-}) {
        fail() unless $keep_raw =~ /\A[0-9]+(?:,[0-9]+)*\z/;
        my %seen;
        @keep = grep { !$seen{$_}++ } split(/,/, $keep_raw, -1);
        fail() if grep { $_ <= 2 } @keep;
    }
    close_fds_except(@keep);
    exec { $command[0] } @command or POSIX::_exit(125);
}
my $path = shift @ARGV;
fail() unless defined($path);

if ($cmd eq q{id}) {
    fail() if @ARGV;
    my @found = open_visible($path);
    fail() unless @found;
    print "$found[2]|$found[3]";
    exit 0;
}

my $raw_id = shift @ARGV;
my ($parent_want, $root_want) = parse_id($raw_id);
if ($cmd eq q{guard}) {
    fail() if @ARGV;
    my @found = open_visible($path);
    fail() unless @found && $found[2] eq $parent_want && $found[3] eq $root_want;
    exit 0;
}

if ($cmd eq q{guard-leaves}) {
    fail() unless @ARGV == 1;
    my $raw = shift @ARGV;
    my @allowed = $raw eq q{-} ? () : split(/,/, $raw, -1);
    my %allowed;
    for my $leaf (@allowed) {
        $leaf = safe_leaf($leaf);
        fail() if $allowed{$leaf}++;
    }
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my @names = read_names_bounded($found[0]);
    fail() unless @names == @allowed;
    for my $name (@names) {
        fail() unless $allowed{$name};
        chdir($found[0]) or fail();
        sysopen(my $leaf, $name, O_RDONLY | O_NOFOLLOW) or fail();
        my @opened = stat($leaf);
        my @named = lstat($name);
        fail() unless @opened && @named && S_ISREG($opened[2]) && !S_ISLNK($named[2])
          && $opened[3] == 1 && $opened[4] == $< && oid(@opened) eq oid(@named)
          && ($opened[2] & 0777) == 0600;
        close($leaf) or fail();
    }
    exit 0;
}

if ($cmd eq q{write}) {
    fail() unless @ARGV == 1;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    write_leaf_from_stdin($found[0], $ARGV[0]);
    exit 0;
}

if ($cmd eq q{read}) {
    fail() unless @ARGV == 2;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    read_leaf_verified($found[0], $ARGV[0], $ARGV[1]);
    exit 0;
}

if ($cmd eq q{seal-gitdir-config} || $cmd eq q{verify-gitdir-config}) {
    fail() unless @ARGV == ($cmd eq q{seal-gitdir-config} ? 1 : 2);
    my $object_format = shift @ARGV;
    my $record = $cmd eq q{verify-gitdir-config} ? shift(@ARGV) : undef;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    if ($cmd eq q{seal-gitdir-config}) {
        seal_gitdir_config($found[0], $object_format);
    } else {
        my ($config) = gitdir_config_bound($found[0], $object_format, $record);
        if (defined($config)) { close($config) or fail() }
    }
    exit 0;
}

if ($cmd eq q{config-gitdir-exec-clean}) {
    fail() unless @ARGV >= 9;
    my ($leaf, $record, $gitdir_path, $gitdir_raw_id, $object_format,
      $gitdir_config_record, $objects, $separator, @command) = @ARGV;
    fail() unless $separator eq q{--} && @command;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my ($config) = open_leaf_verified($found[0], $leaf, $record);
    sysseek($config, 0, 0) or fail();
    fcntl($config, F_SETFD, 0) or fail();
    my ($gitdir_parent_want, $gitdir_root_want) = parse_id($gitdir_raw_id);
    my @gitdir = locate_visible_exact(
      $gitdir_path, $gitdir_parent_want, $gitdir_root_want);
    fail() unless @gitdir;
    my ($gitdir_config) = gitdir_config_bound(
      $gitdir[0], $object_format, $gitdir_config_record);
    if (defined($gitdir_config)) {
        sysseek($gitdir_config, 0, 0) or fail();
        fcntl($gitdir_config, F_SETFD, 0) or fail();
    }
    # cwd now pins the exact disposable Gitdir inode. Git receives no mutable Gitdir pathname and
    # no local/common selector; SHA-256 retains only its exact canonical object-format config leaf.
    install_clean_git_env($config, "$path/$leaf", $object_format, $objects);
    my @exec_keep = ($config);
    push @exec_keep, $gitdir_config if defined($gitdir_config);
    close_fds_except(@exec_keep);
    exec { $command[0] } @command or fail();
}

if ($cmd eq q{config-exec} || $cmd eq q{config-exec-clean}) {
    fail() unless @ARGV >= 4;
    my ($leaf, $record, $separator, @command) = @ARGV;
    fail() unless $separator eq q{--} && @command;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my ($config) = open_leaf_verified($found[0], $leaf, $record);
    sysseek($config, 0, 0) or fail();
    fcntl($config, F_SETFD, 0) or fail();
    if ($cmd eq q{config-exec-clean}) {
        install_clean_git_env($config, "$path/$leaf", undef, undef);
    } else {
        for my $name (keys %ENV) {
            delete $ENV{$name} if $name =~ /\AGIT_CONFIG_(?:KEY|VALUE)_[0-9]+\z/;
        }
        delete @ENV{qw(GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL
          GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT)};
    }
    if ($cmd eq q{config-exec}) {
        fail() unless "$path/$leaf" =~ m{\A/} && "$path/$leaf" !~ /[\x00-\x1f\x7f]/;
        $ENV{GIT_CONFIG_GLOBAL} = "$path/$leaf";
        $ENV{GIT_CONFIG_SYSTEM} = q{/dev/null};
        $ENV{GIT_CONFIG_NOSYSTEM} = 1;
        $ENV{GIT_CONFIG_COUNT} = 0;
        $ENV{GIT_ATTR_NOSYSTEM} = 1;
        $ENV{GIT_NO_REPLACE_OBJECTS} = 1;
        $ENV{GIT_NO_LAZY_FETCH} = 1;
        $ENV{GIT_OPTIONAL_LOCKS} = 0;
    }
    close_fds_except($config);
    exec { $command[0] } @command or fail();
}

if ($cmd eq q{make-dir}) {
    fail() unless @ARGV == 1;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my (undef, undef, undef, $child_id) =
      make_private_child_dir($found[0], safe_leaf($ARGV[0]), undef);
    print "$root_want|$child_id";
    exit 0;
}

if ($cmd eq q{make-random-dir}) {
    fail() unless @ARGV == 1 && length($ARGV[0]) <= 80;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my (undef, $name, undef, $child_id) =
      make_private_child_dir($found[0], undef, safe_leaf($ARGV[0]));
    print "$name\t$root_want|$child_id";
    exit 0;
}

if ($cmd eq q{run} || $cmd eq q{run-bounded} || $cmd eq q{run-bounded-fd8}
    || $cmd eq q{run-bounded-test-delay}) {
    my $bounded = $cmd ne q{run};
    my $minimum = $cmd eq q{run-bounded-test-delay} ? 6 : $bounded ? 5 : 4;
    fail() unless @ARGV >= $minimum;
    my $timeout = $bounded ? shift(@ARGV) : undef;
    fail() if defined($timeout) && $timeout !~ /\A[0-9]+\z/;
    if ($cmd eq q{run-bounded-test-delay}) {
        my $delay_ms = shift(@ARGV);
        fail() unless defined($delay_ms) && $delay_ms =~ /\A[1-9][0-9]{0,4}\z/
          && $delay_ms <= 10_000;
        $ENUMERATION_TEST_DELAY_SECONDS = $delay_ms / 1000;
    }
    my ($stdout_leaf, $stderr_leaf, $separator, @command) = @ARGV;
    fail() unless $separator eq q{--} && @command;
    sysopen(my $caller_cwd, q{.}, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fail();
    my @caller_cwd = stat($caller_cwd);
    fail() unless @caller_cwd && S_ISDIR($caller_cwd[2]);
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my @keep;
    if ($cmd eq q{run-bounded-fd8}) {
        open(my $fd8, q{<&=8}) or fail();
        fail() unless fileno($fd8) == 8;
        push @keep, $fd8;
    }
    capture_to_leaves($found[0], $caller_cwd, $timeout, \@keep,
      $stdout_leaf, $stderr_leaf, @command);
    exit 0;
}

if ($cmd eq q{worktree-proof}) {
    fail() unless @ARGV == 4 || @ARGV == 5;
    my ($git_dir, $work_tree, $head, $mode, $spec_rel) = @ARGV;
    my @found = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @found;
    my ($proof_rc, $proof_output) =
      raw_worktree_proof($found[0], $git_dir, $work_tree, $head, $mode, $spec_rel);
    my @still = locate_visible_exact($path, $parent_want, $root_want);
    fail() unless @still;
    print $proof_output;
    exit $proof_rc;
}

fail() unless $cmd eq q{cleanup};
fail() if @ARGV;
my @found = locate_exact($path, $parent_want, $root_want);
fail() unless @found;
my ($root, $parent) = @found[0, 1];
my $was_relocated = $found[4] eq q{relocated};
scrub_dir($root, 0);
my @still_visible = open_visible($path);
$was_relocated = 1 unless @still_visible && $still_visible[2] eq $parent_want
  && $still_visible[3] eq $root_want;
my $name = find_name_by_oid($parent, $root_want);
if (defined($name)) {
    rmdir($name) or fail();
}
exit($was_relocated ? 2 : 0);
