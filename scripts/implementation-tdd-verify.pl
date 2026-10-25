#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha1_hex sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Errno qw(ENOENT);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISLNK S_ISREG SEEK_SET);
use File::Basename qw(dirname);
use File::Temp qw(tempfile);

# Pure verifier for architecture-evidence-v1 implementation candidates.  The state writer owns
# mutation and audit append; this program only pins repository bytes, derives the prospective
# base->index delta, validates the TDD chain and returns a canonical binding record.

my $MAX_FILE       = 16 * 1024 * 1024;
my $MAX_SET        = 64 * 1024 * 1024;
my $MAX_GIT_OUTPUT = 128 * 1024 * 1024;
my $MAX_GENERATION = 2147483647;
my $MAX_PATHS      = 100_000;

my $DOMAIN = "HARNESS-IMPLEMENTATION-ROOT-V1\n";
my $TDD_DOMAIN = "HARNESS-TDD-CANDIDATE-V1\n";
my $MODERN_HEADER = encode(q{UTF-8},
  "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n"
  . "| ts (UTC) | event | detail |\n|---|---|---|\n");
my $LEGACY_HEADER =
  "# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";

my $OID_RE     = qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my $ROOT_RE    = qr/[0-9a-f]{64}/;
my $ATTEMPT_RE = qr/[0-9a-f]{64}/;
my $ACTOR_RE   = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $TEST_RE    = qr/T-[A-Z0-9][A-Z0-9-]{1,63}/;
my $UINT_RE    = qr/(?:0|[1-9][0-9]*)/;

my $SCRIPT_DIR = abs_path(dirname(__FILE__));
my (@PINS, @ABS_PINS, @DIR_PINS, @ABSENCE_PINS);
my $INTERNAL_GIT_CONTEXT = delete $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1};
my ($AUTH_ROOT, $AUTH_INDEX);

sub fatal {
  print STDERR "implementation-tdd-verify: FATAL: $_[0]\n";
  exit 2;
}

sub inode_id { return $_[0][0] . q{:} . $_[0][1] }

