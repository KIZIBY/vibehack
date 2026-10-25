#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISLNK S_ISREG SEEK_SET);

my $MAX_FILE = 16 * 1024 * 1024;
my $MAX_GENERATION = 2147483647;
my $MAX_WORKLOADS = 64;

my $MODERN_HEADER = encode(q{UTF-8},
  "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n"
  . "| ts (UTC) | event | detail |\n|---|---|---|\n");
my $LEGACY_HEADER =
  "# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";

my $ATTEMPT = qr/[0-9a-f]{64}/;
my $HANDLE = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $SUBJECT = qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my $UINT = qr/(?:0|[1-9][0-9]*)/;

sub fatal {
  print STDERR "receipt-v1: FATAL: $_[0]\n";
  exit 2;
}

sub inode_id {
  my ($stat) = @_;
  return $stat->[0] . q{:} . $stat->[1];
}

sub exact_file_meta {
  my ($before, $after, $mode) = @_;
  return 0 unless @$before && @$after;
  return 0 unless inode_id($before) eq inode_id($after);
  return 0 unless S_ISREG($after->[2]) && $after->[3] == 1;
  return 0 unless ($after->[2] & 07777) == $mode;
  return 0 unless $before->[7] == $after->[7]
    && $before->[9] == $after->[9] && $before->[10] == $after->[10];
  return 1;
}

sub safe_rel_path {
  my ($path, $markdown_only) = @_;
  fatal('empty repo-relative path') unless defined($path) && length($path);
  fatal('unsafe repo-relative path') if $path =~ m{\A/} || $path =~ /[\x00-\x1f\x7f]/;
  fatal('repo-relative path contains Markdown table delimiter') if $path =~ /\|/;
  my $decoded;
  eval { $decoded = decode(q{UTF-8}, $path, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('repo-relative path is not UTF-8');
  fatal('Unicode control in repo-relative path') if $decoded =~ /\p{Cc}/;
  my @part = split m{/}, $path, -1;
  fatal('unsafe repo-relative path segment')
    if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  fatal('artifact must be Markdown') if $markdown_only && $path !~ /\.md\z/;
  return @part;
}

sub open_root {
  my ($root) = @_;
  fatal('empty repo root') unless defined($root) && length($root);
  my @named = lstat($root);
  fatal('repo root must be a real directory')
    unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
  my $abs = abs_path($root);
  fatal('repo root unavailable') unless defined($abs);
  sysopen(my $fh, $root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('repo root open failed');
  my @opened = stat($fh);
  fatal('repo root identity changed')
    unless @opened && S_ISDIR($opened[2])
      && inode_id(\@opened) eq inode_id(\@named);
  return {
    abs => $abs,
    fh => $fh,
    id => inode_id(\@opened),
  };
}

sub check_root {
  my ($root) = @_;
  my @opened = stat($root->{fh});
  my @named = lstat($root->{abs});
  fatal('repo root identity changed')
    unless @opened && @named && !S_ISLNK($named[2])
      && S_ISDIR($opened[2]) && S_ISDIR($named[2])
      && inode_id(\@opened) eq $root->{id}
      && inode_id(\@named) eq $root->{id};
}

sub open_repo_leaf {
  my ($root, $rel, $mode, $limit) = @_;
  my @part = safe_rel_path($rel, 0);
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
        unless @opened && S_ISDIR($opened[2])
          && inode_id(\@opened) eq inode_id(\@named);
      push @hold, $next;
      $dir = $next;
    }
  }
  chdir($dir) or fatal('artifact directory unavailable');
  my $leaf = $part[-1];
  my @named = lstat($leaf);
  fatal('file must be regular, non-symlink, single-link')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal('file mode must be 100644') unless ($named[2] & 07777) == $mode;
  fatal('file exceeds 16 MiB') if $named[7] > $limit;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal('file open failed');
  my @opened = stat($fh);
  fatal('file identity changed before read')
    unless exact_file_meta(\@named, \@opened, $mode) && $opened[7] <= $limit;
  return {
    fh => $fh,
    dir => $dir,
    hold => \@hold,
    leaf => $leaf,
    opened => \@opened,
    mode => $mode,
    limit => $limit,
  };
}

sub read_from_start {
  my ($leaf) = @_;
  defined(sysseek($leaf->{fh}, 0, SEEK_SET)) or fatal('file seek failed');
  my $raw = q{};
  while (1) {
    my $n = sysread($leaf->{fh}, my $buf, 65536);
    fatal('file read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('file exceeds 16 MiB') if length($raw) > $leaf->{limit};
  }
  return $raw;
}

sub check_open_leaf {
  my ($leaf, $length) = @_;
  my @after = stat($leaf->{fh});
  chdir($leaf->{dir}) or fatal('artifact directory unavailable');
  my @again = lstat($leaf->{leaf});
  fatal('file changed during read')
    unless exact_file_meta($leaf->{opened}, \@after, $leaf->{mode})
      && exact_file_meta($leaf->{opened}, \@again, $leaf->{mode})
      && $after[7] == $length && $again[7] == $length;
}

sub read_repo_file {
  my ($root, $rel, $markdown_only) = @_;
  safe_rel_path($rel, $markdown_only);
  my $first = open_repo_leaf($root, $rel, 0644, $MAX_FILE);
  my $raw = read_from_start($first);
  check_open_leaf($first, length($raw));
  my $again = read_from_start($first);
  fatal('file changed between descriptor reads') unless $again eq $raw;
  check_open_leaf($first, length($again));

  # Resolve the canonical repo-relative name again. This detects a renamed or
  # replaced parent directory while the first descriptor tree remained pinned.
  my $second = open_repo_leaf($root, $rel, 0644, $MAX_FILE);
  fatal('file identity changed after read')
    unless inode_id($second->{opened}) eq inode_id($first->{opened});
  my $final = read_from_start($second);
  fatal('file changed after canonical re-resolution') unless $final eq $raw;
  check_open_leaf($second, length($final));
  check_open_leaf($first, length($raw));
  close($second->{fh}) or fatal('file close failed');
  close($first->{fh}) or fatal('file close failed');
  check_root($root);
  return $raw;
}

sub valid_generation {
  my ($value) = @_;
  return 0 unless defined($value) && $value =~ /\A$UINT\z/;
  return 0 if length($value) > 10;
  return 0 if $value > $MAX_GENERATION;
  return 1;
}

sub valid_role {
  my ($role) = @_;
  return defined($role) && $role =~ /\A(?:architecture|critical-code|performance)\z/;
}

sub role_scope {
  my ($role) = @_;
  return 'architecture' if $role eq 'architecture';
  return 'quality';
}

sub role_capability {
  my ($role) = @_;
  return 'architecture-review-v1' if $role eq 'architecture';
  return 'critical-code-review-v1' if $role eq 'critical-code';
  return 'performance-review-v1' if $role eq 'performance';
  fatal('unknown receipt role');
}

sub parse_common {
  my ($role, $detail, $terminal) = @_;
  my @capture;
  if ($terminal eq 'start') {
    @capture = ($detail =~
      /\Aattempt=($ATTEMPT);generation=($UINT);actor=($HANDLE);subject=($SUBJECT);capability=($HANDLE)\z/);
    fatal('non-canonical review-start detail') unless @capture == 5;
  } elsif ($terminal eq 'blocked') {
    @capture = ($detail =~
      /\Aattempt=($ATTEMPT);generation=($UINT);actor=($HANDLE);subject=($SUBJECT);capability=($HANDLE);reason=(unavailable|lost|invalid-output)\z/);
    fatal('non-canonical review-blocked detail') unless @capture == 6;
  } elsif ($terminal eq 'finish') {
    @capture = ($detail =~
      /\Aattempt=($ATTEMPT);generation=($UINT);actor=($HANDLE);subject=($SUBJECT);capability=($HANDLE);artifact=([^;\r\n]+);sha256=([0-9a-f]{64})\z/);
    fatal('non-canonical review-finish detail') unless @capture == 7;
  } else {
    fatal('internal receipt parser error');
  }
  fatal('receipt generation malformed') unless valid_generation($capture[1]);
  fatal('architecture receipt subject must be a Design-Root')
    if $role eq 'architecture' && length($capture[3]) != 64;
  my %value = (
    attempt => $capture[0], generation => $capture[1], actor => $capture[2],
    subject => $capture[3], capability => $capture[4],
  );
  fatal('receipt capability does not match role')
    unless $value{capability} eq role_capability($role);
  $value{reason} = $capture[5] if $terminal eq 'blocked';
  if ($terminal eq 'finish') {
    $value{artifact} = $capture[5];
    $value{sha256} = $capture[6];
    safe_rel_path($value{artifact}, 1);
  }
  return \%value;
}

sub same_start_identity {
  my ($start, $terminal) = @_;
  for my $key (qw(attempt generation actor subject capability)) {
    fatal("review terminal $key mismatch") unless $start->{$key} eq $terminal->{$key};
  }
}

sub parse_scopes {
  my ($detail, $current) = @_;
  $detail =~
    /\Ageneration=($UINT);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
      or fatal('non-canonical receipt-invalidate detail');
  my ($generation, $list) = ($1, $2);
  fatal('receipt generation malformed') unless valid_generation($generation) && $generation > 0;
  fatal('receipt generation is not monotonic') unless $generation == $current + 1;
  my %scope = map { $_ => 1 } split /,/, $list;
  return ($generation, \%scope);
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
    push @row, [$1, $2, $3];
  }
  return \@row;
}

sub parse_audit {
  my ($root, $spec) = @_;
  my $raw = read_repo_file($root, "$spec/audit.md", 1);
  my $rows = audit_rows($raw);
  my $generation = 0;
  my %attempt;
  my @invalidation;

  for my $row (@$rows) {
    my ($event, $detail) = @$row[1, 2];
    if ($event eq 'receipt-invalidate') {
      my ($next, $scope) = parse_scopes($detail, $generation);
      $generation = $next;
      push @invalidation, { generation => $next, scope => $scope };
      next;
    }
    fatal('spoofed receipt-invalidate event') if $event =~ /\Areceipt-invalidate/;

    if ($event =~ /\Areview-(start|blocked|finish):(.+)\z/) {
      my ($kind, $role) = ($1, $2);
      fatal('unknown receipt role') unless valid_role($role);
      my $value = parse_common($role, $detail, $kind);
      my $id = $value->{attempt};
      if ($kind eq 'start') {
        fatal('duplicate receipt attempt') if exists($attempt{$id});
        fatal('review-start is not in current generation')
          unless $value->{generation} == $generation;
        for my $known (values %attempt) {
          fatal('same-role receipt lifecycle already locks current generation')
            if $known->{role} eq $role
              && $known->{status} ne 'blocked'
              && $known->{start}{generation} == $generation;
        }
        $attempt{$id} = {
          role => $role, status => 'open', start => $value,
        };
        next;
      }
      fatal('unmatched receipt terminal') unless exists($attempt{$id});
      my $receipt = $attempt{$id};
      fatal('receipt role mismatch') unless $receipt->{role} eq $role;
      fatal('duplicated receipt terminal') unless $receipt->{status} eq 'open';
      same_start_identity($receipt->{start}, $value);
      fatal('receipt terminal is not in current generation')
        unless $value->{generation} == $generation;
      $receipt->{status} = $kind eq 'finish' ? 'finished' : 'blocked';
      $receipt->{terminal} = $value;
      next;
    }
    if ($event eq 'performance-run-start' || $event eq 'performance-run-finish') {
      my $kind = $event eq 'performance-run-start' ? 'start' : 'finish';
      my @value;
      if ($kind eq 'start') {
        @value = ($detail =~
          /\Aattempt=($ATTEMPT);generation=($UINT);actor=($HANDLE);subject=($SUBJECT);capability=performance-process-v1;workloads=($UINT);manifest=([0-9a-f]{64});producer=([0-9a-f]{64})\z/);
        fatal('non-canonical performance-run-start detail') unless @value == 7;
      } else {
        @value = ($detail =~
          /\Aattempt=($ATTEMPT);generation=($UINT);actor=($HANDLE);subject=($SUBJECT);capability=performance-process-v1;workloads=($UINT);manifest=([0-9a-f]{64});producer=([0-9a-f]{64});raw-samples=([0-9a-f]{64});artifact=([^;\r\n]+);sha256=([0-9a-f]{64})\z/);
        fatal('non-canonical performance-run-finish detail') unless @value == 10;
        safe_rel_path($value[8], 1);
      }
      fatal('performance process workload count must be positive')
        unless $value[4] > 0 && $value[4] <= $MAX_WORKLOADS;
      my $id = $value[0];
      fatal('performance process terminal has no matching review start')
        unless exists($attempt{$id});
      my $receipt = $attempt{$id};
      fatal('performance process receipt role mismatch') unless $receipt->{role} eq 'performance';
      my $start = $receipt->{start};
      for my $pair ([generation => $value[1]], [actor => $value[2]], [subject => $value[3]]) {
        fatal("performance process $pair->[0] mismatch")
          unless $start->{$pair->[0]} eq $pair->[1];
      }
      fatal('performance process terminal is not in current generation')
        unless $value[1] == $generation;
      if ($kind eq 'start') {
        fatal('performance process lifecycle duplicated') unless $receipt->{status} eq 'open';
        $receipt->{status} = 'process-running';
        $receipt->{process} = {
          workloads => $value[4], manifest => $value[5], producer => $value[6],
        };
      } else {
        fatal('performance process finish has no exact start')
          unless $receipt->{status} eq 'process-running';
        for my $pair ([workloads => $value[4]], [manifest => $value[5]], [producer => $value[6]]) {
          fatal("performance process finish $pair->[0] mismatch")
            unless $receipt->{process}{$pair->[0]} eq $pair->[1];
        }
        $receipt->{status} = 'finished-process';
      }
      next;
    }
    fatal('spoofed or malformed performance process event')
      if $event =~ /performance-run-(?:start|finish)/;
    fatal('spoofed or malformed review event') if $event =~ /\Areview-/;
  }
  return {
    generation => $generation,
    attempt => \%attempt,
    invalidation => \@invalidation,
    audit_raw => $raw,
  };
}

sub assert_audit_unchanged {
  my ($root, $spec, $expected) = @_;
  my $again = read_repo_file($root, "$spec/audit.md", 1);
  fatal('audit.md changed during receipt verification') unless $again eq $expected;
}

sub validate_spec_and_artifact {
  my ($spec, $artifact) = @_;
  fatal('SPEC_DIR grammar mismatch')
    unless defined($spec) && $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  safe_rel_path($artifact, 1);
  fatal('receipt artifact path contains a receipt/audit delimiter')
    if $artifact =~ /[;|]/;
  fatal('receipt artifact must belong to SPEC_DIR')
    unless index($artifact, "$spec/") == 0;
  fatal('state/audit cannot be a receipt artifact')
    if $artifact eq "$spec/state.md" || $artifact eq "$spec/audit.md";
}

sub current_finished_receipt {
  my ($parsed, $role, $attempt) = @_;
  fatal('receipt attempt absent') unless exists($parsed->{attempt}{$attempt});
  my $receipt = $parsed->{attempt}{$attempt};
  fatal('receipt role mismatch') unless $receipt->{role} eq $role;
  fatal('receipt attempt is not finished') unless $receipt->{status} eq 'finished';
  my $scope = role_scope($role);
  my $issued = $receipt->{start}{generation};
  for my $invalidation (@{$parsed->{invalidation}}) {
    fatal('receipt was invalidated')
      if $invalidation->{generation} > $issued && $invalidation->{scope}{$scope};
  }
  return $receipt;
}

sub usage {
  fatal('usage: receipt-v1.pl start-detail <repo-root> <SPEC_DIR> <role> <attempt64> <actor> <subject> | blocked-detail <repo-root> <SPEC_DIR> <role> <attempt64> <reason> | finish-detail <repo-root> <SPEC_DIR> <role> <attempt64> <artifact-rel> | verify-finished <repo-root> <SPEC_DIR> <role> <attempt64>');
}

binmode(STDOUT, q{:raw});
binmode(STDERR, q{:raw});
my $command = shift // usage();

if ($command eq 'start-detail') {
  @ARGV == 6 or usage();
  my ($root_arg, $spec, $role, $attempt, $actor, $subject) = @ARGV;
  fatal('SPEC_DIR grammar mismatch')
    unless defined($spec) && $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  fatal('unknown receipt role') unless valid_role($role);
  fatal('receipt attempt malformed') unless $attempt =~ /\A$ATTEMPT\z/;
  fatal('receipt actor malformed') unless $actor =~ /\A$HANDLE\z/;
  fatal('receipt subject malformed') unless $subject =~ /\A$SUBJECT\z/;
  fatal('architecture receipt subject must be a Design-Root')
    if $role eq 'architecture' && length($subject) != 64;
  my $root = open_root($root_arg);
  my $parsed = parse_audit($root, $spec);
  fatal('receipt attempt already exists') if exists($parsed->{attempt}{$attempt});
  for my $known (values %{$parsed->{attempt}}) {
    fatal('same-role receipt lifecycle already locks current generation')
      if $known->{role} eq $role
        && $known->{status} ne 'blocked'
        && $known->{start}{generation} == $parsed->{generation};
  }
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  print join(q{;}, "attempt=$attempt", "generation=$parsed->{generation}",
    "actor=$actor", "subject=$subject", 'capability=' . role_capability($role)), "\n";
  exit 0;
}

if ($command eq 'blocked-detail') {
  @ARGV == 5 or usage();
  my ($root_arg, $spec, $role, $attempt, $reason) = @ARGV;
  fatal('SPEC_DIR grammar mismatch')
    unless defined($spec) && $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  fatal('unknown receipt role') unless valid_role($role);
  fatal('receipt attempt malformed') unless $attempt =~ /\A$ATTEMPT\z/;
  fatal('receipt blocked reason malformed')
    unless $reason =~ /\A(?:unavailable|lost|invalid-output)\z/;
  my $root = open_root($root_arg);
  my $parsed = parse_audit($root, $spec);
  fatal('receipt attempt absent') unless exists($parsed->{attempt}{$attempt});
  my $receipt = $parsed->{attempt}{$attempt};
  fatal('receipt role mismatch') unless $receipt->{role} eq $role;
  fatal('receipt attempt is not open') unless $receipt->{status} eq 'open';
  fatal('open receipt is not in current generation')
    unless $receipt->{start}{generation} == $parsed->{generation};
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  my $start = $receipt->{start};
  print join(q{;}, "attempt=$start->{attempt}", "generation=$start->{generation}",
    "actor=$start->{actor}", "subject=$start->{subject}",
    "capability=$start->{capability}", "reason=$reason"), "\n";
  exit 0;
}

if ($command eq 'finish-detail') {
  @ARGV == 5 or usage();
  my ($root_arg, $spec, $role, $attempt, $artifact) = @ARGV;
  fatal('unknown receipt role') unless valid_role($role);
  fatal('receipt attempt malformed') unless $attempt =~ /\A$ATTEMPT\z/;
  validate_spec_and_artifact($spec, $artifact);
  my $root = open_root($root_arg);
  my $parsed = parse_audit($root, $spec);
  fatal('receipt attempt absent') unless exists($parsed->{attempt}{$attempt});
  my $receipt = $parsed->{attempt}{$attempt};
  fatal('receipt role mismatch') unless $receipt->{role} eq $role;
  fatal('receipt attempt is not open') unless $receipt->{status} eq 'open';
  fatal('open receipt is not in current generation')
    unless $receipt->{start}{generation} == $parsed->{generation};
  my $artifact_raw = read_repo_file($root, $artifact, 1);
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  fatal('receipt artifact changed during lifecycle verification')
    unless read_repo_file($root, $artifact, 1) eq $artifact_raw;
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  my $sha = sha256_hex($artifact_raw);
  my $start = $receipt->{start};
  print join(q{;},
    "attempt=$start->{attempt}", "generation=$start->{generation}",
    "actor=$start->{actor}", "subject=$start->{subject}",
    "capability=$start->{capability}", "artifact=$artifact", "sha256=$sha"), "\n";
  exit 0;
}

if ($command eq 'verify-finished') {
  @ARGV == 4 or usage();
  my ($root_arg, $spec, $role, $attempt) = @ARGV;
  fatal('SPEC_DIR grammar mismatch')
    unless defined($spec) && $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  fatal('unknown receipt role') unless valid_role($role);
  fatal('receipt attempt malformed') unless $attempt =~ /\A$ATTEMPT\z/;
  my $root = open_root($root_arg);
  my $parsed = parse_audit($root, $spec);
  my $receipt = current_finished_receipt($parsed, $role, $attempt);
  my $finish = $receipt->{terminal};
  validate_spec_and_artifact($spec, $finish->{artifact});
  my $artifact_raw = read_repo_file($root, $finish->{artifact}, 1);
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  fatal('receipt artifact changed during lifecycle verification')
    unless read_repo_file($root, $finish->{artifact}, 1) eq $artifact_raw;
  assert_audit_unchanged($root, $spec, $parsed->{audit_raw});
  my $sha = sha256_hex($artifact_raw);
  fatal('receipt artifact digest mismatch') unless $sha eq $finish->{sha256};
  for my $key (qw(attempt generation actor subject capability artifact sha256)) {
    print "$key=$finish->{$key}\n";
  }
  # Bind every caller to the exact audit snapshot that produced this receipt.  A parent verifier
  # may pin its own descriptor and reject an ABA/path-swap if the child observed other bytes.
  print 'auditsha256=', sha256_hex($parsed->{audit_raw}), "\n";
  exit 0;
}

usage();