sub valid_uint {
  my ($value) = @_;
  return 0 unless defined($value) && $value =~ /\A$UINT_RE\z/;
  return 0 if length($value) > 10 || $value > $MAX_GENERATION;
  return 1;
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
  my $raw = read_fd($fh, $MAX_FILE, "trusted producer $label");
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

sub tdd_producer_identity {
  my ($root, $base, $bootstrap) = @_;
  my (%base_raw, $present); $present = 0;
  for my $name (qw(tdd-receipt-v1.pl implementation-tdd-verify.pl)) {
    my $raw = base_producer_bytes($root, $base, "scripts/$name");
    $base_raw{$name} = $raw;
    $present++ if defined($raw);
  }
  fatal('base producer set is partial') if $present != 0 && $present != 2;
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

sub root_abs {
  my ($root) = @_;
  fatal('empty repo root') unless defined($root) && length($root);
  my @named = lstat($root);
  fatal('repo root must be a real directory')
    unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
  my $abs = abs_path($root);
  fatal('repo root unavailable') unless defined($abs);
  my @canonical = lstat($abs);
  fatal('repo root identity changed')
    unless @canonical && !S_ISLNK($canonical[2]) && S_ISDIR($canonical[2])
      && inode_id(\@canonical) eq inode_id(\@named);
  sysopen(my $fh, $abs, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('repo root pin failed');
  my @opened = stat($fh);
  fatal('repo root pin identity changed')
    unless @opened && inode_id(\@opened) eq inode_id(\@canonical);
  $AUTH_ROOT = { path => $abs, fh => $fh, id => inode_id(\@opened) };
  return $abs;
}

sub safe_rel_bytes {
  my ($raw, $label) = @_;
  fatal("empty repo-relative path: $label") unless defined($raw) && length($raw);
  fatal("unsafe repo-relative path: $label") if $raw =~ m{\A/} || $raw =~ /[\x00-\x1f\x7f]/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("repo-relative path is not UTF-8: $label");
  fatal("Unicode control in repo-relative path: $label") if $text =~ /\p{Cc}/;
  my @part = split m{/}, $raw, -1;
  fatal("unsafe repo-relative path segment: $label")
    if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  return ($text, @part);
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
      or fatal("unsafe parent for $label");
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
    my @a = stat($opened->[$i]);
    my @b = stat($held->[$i]);
    fatal("directory chain changed for $label")
      unless @a && @b && inode_id(\@a) eq inode_id(\@b);
  }
  chdir(q{/}) or fatal('cannot leave verification directory chain');
  close($_) or fatal("directory chain close failed for $label") for reverse @$opened;
}

sub close_chain {
  my ($held, $label) = @_;
  chdir(q{/}) or fatal("cannot leave directory chain for $label");
  close($_) or fatal("directory chain close failed for $label") for reverse @$held;
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

sub safe_read_inner {
  my ($root, $rel, $expected_mode, $record) = @_;
  $expected_mode //= 0644;
  my $git_mode = $expected_mode == 0755 ? '100755' : '100644';
  my (undef, @part) = safe_rel_bytes($rel, $rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable for $rel");
  my @named = lstat($leaf);
  fatal("$rel must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$rel mode must be $git_mode") unless ($named[2] & 07777) == $expected_mode;
  fatal("$rel exceeds 16 MiB") if $named[7] > $MAX_FILE;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $rel");
  my @opened = stat($fh);
  fatal("$rel identity changed")
    unless @opened && inode_id(\@opened) eq inode_id(\@named)
      && S_ISREG($opened[2]) && $opened[3] == 1
      && ($opened[2] & 07777) == $expected_mode;
  my $raw = read_fd($fh, $MAX_FILE, $rel);
  my $again = read_fd($fh, $MAX_FILE, $rel);
  fatal("$rel changed during read") unless $again eq $raw;
  my @after = stat($fh);
  my @renamed = lstat($leaf);
  fatal("$rel changed during read")
    unless @after && @renamed && !S_ISLNK($renamed[2])
      && S_ISREG($after[2]) && S_ISREG($renamed[2])
      && $after[3] == 1 && $renamed[3] == 1
      && inode_id(\@after) eq inode_id(\@opened)
      && inode_id(\@renamed) eq inode_id(\@opened)
      && $after[7] == length($raw) && $renamed[7] == length($raw)
      && ($after[2] & 07777) == $expected_mode
      && ($renamed[2] & 07777) == $expected_mode;
  close($fh) or fatal("file close failed: $rel");
  close_chain($hold, $rel);
  push @PINS, {
    root => $root, rel => $rel, size => length($raw), sha => sha256_hex($raw),
    expected_mode => $expected_mode, git_mode => $git_mode,
  } if $record;
  return $raw;
}

sub safe_read {
  my ($root, $rel, $expected_mode) = @_;
  return safe_read_inner($root, $rel, $expected_mode, 1);
}

sub safe_absent_inner {
  my ($root, $rel, $record) = @_;
  my (undef, @part) = safe_rel_bytes($rel, $rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable for $rel");
  my @named = lstat($leaf);
  fatal("deleted delta path still exists in live tree: $rel") if @named;
  fatal("cannot verify live deletion: $rel") unless $! == ENOENT;
  close_chain($hold, $rel);
  push @ABSENCE_PINS, { root => $root, rel => $rel } if $record;
}

sub safe_absent {
  my ($root, $rel) = @_;
  safe_absent_inner($root, $rel, 1);
}

sub safe_symlink_bytes {
  my ($root, $rel) = @_;
  my (undef, @part) = safe_rel_bytes($rel, $rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable for $rel");
  my @named = lstat($leaf);
  fatal("whole-tree symlink path is not a symlink: $rel")
    unless @named && S_ISLNK($named[2]);
  my $raw = readlink($leaf);
  fatal("whole-tree symlink target unreadable: $rel") unless defined($raw);
  fatal("whole-tree symlink target exceeds 16 MiB: $rel") if length($raw) > $MAX_FILE;
  my $again = readlink($leaf);
  my @after = lstat($leaf);
  fatal("whole-tree symlink changed during read: $rel")
    unless defined($again) && $again eq $raw && @after && S_ISLNK($after[2])
      && inode_id(\@after) eq inode_id(\@named);
  close_chain($hold, $rel);
  return $raw;
}

sub pin_absolute_file {
  my ($path, $limit, $label) = @_;
  fatal("$label path unavailable") unless defined($path) && $path =~ m{\A/};
  my @named = lstat($path);
  fatal("$label must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$label exceeds size limit") if $named[7] > $limit;
  sysopen(my $fh, $path, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $label");
  my @opened = stat($fh);
  fatal("$label identity changed")
    unless @opened && inode_id(\@opened) eq inode_id(\@named)
      && S_ISREG($opened[2]) && $opened[3] == 1;
  my $raw = read_fd($fh, $limit, $label);
  fatal("$label changed during read") unless read_fd($fh, $limit, $label) eq $raw;
  push @ABS_PINS, {
    path => $path, label => $label, limit => $limit, fh => $fh,
    opened => [@opened], raw => $raw,
  };
  return $raw;
}

sub directory_exact_inner {
  my ($root, $rel, $expected, $record) = @_;
  my (undef, @part) = safe_rel_bytes($rel, $rel);
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("directory unavailable: $rel");
  opendir(my $dh, q{.}) or fatal("directory unreadable: $rel");
  my @name = sort { use bytes; $a cmp $b }
    grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
  closedir($dh) or fatal("directory close failed: $rel");
  fatal("closed directory path-set mismatch: $rel")
    unless join(q{\0}, @name) eq join(q{\0}, @$expected);
  close_chain($hold, $rel);
  push @DIR_PINS, {
    root => $root, rel => $rel, names => [@name],
  } if $record;
}

sub pin_directory_exact {
  my ($root, $rel, $expected) = @_;
  directory_exact_inner($root, $rel, $expected, 1);
}

sub revalidate_pins {
  fatal('repo root pin absent') unless defined($AUTH_ROOT);
  my @root_opened = stat($AUTH_ROOT->{fh});
  my @root_named = lstat($AUTH_ROOT->{path});
  fatal('repo root identity changed before authorization')
    unless @root_opened && @root_named && !S_ISLNK($root_named[2])
      && S_ISDIR($root_opened[2]) && S_ISDIR($root_named[2])
      && inode_id(\@root_opened) eq $AUTH_ROOT->{id}
      && inode_id(\@root_named) eq $AUTH_ROOT->{id};
  for my $pin (@ABSENCE_PINS) {
    safe_absent_inner($pin->{root}, $pin->{rel}, 0);
  }
  for my $pin (@DIR_PINS) {
    directory_exact_inner($pin->{root}, $pin->{rel}, $pin->{names}, 0);
  }
  for my $pin (@PINS) {
    my $raw = safe_read_inner($pin->{root}, $pin->{rel}, $pin->{expected_mode}, 0);
    fatal("$pin->{rel} changed before authorization")
      unless length($raw) == $pin->{size} && sha256_hex($raw) eq $pin->{sha};
  }
  for my $pin (@ABS_PINS) {
    my @named = lstat($pin->{path});
    my @opened = stat($pin->{fh});
    fatal("$pin->{label} changed before authorization")
      unless @named && @opened && !S_ISLNK($named[2])
        && S_ISREG($named[2]) && S_ISREG($opened[2])
        && $named[3] == 1 && $opened[3] == 1
        && inode_id(\@named) eq inode_id($pin->{opened})
        && inode_id(\@opened) eq inode_id($pin->{opened})
        && $named[7] == length($pin->{raw}) && $opened[7] == length($pin->{raw});
    fatal("$pin->{label} changed before authorization")
      unless read_fd($pin->{fh}, $pin->{limit}, $pin->{label}) eq $pin->{raw};
  }
  fatal('captured index authority absent') unless defined($AUTH_INDEX);
  my $again = index_entries($AUTH_ROOT->{path});
  fatal('index path-set changed before authorization')
    unless keys(%$again) == keys(%$AUTH_INDEX);
  for my $path (keys %$AUTH_INDEX) {
    fatal("index entry changed before authorization: $path")
      unless exists($again->{$path})
        && $again->{$path}{mode} eq $AUTH_INDEX->{$path}{mode}
        && $again->{$path}{oid} eq $AUTH_INDEX->{$path}{oid};
  }
  whole_tree_live_index_parity($AUTH_ROOT->{path}, $AUTH_INDEX);
  @root_opened = stat($AUTH_ROOT->{fh}); @root_named = lstat($AUTH_ROOT->{path});
  fatal('repo root identity changed during final parity pass')
    unless @root_opened && @root_named
      && inode_id(\@root_opened) eq $AUTH_ROOT->{id}
      && inode_id(\@root_named) eq $AUTH_ROOT->{id};
}

sub utf8_text {
  my ($raw, $label) = @_;
  fatal("NUL in $label") if $raw =~ /\x00/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$label is not UTF-8");
  return $text;
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
  $ENV{LC_ALL} = 'C';
  $ENV{LANG} = 'C';
  $ENV{GIT_OPTIONAL_LOCKS} = '0';
  $ENV{GIT_NO_REPLACE_OBJECTS} = '1';
  $ENV{GIT_CONFIG_NOSYSTEM} = '1';
  $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  $ENV{GIT_PAGER} = 'cat';
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
  my $index_leaf = $index;
  $index_leaf =~ s{.*/}{};
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
  # Preserve the writer-minted record only for the trusted helper chain.  Test children receive
  # an explicit environment allowlist and never inherit it.
  $ENV{HARNESS_INTERNAL_GIT_CONTEXT_V1} = $INTERNAL_GIT_CONTEXT;
  my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'context worktree');
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

sub git_capture {
  my ($root, $limit, @args) = @_;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  open(my $fh, '-|', 'git', '-c', 'core.fsmonitor=false',
    '-c', 'core.hooksPath=/dev/null', '-c', 'core.untrackedCache=false',
    '-C', $root, @args) or fatal('git launch failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('git output read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('git output exceeds safety limit') if length($raw) > $limit;
  }
  close($fh) or fatal("git command failed: " . join(q{ }, @args));
  return $raw;
}

sub exact_line {
  my ($raw, $label) = @_;
  fatal("$label output malformed") unless $raw =~ /\A([^\r\n]+)\n\z/;
  return $1;
}

sub cat_blobs {
  my ($root, $oids) = @_;
  my @oid = sort keys %$oids;
  fatal('too many candidate blobs') if @oid > $MAX_PATHS;
  my ($request, $request_path) = tempfile('harness-implementation-cat-file.XXXXXX',
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
    open(STDIN, '<&', $request) or exit 125;
    open(STDOUT, '>&', $write) or exit 125;
    close($write);
    chdir(q{/}) or exit 125;
    exec('git', '-c', 'core.fsmonitor=false', '-c', 'core.hooksPath=/dev/null',
      '-c', 'core.untrackedCache=false', '-C', $root, 'cat-file', '--batch');
    exit 125;
  }
  close($write);
  close($request);
  binmode($read, q{:raw});
  my $buffer = q{};
  my $eof = 0;
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
        fatal('cat-file header exceeds safety limit') if $at > 4096;
        return substr($buffer, 0, $at + 1, q{});
      }
      fatal('cat-file header exceeds safety limit') if length($buffer) > 4096;
      $fill->() or fatal('cat-file response truncated');
    }
  };
  my $take_exact = sub {
    my ($size) = @_;
    while (length($buffer) < $size) {
      $fill->() or fatal('cat-file blob truncated');
      fatal('cat-file buffered output exceeds safety limit')
        if length($buffer) > $MAX_FILE + 65_536;
    }
    return substr($buffer, 0, $size, q{});
  };

  my %blob;
  my $total = 0;
  for my $oid (@oid) {
    my $header = $take_line->();
    $header =~ /\A\Q$oid\E blob (0|[1-9][0-9]*)\n\z/
      or fatal('cat-file response header malformed');
    my $size = $1;
    fatal('candidate blob exceeds 16 MiB') if length($size) > 8 || $size > $MAX_FILE;
    my $raw = $take_exact->($size);
    fatal('cat-file response framing malformed') unless $take_exact->(1) eq "\n";
    $total += $size;
    fatal('candidate/design blob set exceeds 128 MiB') if $total > 2 * $MAX_SET;
    $blob{$oid} = $raw;
  }
  $fill->() unless $eof;
  fatal('cat-file returned extra output') if length($buffer);
  close($read) or fatal('cat-file output close failed');
  waitpid($pid, 0) == $pid or fatal('cat-file wait failed');
  fatal('cat-file process failed') unless $? == 0;
  return \%blob;
}

sub index_entries {
  my ($root) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT, 'ls-files', '--stage', '-z');
  my @record = split /\x00/, $raw, -1;
  fatal('git index listing is not NUL terminated') unless pop(@record) eq q{};
  fatal('too many index paths') if @record > $MAX_PATHS;
  my %entry;
  for my $record (@record) {
    my ($mode, $oid, $stage, $path) =
      $record =~ /\A([0-7]{6}) ($OID_RE) ([0-3])\t(.*)\z/s;
    fatal('git index record malformed') unless defined($path);
    fatal('unmerged index entry is not bindable') unless $stage eq '0';
    safe_rel_bytes($path, 'git index');
    fatal('duplicate git index path') if exists($entry{$path});
    $entry{$path} = { mode => $mode, oid => $oid };
  }
  return \%entry;
}

sub whole_tree_live_index_parity {
  my ($root, $index) = @_;
  my $flags = git_capture($root, $MAX_GIT_OUTPUT, 'ls-files', '-v', '-z');
  for my $record (split /\x00/, $flags, -1) {
    next if $record eq q{};
    fatal('skip-worktree/assume-unchanged index flags prevent whole-tree proof')
      if $record =~ /\A(?:[a-z]|S) /;
  }
  for my $path (sort { use bytes; $a cmp $b } keys %$index) {
    my $mode = $index->{$path}{mode};
    # Gitlinks are commit identities in the pinned index, not byte members of the superproject
    # snapshot.  Unrelated initialized/uninitialized submodule contents are intentionally outside
    # this proof; a gitlink in the candidate delta remains rejected below.
    next if $mode eq '160000';
    fatal("whole-tree proof rejects unsupported mode: $path")
      unless $mode eq '100644' || $mode eq '100755' || $mode eq '120000';
    my $raw = $mode eq '120000'
      ? safe_symlink_bytes($root, $path)
      : safe_read_inner($root, $path, $mode eq '100755' ? 0755 : 0644, 0);
    my $framed = 'blob ' . length($raw) . "\0" . $raw;
    my $computed = length($index->{$path}{oid}) == 40
      ? sha1_hex($framed) : sha256_hex($framed);
    fatal("whole-tree live/index bytes differ: $path")
      unless $computed eq $index->{$path}{oid};
  }
}

sub delta_entries {
  my ($root, $base) = @_;
  my $raw = git_capture($root, $MAX_GIT_OUTPUT,
    'diff-index', '--cached', '--name-status', '-z', '--no-renames', '--no-ext-diff', $base, '--');
  my @field = split /\x00/, $raw, -1;
  fatal('git delta listing is not NUL terminated') unless pop(@field) eq q{};
  fatal('git delta listing malformed') if @field % 2;
  fatal('too many delta paths') if @field / 2 > $MAX_PATHS;
  my %delta;
  while (@field) {
    my $status = shift @field;
    my $path = shift @field;
    fatal('unsupported git delta status') unless $status =~ /\A[AMDT]\z/;
    safe_rel_bytes($path, 'git delta');
    fatal('duplicate git delta path') if exists($delta{$path});
    $delta{$path} = $status;
  }
  return \%delta;
}

sub architecture_manifest {
  my ($root, $spec, $design) = @_;
  my $helper = "$SCRIPT_DIR/architecture-sdd-verify.pl";
  fatal('architecture verifier unavailable') unless defined($SCRIPT_DIR) && -f $helper;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  open(my $fh, '-|', $^X, $helper, 'manifest', $root, $spec)
    or fatal('architecture verifier launch failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('architecture manifest read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('architecture manifest exceeds 64 MiB') if length($raw) > $MAX_SET;
  }
  close($fh) or fatal('current Design-Root is not verifiable');
  fatal('Design-Root argument does not match current design authority')
    unless sha256_hex($raw) eq $design;
  my @line = split /\n/, $raw, -1;
  fatal('architecture manifest must end with one LF') unless pop(@line) eq q{};
  fatal('architecture manifest domain mismatch')
    unless shift(@line) eq 'HARNESS-DESIGN-ROOT-V1';
  my (%row, $prior);
  for my $line (@line) {
    my ($kind, $path, $mode, $size, $sha) = split /\t/, $line, -1;
    fatal('architecture manifest row malformed')
      unless defined($sha) && $kind eq 'F' && $mode eq '100644'
        && $size =~ /\A(?:0|[1-9][0-9]*)\z/ && $sha =~ /\A$ROOT_RE\z/;
    safe_rel_bytes($path, 'architecture manifest');
    fatal('architecture manifest is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $path };
    fatal('architecture manifest path duplicated') if exists($row{$path});
    $row{$path} = { size => $size, sha => $sha };
    $prior = $path;
  }
  return (\%row, $raw);
}

sub architecture_binding {
  my ($root, $spec, $design) = @_;
  my $helper = "$SCRIPT_DIR/architecture-sdd-verify.pl";
  fatal('architecture verifier unavailable') unless defined($SCRIPT_DIR) && -f $helper;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  open(my $fh, '-|', $^X, $helper, 'verify-bound', $root, $spec)
    or fatal('architecture verifier launch failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 4096);
    fatal('architecture binding read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('architecture binding output exceeds safety limit') if length($raw) > 16_384;
  }
  close($fh) or fatal('current architecture review authority is not verifiable');
  $raw =~ /\ADesign-Root: ($ROOT_RE)\nReview-Attempt: ($ATTEMPT_RE)\nReview-Generation: ($UINT_RE)\nReview-Actor: ($ACTOR_RE)\nReview-SHA256: ($ROOT_RE)\nAudit-SHA256: ($ROOT_RE)\n\z/
    or fatal('architecture verifier binding output malformed');
  my ($bound_design, $review_attempt, $review_generation, $review_actor,
    $review_sha, $audit_sha) = ($1, $2, $3, $4, $5, $6);
  fatal('architecture binding Design-Root mismatch') unless $bound_design eq $design;
  fatal('architecture review generation malformed') unless valid_uint($review_generation);
  return ($review_sha, $audit_sha);
}

sub tdd_receipts {
  my ($root, $spec, $attempt, $authority_audit_raw, $base, $bootstrap) = @_;
  my $helper = "$SCRIPT_DIR/tdd-receipt-v1.pl";
  fatal('TDD receipt verifier unavailable') unless defined($SCRIPT_DIR) && -f $helper;
  chdir(q{/}) or fatal('cannot enter filesystem root');
  open(my $fh, '-|', $^X, $helper, 'verify-chain', $root, $spec, $attempt)
    or fatal('TDD receipt verifier launch failed');
  binmode($fh, q{:raw});
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65_536);
    fatal('TDD receipt output read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('TDD receipt output exceeds safety limit') if length($raw) > $MAX_SET;
  }
  close($fh) or fatal('current TDD receipt chain is not verifiable');
  my @line = split /\n/, $raw, -1;
  fatal('TDD receipt output must end with one LF') unless pop(@line) eq q{};
  fatal('TDD receipt output missing Audit-SHA256') unless @line;
  my $audit = pop @line;
  $audit =~ /\AAudit-SHA256: ($ROOT_RE)\z/
    or fatal('TDD receipt Audit-SHA256 malformed');
  fatal('TDD receipt audit bytes differ from implementation authority audit')
    unless $1 eq sha256_hex($authority_audit_raw);
  my $producer = tdd_producer_identity($root, $base, $bootstrap);
  my %receipt;
  for my $line (@line) {
    my @v = ($line =~ /\AReceipt: test=(T-[A-Z0-9][A-Z0-9-]{1,63});phase=(red|green|adjacent);executed=(T-[A-Z0-9][A-Z0-9-]{1,63});run=($ATTEMPT_RE);generation=($UINT_RE);implementation=($ATTEMPT_RE);actor=($ACTOR_RE);root=($ROOT_RE);contract=($ROOT_RE);tree=($OID_RE);test-manifest=($ROOT_RE);executable=($ROOT_RE);argv-template=($ROOT_RE);producer=($ROOT_RE);timeout=120;result=(assertion-failed|assertion-passed|setup-failed|timeout|invalid-output);exit=(0|[1-9][0-9]{0,2}|signal-[1-9][0-9]{0,2}|timeout);signature=($ROOT_RE|none);stdout=($ROOT_RE);stderr=($ROOT_RE);duration-ms=($UINT_RE)\z/);
    fatal('TDD receipt record malformed') unless @v == 20;
    fatal('TDD receipt generation malformed') unless valid_uint($v[4]);
    fatal('TDD receipt duration malformed') unless valid_uint($v[19]);
    fatal('TDD receipt attempt mismatch') unless $v[5] eq $attempt;
    fatal('TDD receipt producer differs from current trusted producer')
      unless $v[13] eq $producer;
    my $key = "$v[0]\0$v[1]";
    fatal('TDD receipt phase duplicated') if exists($receipt{$key});
    $receipt{$key} = {
      test => $v[0], phase => $v[1], executed => $v[2], run => $v[3],
      generation => $v[4], implementation => $v[5], actor => $v[6],
      root => $v[7], contract => $v[8], tree => $v[9], manifest => $v[10],
      executable => $v[11], argv_template => $v[12], producer => $v[13],
      result => $v[14], exit => $v[15], signature => $v[16], stdout => $v[17],
      stderr => $v[18], duration => $v[19],
    };
  }
  return \%receipt;
}

sub parse_design_trace {
  my ($raw, $spec) = @_;
  my $text = utf8_text($raw, "$spec/traceability.tsv");
  my @line = split /\n/, $text, -1;
  fatal('traceability.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('traceability.tsv header mismatch')
    unless shift(@line) eq "requirement\tdecision\ttest_intent\tacceptance";
  my %chain;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('traceability.tsv row malformed') unless @c == 4
      && $c[0] =~ /\A(?:FR|NFR)-[0-9]{3}\z/
      && $c[1] =~ /\AAD-[0-9]{3}\z/
      && $c[2] =~ /\AT-[A-Z0-9][A-Z0-9-]{1,63}\z/
      && $c[3] =~ /\S/ && !grep { /\p{Cc}/ } @c;
    my $key = join("\0", @c[0 .. 2]);
    fatal('traceability.tsv chain duplicated') if exists($chain{$key});
    $chain{$key} = { requirement => $c[0], decision => $c[1], test => $c[2] };
  }
  fatal('traceability.tsv has no chains') unless keys(%chain);
  return \%chain;
}

sub parse_delivery_trace_pre_red {
  my ($raw, $spec, $design_chain) = @_;
  my $text = utf8_text($raw, "$spec/delivery-trace.tsv");
  my @line = split /\n/, $text, -1;
  fatal('delivery-trace.tsv must end with one LF') unless pop(@line) eq q{};
  my $header = join("\t", qw(requirement decision test kind expected_assertion_signature
    expected_failure_signature red_order red_root red_result red_signature green_order green_root
    green_result green_signature adjacent_test adjacent_signature adjacent_result status));
  fatal('delivery-trace.tsv header mismatch') unless shift(@line) eq $header;
  my (%delivery, %test_shape);
  my @contract_row;
  my @row;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('delivery-trace.tsv row malformed') unless @c == 18 && !grep { /\p{Cc}/ } @c;
    my $key = join("\0", @c[0 .. 2]);
    fatal('delivery trace chain absent from design trace') unless exists($design_chain->{$key});
    fatal('delivery trace chain duplicated') if exists($delivery{$key});
    my $kind = $c[3];
    if ($kind eq 'behavioral') {
      fatal('expected assertion signature malformed')
        unless $c[4] =~ /\A$ROOT_RE\z/;
      fatal('expected failure signature malformed')
        unless $c[5] =~ /\A$ROOT_RE\z/ && $c[5] ne $c[4];
      fatal('RED/GREEN order malformed')
        unless valid_uint($c[6]) && valid_uint($c[10])
          && $c[6] > 0 && $c[10] == $c[6] + 1;
      fatal('pre-RED RED content root is not typed')
        unless $c[7] =~ /\A$ROOT_RE\z/ || $c[7] eq 'PENDING:red-root';
      fatal('pre-RED RED result is not typed')
        unless $c[8] =~ /\A(?:assertion-failed|assertion-passed|setup-failed|timeout|invalid-output)\z/
          || $c[8] eq 'PENDING:red-result';
      fatal('pre-RED RED signature is not typed')
        unless $c[9] =~ /\A$ROOT_RE\z/ || $c[9] eq 'PENDING:red-signature';
      fatal('pre-RED GREEN content root is not typed')
        unless $c[11] =~ /\A$ROOT_RE\z/ || $c[11] eq 'PENDING:green-root';
      fatal('pre-RED GREEN result is not typed')
        unless $c[12] =~ /\A(?:assertion-failed|assertion-passed|setup-failed|timeout|invalid-output)\z/
          || $c[12] eq 'PENDING:green-result';
      fatal('pre-RED GREEN signature is not typed')
        unless $c[13] =~ /\A$ROOT_RE\z/ || $c[13] eq 'PENDING:green-signature';
      fatal('adjacent regression test malformed')
        unless $c[14] =~ /\AT-[A-Z0-9][A-Z0-9-]{1,63}\z/ && $c[14] ne $c[2];
      fatal('adjacent assertion signature malformed') unless $c[15] =~ /\A$ROOT_RE\z/;
      fatal('pre-RED adjacent result is not typed')
        unless $c[16] =~ /\A(?:passed|failed)\z/ || $c[16] eq 'PENDING:adjacent-result';
      fatal('pre-RED delivery status is not typed')
        unless $c[17] =~ /\A(?:green|red|blocked)\z/ || $c[17] eq 'PENDING:status';
      push @contract_row, join("\t", 'B', @c[0, 1, 2, 14, 4, 5, 15]) . "\n";
    } elsif ($kind eq 'non-behavioral') {
      fatal('typed non-executable N/A row malformed')
        unless !(grep { $_ ne 'N/A:non-executable' } @c[4 .. 16])
          && $c[17] eq 'verified-non-behavioral';
      push @contract_row, join("\t", 'N', @c[0 .. 2]) . "\n";
    } else {
      fatal('delivery kind must be behavioral or non-behavioral');
    }
    my $shape = join("\0", @c[3 .. 17]);
    fatal('one test ID has conflicting RED/GREEN chains')
      if exists($test_shape{$c[2]}) && $test_shape{$c[2]} ne $shape;
    $test_shape{$c[2]} = $shape;
    $delivery{$key} = { kind => $kind, test => $c[2] };
    push @row, \@c;
  }
  for my $key (keys %$design_chain) {
    fatal('design trace chain missing from delivery trace') unless exists($delivery{$key});
  }
  fatal('delivery trace contains extra chains')
    unless keys(%delivery) == keys(%$design_chain);
  @contract_row = sort { use bytes; $a cmp $b } @contract_row;
  my $contract = sha256_hex("HARNESS-TDD-EXPECTED-CONTRACT-V1\n" . join(q{}, @contract_row));
  return { delivery => \%delivery, rows => \@row, contract => $contract };
}

sub parse_delivery_trace {
  my ($pre_red, $tdd_root, $receipt) = @_;
  my %delivery = %{$pre_red->{delivery}};
  for my $row (@{$pre_red->{rows}}) {
    my @c = @$row;
    next if $c[3] eq 'non-behavioral';
    fatal('RED content root malformed') unless $c[7] =~ /\A$ROOT_RE\z/;
    fatal('setup/compile/network failure is not a causal RED')
      unless $c[8] eq 'assertion-failed';
    fatal('RED failure signature mismatch') unless $c[9] eq $c[5];
    fatal('GREEN is not bound to the prospective candidate content root')
      unless $c[11] eq $tdd_root;
    fatal('RED and GREEN content roots must differ') if $c[7] eq $c[11];
    fatal('GREEN result must be assertion-passed') unless $c[12] eq 'assertion-passed';
    fatal('GREEN assertion signature mismatch') unless $c[13] eq $c[4];
    fatal('adjacent regression is not green') unless $c[16] eq 'passed';
    fatal('behavioral delivery row is not green') unless $c[17] eq 'green';

    my ($red, $green, $adjacent) = map { $receipt->{"$c[2]\0$_"} }
      qw(red green adjacent);
    fatal('behavioral delivery row lacks runner-produced RED/GREEN/adjacent receipts')
      unless defined($red) && defined($green) && defined($adjacent);
    for my $bound ($red, $green, $adjacent) {
      fatal('runner expected-contract digest differs from final delivery trace')
        unless $bound->{contract} eq $pre_red->{contract};
    }
    fatal('runner RED does not bind primary TestId')
      unless $red->{executed} eq $c[2] && $red->{root} eq $c[7]
        && $red->{result} eq 'assertion-failed'
        && $red->{exit} =~ /\A[1-9][0-9]*\z/ && $red->{exit} <= 255
        && $red->{signature} eq $c[5] && $red->{signature} eq $c[9];
    fatal('runner GREEN does not bind candidate assertion')
      unless $green->{executed} eq $c[2] && $green->{root} eq $tdd_root
        && $green->{result} eq 'assertion-passed' && $green->{exit} eq '0'
        && $green->{signature} eq $c[4] && $green->{signature} eq $c[13];
    fatal('runner adjacent regression does not bind candidate assertion')
      unless $adjacent->{executed} eq $c[14] && $adjacent->{root} eq $tdd_root
        && $adjacent->{result} eq 'assertion-passed' && $adjacent->{exit} eq '0'
        && $adjacent->{signature} eq $c[15];
  }
  my %behavioral_test = map { $delivery{$_}{test} => 1 }
    grep { $delivery{$_}{kind} eq 'behavioral' } keys %delivery;
  for my $key (keys %$receipt) {
    my ($test, $phase) = split /\0/, $key, 2;
    fatal('TDD receipt exists outside closed behavioral delivery test set')
      unless $behavioral_test{$test} && $phase =~ /\A(?:red|green|adjacent)\z/;
  }
  return \%delivery;
}

sub parse_test_manifest_v2 {
  my ($raw, $spec, $index, $eligible, $final) = @_;
  my $text = utf8_text($raw, "$spec/test-manifest-v2.tsv");
  my @line = split /\n/, $text, -1;
  fatal('test-manifest-v2.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('test-manifest-v2.tsv header mismatch')
    unless shift(@line) eq "test\trole\tpath";
  my (%seen, %by_test, %global_support, $prior);
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('test-manifest-v2.tsv row malformed')
      unless @c == 3 && $c[0] =~ /\A$TEST_RE\z/
        && $c[1] =~ /\A(?:test-logic|sut|fixture|transitive)\z/;
    my ($test, $role, $path_text) = @c;
    my $path = encode(q{UTF-8}, $path_text, FB_CROAK);
    safe_rel_bytes($path, 'test manifest');
    my $sort_key = "$test\0$role\0$path";
    fatal('test-manifest-v2.tsv is not raw-byte sorted')
      if defined($prior) && do { use bytes; $prior ge $sort_key };
    fatal('test-manifest-v2.tsv row duplicated') if $seen{$sort_key}++;
    fatal('test manifest path has conflicting roles')
      if exists($by_test{$test}{$path}) && $by_test{$test}{$path} ne $role;
    if ($role eq 'sut') {
      if (exists($index->{$path})) {
        fatal("SUT path has unsupported staged mode: $path")
          unless $index->{$path}{mode} eq '100644' || $index->{$path}{mode} eq '100755';
      }
    } else {
      fatal("stable test input absent from staged tree: $path") unless exists($index->{$path});
      fatal("stable test input has unsupported mode: $path")
        unless $index->{$path}{mode} eq '100644' || $index->{$path}{mode} eq '100755';
      $global_support{$path} = 1;
    }
    $by_test{$test}{$path} = $role;
    $prior = $sort_key;
  }
  fatal('test-manifest-v2.tsv has no rows') unless keys(%by_test);
  for my $test (keys %by_test) {
    fatal("test manifest TestId has no test-logic input: $test")
      unless grep { $_ eq 'test-logic' } values(%{$by_test{$test}});
  }
  return { raw => $raw, by_test => \%by_test, support => \%global_support };
}

sub test_manifest_identity_v2 {
  my ($manifest, $test, $index, $blobs) = @_;
  fatal("receipt TestId absent from test manifest: $test")
    unless exists($manifest->{by_test}{$test});
  my $framed = "HARNESS-TDD-TEST-MANIFEST-V2\nsource\t"
    . sha256_hex($manifest->{raw}) . "\n";
  for my $path (sort { use bytes; $a cmp $b } keys %{$manifest->{by_test}{$test}}) {
    my $role = $manifest->{by_test}{$test}{$path};
    if ($role eq 'sut') {
      $framed .= join("\t", 'input', $role, $path) . "\n";
      next;
    }
    my $entry = $index->{$path};
    my $blob = $blobs->{$entry->{oid}};
    fatal("stable test input blob unavailable: $path") unless defined($blob);
    $framed .= join("\t", 'input', $role, $path, $entry->{mode},
      length($blob), sha256_hex($blob)) . "\n";
  }
  return sha256_hex($framed);
}

sub parse_implementation_map {
  my ($raw, $spec, $delivery, $eligible, $nonbehavioral, $control, $test_manifest) = @_;
  my $text = utf8_text($raw, "$spec/implementation-map.tsv");
  my @line = split /\n/, $text, -1;
  fatal('implementation-map.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('implementation-map.tsv header mismatch')
    unless shift(@line) eq "requirement\tdecision\ttest\tpath";
  my (%tuple, %covered, %chain_count, %behavioral_code, %mapped_sut);
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('implementation-map.tsv row malformed') unless @c == 4;
    my $key = join("\0", @c[0 .. 2]);
    fatal('implementation map chain absent from delivery trace') unless exists($delivery->{$key});
    my $path = encode(q{UTF-8}, $c[3], FB_CROAK);
    safe_rel_bytes($path, 'implementation map');
    fatal('implementation map contains path outside prospective delta')
      unless exists($eligible->{$path});
    my $tuple = "$key\0$path";
    fatal('implementation map tuple duplicated') if $tuple{$tuple}++;
    fatal('typed non-executable N/A maps a behavioral-capable path')
      if $delivery->{$key}{kind} eq 'non-behavioral' && !$nonbehavioral->{$path};
    if ($delivery->{$key}{kind} eq 'behavioral'
        && !$nonbehavioral->{$path} && !$control->{$path}) {
      my $test = $delivery->{$key}{test};
      my $declared_role = $test_manifest->{by_test}{$test}{$path};
      if (defined($declared_role) && $declared_role ne 'sut') {
        $covered{$path} = 1;
        $chain_count{$key}++;
        next;
      }
      fatal("behavioral implementation path is not declared SUT for $test: $path")
        unless defined($declared_role) && $declared_role eq 'sut';
      $behavioral_code{$key} = 1;
      $mapped_sut{$test}{$path} = 1;
    }
    $covered{$path} = 1;
    $chain_count{$key}++;
  }
  for my $key (keys %$delivery) {
    fatal('delivery chain has no implementation path') unless $chain_count{$key};
    fatal('behavioral delivery chain maps no code/test delta')
      if $delivery->{$key}{kind} eq 'behavioral' && !$behavioral_code{$key};
  }
  for my $path (keys %$eligible) {
    fatal("prospective delta path omitted from implementation map: $path")
      unless $covered{$path};
  }
  fatal('implementation map contains extra prospective paths')
    unless keys(%covered) == keys(%$eligible);
  my %behavioral_test = map { $delivery->{$_}{test} => 1 }
    grep { $delivery->{$_}{kind} eq 'behavioral' } keys %$delivery;
  for my $test (keys %behavioral_test) {
    fatal("behavioral TestId absent from test manifest: $test")
      unless exists($test_manifest->{by_test}{$test});
    for my $path (keys %{$test_manifest->{by_test}{$test}}) {
      next unless $test_manifest->{by_test}{$test}{$path} eq 'sut';
      fatal("test manifest SUT is not set-covered by implementation map for $test: $path")
        unless $mapped_sut{$test}{$path};
    }
    for my $path (keys %{$mapped_sut{$test} // {}}) {
      fatal("implementation map has extra SUT outside manifest for $test: $path")
        unless $test_manifest->{by_test}{$test}{$path} eq 'sut';
    }
  }
}

sub delivery_append_receipts {
  my ($raw) = @_;
  eval { decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('audit.md is not UTF-8');
  my $header;
  if (index($raw, $MODERN_HEADER) == 0) { $header = $MODERN_HEADER }
  elsif (index($raw, $LEGACY_HEADER) == 0) { $header = $LEGACY_HEADER }
  else { fatal('audit.md header is not canonical') }
  my $body = substr($raw, length($header));
  my (@receipt, $implementation_active, $current_count) = ();
  while (length($body)) {
    $body =~ s/\A\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
      or fatal('audit.md row is not canonical');
    my ($event, $detail) = ($1, $2);
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=$UINT_RE;scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      $implementation_active = 0
        if grep { $_ eq 'implementation' } split /,/, $1;
      next;
    }
    if ($event eq 'implementation-start') {
      $detail =~ /\Aattempt=$ATTEMPT_RE;generation=$UINT_RE;actor=$ACTOR_RE;subject=$ROOT_RE;capability=implementation-v1;base=$OID_RE\z/
        or fatal('non-canonical implementation-start detail');
      fatal('implementation lifecycle already active') if $implementation_active;
      $implementation_active = 1;
      $current_count = 0;
      next;
    }
    if ($event =~ /delivery-append/) {
      fatal('spoofed delivery-append event') unless $event eq 'delivery-append';
      $detail =~ /\Arevision=([A-Za-z0-9][A-Za-z0-9._-]{0,63});sha256=($ROOT_RE)\z/
        or fatal('delivery-append receipt is malformed');
      push @receipt, [$1, $2];
      $current_count++ if $implementation_active;
    }
  }
  return (\@receipt, $current_count // 0, $implementation_active ? 1 : 0);
}

sub parse_delivery_changelog {
  my ($raw, $spec, $audit_raw) = @_;
  my $text = utf8_text($raw, "$spec/delivery-changelog.tsv");
  my @line = split /\n/, $text, -1;
  fatal('delivery-changelog.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('delivery-changelog.tsv header mismatch')
    unless shift(@line) eq "stage\trevision\tresult\tevidence";
  my ($receipt, $current_count, $implementation_active) =
    delivery_append_receipts($audit_raw);
  my (@row, %seen);
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('delivery-changelog.tsv row malformed')
      unless @c == 4 && $c[0] eq 'stage-3'
        && $c[1] =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
        && length($c[2]) && length($c[3])
        && !grep { /[\t\r\n]|\p{Cc}/ } @c;
    my $sha = sha256_hex(encode(q{UTF-8}, "$line\n", FB_CROAK));
    my $key = "$c[1]\0$sha";
    fatal('delivery-changelog.tsv row duplicated') if $seen{$key}++;
    push @row, [$c[1], $sha];
  }
  fatal('delivery-changelog.tsv must contain at least one Stage-3 row') unless @row;
  fatal('delivery changelog row/receipt count mismatch') unless @row == @$receipt;
  for my $i (0 .. $#row) {
    fatal('delivery changelog rows are not 1:1 ordered audit receipts')
      unless $row[$i][0] eq $receipt->[$i][0] && $row[$i][1] eq $receipt->[$i][1];
  }
  fatal('current implementation attempt lacks a causal delivery-append receipt')
    if $implementation_active && $current_count == 0;
}

sub documentation_nonbehavioral_path {
  my ($path) = @_;
  # N/A is a closed allowlist of narrative-only artifacts. Operational contracts, runbooks,
  # agent canons, provider/runtime instructions and verifier-consumed templates deliberately
  # fall through to TDD even when their storage format is Markdown.
  return 1 if $path eq 'README.md';
  return 1 if $path =~ /\Adocs\/(?:research|audit|roadmap)[A-Za-z0-9._-]*\.md\z/;
  return 1 if $path =~ /\Adocs\/(?:research|audits?|roadmaps?)\/[A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.md\z/;
  return 0;
}

sub parse_audit {
  my ($raw, $attempt, $base, $design, $root) = @_;
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

  my ($generation, $active, $bound) = (0, undef, undef);
  my %used_attempt;
  for my $row (@row) {
    my ($event, $detail) = @$row;
    if ($event eq 'receipt-invalidate') {
      $detail =~ /\Ageneration=($UINT_RE);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
        or fatal('non-canonical receipt-invalidate detail');
      my ($next, $scopes) = ($1, $2);
      fatal('receipt generation malformed') unless valid_uint($next) && $next > 0;
      fatal('receipt generation is not monotonic') unless $next == $generation + 1;
      $generation = $next;
      if (grep { $_ eq 'implementation' } split /,/, $scopes) {
        $active = undef;
        $bound = undef;
      }
      next;
    }
    fatal('spoofed receipt-invalidate event') if $event =~ /receipt-invalidate/;
    if ($event eq 'implementation-start') {
      $detail =~ /\Aattempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE);subject=($ROOT_RE);capability=implementation-v1;base=($OID_RE)\z/
        or fatal('non-canonical implementation-start detail');
      my %start = (attempt => $1, generation => $2, actor => $3, design => $4, base => $5);
      fatal('implementation generation malformed') unless valid_uint($start{generation});
      fatal('implementation-start is not in current generation')
        unless $start{generation} == $generation;
      fatal('duplicate implementation attempt') if $used_attempt{$start{attempt}}++;
      fatal('implementation lifecycle already active') if defined($active);
      $active = \%start;
      $bound = undef;
      next;
    }
    if ($event eq 'implementation-bind') {
      $detail =~ /\Aroot=($ROOT_RE);base=($OID_RE);design=($ROOT_RE);attempt=($ATTEMPT_RE);generation=($UINT_RE);actor=($ACTOR_RE)\z/
        or fatal('non-canonical implementation-bind detail');
      my %terminal = (root => $1, base => $2, design => $3, attempt => $4,
        generation => $5, actor => $6);
      fatal('implementation-bind has no matching start') unless defined($active);
      fatal('duplicate implementation-bind in retained lifecycle') if defined($bound);
      for my $key (qw(base design attempt generation actor)) {
        fatal("implementation-bind $key mismatches start")
          unless $terminal{$key} eq $active->{$key};
      }
      $bound = \%terminal;
      next;
    }
    fatal('spoofed or malformed implementation event')
      if $event =~ /implementation-(?:start|bind)/ || $detail =~ /implementation-(?:start|bind)/;
  }
  fatal('current implementation-start absent') unless defined($active);
  fatal('requested implementation attempt is not current') unless $active->{attempt} eq $attempt;
  fatal('implementation-start base mismatch') unless $active->{base} eq $base;
  fatal('implementation-start Design-Root mismatch') unless $active->{design} eq $design;
  fatal('current implementation-bind root mismatches prospective candidate')
    if defined($bound) && $bound->{root} ne $root;
  return $active;
}

sub build_candidate {
  my ($root, $spec, $base, $design, $attempt, $validate_delivery) = @_;
  fatal('SPEC_DIR grammar mismatch')
    unless $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  fatal('base GitOid malformed') unless $base =~ /\A$OID_RE\z/;
  fatal('Design-Root malformed') unless $design =~ /\A$ROOT_RE\z/;

  my $top = exact_line(git_capture($root, 4096, 'rev-parse', '--show-toplevel'), 'git root');
  my $top_abs = abs_path($top);
  fatal('repo root is not canonical git toplevel') unless defined($top_abs) && $top_abs eq $root;
  my $resolved = exact_line(
    git_capture($root, 4096, 'rev-parse', '--verify', "$base^{commit}"), 'base commit');
  fatal('base GitOid does not name its exact commit object') unless $resolved eq $base;
  fatal('base object is not a commit')
    unless exact_line(git_capture($root, 128, 'cat-file', '-t', $base), 'base type') eq 'commit';

  my $index_path = exact_line(git_capture($root, 16_384, 'rev-parse', '--git-path', 'index'), 'index path');
  $index_path = "$root/$index_path" unless $index_path =~ m{\A/};
  my @index_named = lstat($index_path);
  fatal('git index must be regular, non-symlink, single-link')
    unless @index_named && !S_ISLNK($index_named[2])
      && S_ISREG($index_named[2]) && $index_named[3] == 1;
  my $index_abs = abs_path($index_path);
  fatal('git index unavailable') unless defined($index_abs);
  pin_absolute_file($index_abs, $MAX_GIT_OUTPUT, 'git index');

  my $index = index_entries($root);
  $AUTH_INDEX = { map { $_ => { %{$index->{$_}} } } keys %$index };
  whole_tree_live_index_parity($root, $index);
  my ($design_row) = architecture_manifest($root, $spec, $design);
  my @decision_name = sort { use bytes; $a cmp $b }
    map { m{/([^/]+)\z}; $1 }
    grep { index($_, "$spec/decisions/") == 0 } keys %$design_row;
  fatal('Design-Root contains no decisions') unless @decision_name;
  pin_directory_exact($root, "$spec/decisions", \@decision_name);
  my ($architecture_review_sha, $architecture_audit_sha) =
    architecture_binding($root, $spec, $design);
  my $authority_audit_raw = safe_read($root, "$spec/audit.md");
  fatal('audit bytes changed after architecture authority verification')
    unless sha256_hex($authority_audit_raw) eq $architecture_audit_sha;
  my $delta = delta_entries($root, $base);

  my $review_path = "$spec/reviews/architecture-critical-review.md";
  my $trace_path = "$spec/delivery-trace.tsv";
  my $map_path = "$spec/implementation-map.tsv";
  my $test_manifest_path = "$spec/test-manifest-v2.tsv";
  my $performance_manifest_path = "$spec/performance-manifest-v1.tsv";
  my $changelog_path = "$spec/delivery-changelog.tsv";
  my @quality_evidence_path = (
    "$spec/reviews/critical-code-review.md",
    "$spec/reviews/performance-review.md",
    "$spec/checklists/requirement-evidence.md",
  );
  my %excluded = map { $_ => 1 }
    (keys(%$design_row), "$spec/state.md", "$spec/audit.md", $review_path,
      @quality_evidence_path);
  my %control = map { $_ => 1 }
    ($trace_path, $map_path, $test_manifest_path, $performance_manifest_path,
      $changelog_path);
  my %eligible;
  for my $path (keys %$delta) {
    next if $excluded{$path};
    $eligible{$path} = $delta->{$path};
  }
  fatal('prospective implementation delta is empty') unless keys(%eligible);
  if ($validate_delivery) {
    fatal('delivery-changelog.tsv must be an append-only Stage-3 implementation delta')
      unless exists($eligible{$changelog_path}) && $eligible{$changelog_path} ne 'D';
  }

  # An index-only extra decision cannot hide outside the live architecture verifier's closed set.
  for my $path (keys %$index) {
    if (index($path, "$spec/decisions/") == 0 && !$design_row->{$path}) {
      fatal('index contains a decision outside current Design-Root');
    }
  }

  my %needed_oid;
  for my $path (keys %$design_row, $review_path, $trace_path, $map_path,
      $test_manifest_path, $changelog_path) {
    fatal("required candidate path absent from index: $path") unless exists($index->{$path});
    fatal("required candidate path mode is not 100644: $path")
      unless $index->{$path}{mode} eq '100644';
    $needed_oid{$index->{$path}{oid}} = 1;
  }
  for my $path (keys %eligible) {
    if ($eligible{$path} eq 'D') {
      fatal("deleted delta path still present in index: $path") if exists($index->{$path});
      next;
    }
    fatal("present delta path absent from index: $path") unless exists($index->{$path});
    fatal("unsupported implementation mode for $path")
      unless $index->{$path}{mode} eq '100644' || $index->{$path}{mode} eq '100755';
    $needed_oid{$index->{$path}{oid}} = 1;
  }
  my $blobs = cat_blobs($root, \%needed_oid);
  my $test_manifest_raw = $blobs->{$index->{$test_manifest_path}{oid}};
  my $test_manifest = parse_test_manifest_v2($test_manifest_raw, $spec, $index,
    \%eligible, $validate_delivery);
  my %stable_oid;
  for my $test (keys %{$test_manifest->{by_test}}) {
    for my $path (keys %{$test_manifest->{by_test}{$test}}) {
      next if $test_manifest->{by_test}{$test}{$path} eq 'sut';
      $stable_oid{$index->{$path}{oid}} = 1;
    }
  }
  if (keys %stable_oid) {
    my $stable_blobs = cat_blobs($root, \%stable_oid);
    @{$blobs}{keys %$stable_blobs} = values %$stable_blobs;
  }
  my %nonbehavioral = %control;
  for my $path (keys %eligible) {
    next unless documentation_nonbehavioral_path($path);
    if ($eligible{$path} ne 'D') {
      fatal("non-behavioral documentation/template mode must be 100644: $path")
        unless $index->{$path}{mode} eq '100644';
      utf8_text($blobs->{$index->{$path}{oid}}, "non-behavioral artifact $path");
    }
    $nonbehavioral{$path} = 1;
  }

  # GREEN is a statement about the candidate developers actually executed.  A staged-good index
  # paired with unstaged-different live bytes (or a staged deletion still present live) is not that
  # candidate and therefore cannot become Implementation authority.
  for my $path (keys %eligible) {
    if ($eligible{$path} eq 'D') {
      safe_absent($root, $path);
      next;
    }
    my $mode = $index->{$path}{mode} eq '100755' ? 0755 : 0644;
    my $live = safe_read($root, $path, $mode);
    fatal("live/index implementation bytes differ: $path")
      unless $live eq $blobs->{$index->{$path}{oid}};
  }

  my %design_raw;
  for my $path (keys %$design_row) {
    my $raw = safe_read($root, $path);
    my $blob = $blobs->{$index->{$path}{oid}};
    fatal("live/index design bytes differ: $path") unless defined($blob) && $blob eq $raw;
    fatal("Design-Root row bytes mismatch: $path")
      unless length($raw) == $design_row->{$path}{size}
        && sha256_hex($raw) eq $design_row->{$path}{sha};
    $design_raw{$path} = $raw;
  }
  my $review_raw = safe_read($root, $review_path);
  fatal('architecture review live/index bytes differ')
    unless $blobs->{$index->{$review_path}{oid}} eq $review_raw;
  fatal('architecture review bytes no longer match the Design binding receipt')
    unless sha256_hex($review_raw) eq $architecture_review_sha;
  my $trace_raw = safe_read($root, $trace_path);
  fatal('delivery trace live/index bytes differ')
    unless $blobs->{$index->{$trace_path}{oid}} eq $trace_raw;
  my $map_raw = safe_read($root, $map_path);
  fatal('implementation map live/index bytes differ')
    unless $blobs->{$index->{$map_path}{oid}} eq $map_raw;
  my $test_manifest_live = safe_read($root, $test_manifest_path);
  fatal('test manifest live/index bytes differ')
    unless $blobs->{$index->{$test_manifest_path}{oid}} eq $test_manifest_live;
  my $changelog_raw = safe_read($root, $changelog_path);
  fatal('delivery changelog live/index bytes differ')
    unless $blobs->{$index->{$changelog_path}{oid}} eq $changelog_raw;
  parse_delivery_changelog($changelog_raw, $spec, $authority_audit_raw)
    if $validate_delivery;
  my $design_trace = parse_design_trace($design_raw{"$spec/traceability.tsv"}, $spec);
  my $pre_red_delivery = parse_delivery_trace_pre_red($trace_raw, $spec, $design_trace);

  my ($total, @row) = (0);
  for my $path (sort { use bytes; $a cmp $b } keys %eligible) {
    if ($eligible{$path} eq 'D') {
      push @row, "D\t$path\n";
      next;
    }
    my $raw = $blobs->{$index->{$path}{oid}};
    fatal("candidate blob unavailable: $path") unless defined($raw);
    fatal("candidate blob exceeds 16 MiB: $path") if length($raw) > $MAX_FILE;
    $total += length($raw);
    fatal('implementation root set exceeds 64 MiB') if $total > $MAX_SET;
    push @row, join("\t", 'F', $path, $index->{$path}{mode}, length($raw), sha256_hex($raw)) . "\n";
  }
  my $prefix = $DOMAIN . "base\t$base\n" . "design\t$design\n";
  my $manifest = $prefix . join(q{}, @row);
  fatal('implementation manifest exceeds 64 MiB') if length($manifest) > $MAX_SET;
  my $implementation_root = sha256_hex($manifest);
  my $tdd_manifest = $TDD_DOMAIN . "base\t$base\n" . "design\t$design\n";
  for my $path (sort { use bytes; $a cmp $b } keys %eligible) {
    next if $control{$path};
    if ($eligible{$path} eq 'D') { $tdd_manifest .= "D\t$path\n"; next }
    my $raw = $blobs->{$index->{$path}{oid}};
    $tdd_manifest .= join("\t", 'F', $path, $index->{$path}{mode},
      length($raw), sha256_hex($raw)) . "\n";
  }
  fatal('TDD candidate manifest exceeds 64 MiB') if length($tdd_manifest) > $MAX_SET;
  my $tdd_root = sha256_hex($tdd_manifest);

  if ($validate_delivery) {
    my $receipts = tdd_receipts($root, $spec, $attempt, $authority_audit_raw,
      $base, $design_raw{"$spec/producer-bootstrap-v1.tsv"});
    for my $receipt (values %$receipts) {
      my $expected_manifest = test_manifest_identity_v2($test_manifest,
        $receipt->{executed}, $index, $blobs);
      fatal('runner receipt test-manifest identity differs from staged closure')
        unless $receipt->{manifest} eq $expected_manifest;
    }
    my $delivery = parse_delivery_trace($pre_red_delivery, $tdd_root, $receipts);
    parse_implementation_map($map_raw, $spec, $delivery, \%eligible,
      \%nonbehavioral, \%control, $test_manifest);
  }
  return ($manifest, $implementation_root, $tdd_root, $authority_audit_raw,
    $pre_red_delivery->{contract});
}

sub usage {
  fatal('usage: implementation-tdd-verify.pl <manifest|candidate|content-candidate|content-contract|verify> <repo-root> <SPEC_DIR> <base-GitOid> <Design-Root> <attempt64>');
}

sanitize_environment();
binmode(STDOUT, q{:raw});
binmode(STDERR, q{:raw});
my $command = shift // usage();
@ARGV == 5 or usage();
my ($root_arg, $spec, $base, $design, $attempt) = @ARGV;
fatal('implementation attempt malformed') unless $attempt =~ /\A$ATTEMPT_RE\z/;
my $root = root_abs($root_arg);
configure_internal_git_context($root);
my ($manifest, $implementation_root, $tdd_root, $authority_audit_raw, $expected_contract) =
  build_candidate($root, $spec, $base, $design, $attempt,
    $command ne 'content-candidate' && $command ne 'content-contract');

if ($command eq 'manifest') {
  revalidate_pins();
  print $manifest;
  exit 0;
}
if ($command eq 'candidate') {
  revalidate_pins();
  print "$implementation_root\n";
  exit 0;
}
if ($command eq 'content-candidate') {
  revalidate_pins();
  print "$tdd_root\n";
  exit 0;
}
if ($command eq 'content-contract') {
  revalidate_pins();
  print "Content-Root: $tdd_root\nExpected-Contract-SHA256: $expected_contract\n";
  exit 0;
}
if ($command eq 'verify') {
  my $identity = parse_audit($authority_audit_raw, $attempt, $base, $design, $implementation_root);
  revalidate_pins();
  print "Implementation-Root: $implementation_root\n";
  print "Base: $base\n";
  print "Design-Root: $design\n";
  print "Implementation-Attempt: $identity->{attempt}\n";
  print "Implementation-Generation: $identity->{generation}\n";
  print "Implementation-Actor: $identity->{actor}\n";
  print "Audit-SHA256: " . sha256_hex($authority_audit_raw) . "\n";
  exit 0;
}
usage();
