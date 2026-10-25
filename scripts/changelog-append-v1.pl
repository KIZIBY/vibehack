#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISLNK S_ISREG SEEK_SET SEEK_END);
use IO::Handle ();

my $MAX_FILE = 16 * 1024 * 1024;
my $TEMP;

sub cleanup_temp {
  return unless $TEMP;
  my ($dir, $leaf, $id) = @{$TEMP}{qw(dir leaf id)};
  if (defined($dir) && defined($leaf) && defined($id) && chdir($dir)) {
    my @named = lstat($leaf);
    unlink($leaf) if @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && did(@named) eq $id;
  }
  $TEMP = undef;
}

END { cleanup_temp() }
for my $signal (qw(HUP INT TERM XFSZ)) {
  $SIG{$signal} = sub { exit 2 };
}

sub fatal {
  print STDERR encode(q{UTF-8}, "changelog-append-v1: FATAL: $_[0]\n");
  exit 2;
}

sub did { return $_[0] . q{:} . $_[1] }

sub safe_spec {
  my ($spec) = @_;
  fatal('SPEC_DIR grammar mismatch')
    unless defined($spec) && $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
}

sub text_arg {
  my ($raw, $name) = @_;
  fatal("$name absent") unless defined($raw) && length($raw);
  my $value;
  eval { $value = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$name is not UTF-8");
  fatal("$name contains control/TAB") if $value =~ /[\t\r\n]|\p{Cc}/;
  fatal("$name too long") if length(encode(q{UTF-8}, $value)) > 4096;
  return $value;
}

sub open_root {
  my ($path) = @_;
  my @named = lstat($path);
  fatal('repo root must be a real directory')
    unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
  my $abs = abs_path($path);
  fatal('repo root unavailable') unless defined($abs);
  sysopen(my $fh, $path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    or fatal('repo root open failed');
  my @opened = stat($fh);
  fatal('repo root identity changed')
    unless @opened && S_ISDIR($opened[2]) && did(@opened) eq did(@named);
  return { abs => $abs, fh => $fh, id => did(@opened) };
}

sub check_root {
  my ($root) = @_;
  my @opened = stat($root->{fh});
  my @named = lstat($root->{abs});
  fatal('repo root identity changed')
    unless @opened && @named && !S_ISLNK($named[2])
      && S_ISDIR($opened[2]) && S_ISDIR($named[2])
      && did(@opened) eq $root->{id} && did(@named) eq $root->{id};
}

sub check_parent_chain {
  my ($opened) = @_;
  my $root = $opened->{root};
  check_root($root);
  chdir($root->{fh}) or fatal('repo root traversal failed');
  my @fresh = ($root->{fh});
  my $index = 1;
  for my $component (@{$opened->{parent_parts}}) {
    my @named = lstat($component);
    fatal('canonical changelog parent changed')
      unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal('canonical changelog parent unavailable');
    my @resolved = stat($next);
    my @held = stat($opened->{hold}[$index]);
    fatal('canonical changelog parent changed')
      unless @resolved && @held && did(@resolved) eq did(@named)
        && did(@resolved) eq did(@held);
    push @fresh, $next;
    chdir($next) or fatal('canonical changelog parent unavailable');
    $index++;
  }
  my @canonical = stat($fresh[-1]);
  my @pinned = stat($opened->{dir});
  fatal('canonical changelog directory changed')
    unless @canonical && @pinned && did(@canonical) eq did(@pinned)
      && $index == @{$opened->{hold}};
}

sub open_changelog {
  my ($root, $rel) = @_;
  my @part = split m{/}, $rel, -1;
  fatal('unsafe changelog path')
    if !@part || grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..}
      || /[\x00-\x1f\x7f]/ } @part;
  check_root($root);
  chdir($root->{fh}) or fatal('repo root traversal failed');
  my @hold = ($root->{fh});
  my $dir = $root->{fh};
  for my $component (@part[0 .. $#part - 1]) {
    chdir($dir) or fatal('directory traversal failed');
    my @named = lstat($component);
    fatal('path parent must be a real directory')
      unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal('path parent open failed');
    my @opened = stat($next);
    fatal('path parent identity changed')
      unless @opened && S_ISDIR($opened[2]) && did(@opened) eq did(@named);
    push @hold, $next;
    $dir = $next;
  }
  # A directory lock survives atomic replacement of the changelog leaf and serializes other
  # canonical writers.  Locking only the old leaf would let a waiter append to a detached inode.
  flock($dir, 2) or fatal('changelog directory lock failed');
  my @parent_parts = @part[0 .. $#part - 1];
  my $opened_chain = {
    dir => $dir, hold => \@hold, root => $root, parent_parts => \@parent_parts,
  };
  check_parent_chain($opened_chain);
  chdir($dir) or fatal('changelog directory unavailable');
  my $leaf = $part[-1];
  my @named = lstat($leaf);
  fatal('changelog must be regular, non-symlink, single-link 100644')
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && $named[3] == 1 && ($named[2] & 07777) == 0644 && $named[7] <= $MAX_FILE;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal('changelog open failed');
  my @opened = stat($fh);
  fatal('changelog identity changed')
    unless @opened && did(@opened) eq did(@named) && $opened[3] == 1
      && ($opened[2] & 07777) == 0644 && $opened[7] <= $MAX_FILE;
  return {
    fh => $fh, dir => $dir, hold => \@hold, leaf => $leaf,
    opened => \@opened, root => $root, parent_parts => \@parent_parts,
  };
}

sub read_all {
  my ($fh) = @_;
  defined(sysseek($fh, 0, SEEK_SET)) or fatal('changelog seek failed');
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65536);
    fatal('changelog read failed') unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal('changelog exceeds 16 MiB') if length($raw) > $MAX_FILE;
  }
  return $raw;
}

sub check_leaf {
  my ($opened) = @_;
  check_parent_chain($opened);
  my @after = stat($opened->{fh});
  chdir($opened->{dir}) or fatal('changelog directory unavailable');
  my @named = lstat($opened->{leaf});
  fatal('changelog identity/mode changed')
    unless @after && @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
      && $after[3] == 1 && $named[3] == 1
      && ($after[2] & 07777) == 0644 && ($named[2] & 07777) == 0644
      && did(@after) eq did(@{$opened->{opened}}) && did(@named) eq did(@{$opened->{opened}});
  check_root($opened->{root});
}

sub random_hex {
  sysopen(my $urandom, '/dev/urandom', O_RDONLY) or fatal('random source unavailable');
  my $raw = q{};
  while (length($raw) < 16) {
    my $n = sysread($urandom, my $buf, 16 - length($raw));
    fatal('random source failed') unless defined($n) && $n > 0;
    $raw .= $buf;
  }
  close($urandom) or fatal('random source close failed');
  return unpack('H*', $raw);
}

sub write_all {
  my ($fh, $raw) = @_;
  my $offset = 0;
  while ($offset < length($raw)) {
    my $written = syswrite($fh, $raw, length($raw) - $offset, $offset);
    fatal('changelog temp write failed') unless defined($written) && $written > 0;
    $offset += $written;
  }
}

sub create_complete_temp {
  my ($opened, $payload) = @_;
  check_leaf($opened);
  chdir($opened->{dir}) or fatal('changelog directory unavailable');
  my ($leaf, $fh);
  for (1 .. 32) {
    $leaf = '.changelog-append-v1.' . random_hex();
    if (sysopen($fh, $leaf, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW, 0600)) {
      last;
    }
    undef($fh);
  }
  fatal('changelog temp creation failed') unless defined($fh);
  my @created = stat($fh);
  my @named = lstat($leaf);
  fatal('changelog temp identity invalid')
    unless @created && @named && !S_ISLNK($named[2]) && S_ISREG($created[2])
      && $created[3] == 1 && $created[4] == $< && did(@created) eq did(@named);
  $TEMP = { dir => $opened->{dir}, leaf => $leaf, id => did(@created) };
  write_all($fh, $payload);
  chmod(0644, $fh) == 1 or fatal('changelog temp mode failed');
  $fh->sync or fatal('changelog temp fsync failed');
  my $confirm = read_all($fh);
  my @after = stat($fh); @named = lstat($leaf);
  fatal('changelog temp postcondition failed')
    unless $confirm eq $payload && @after && @named && !S_ISLNK($named[2])
      && S_ISREG($after[2]) && $after[3] == 1 && did(@after) eq did(@created)
      && did(@named) eq did(@created) && ($after[2] & 07777) == 0644
      && ($named[2] & 07777) == 0644;
  close($fh) or fatal('changelog temp close failed');
  return ($leaf, did(@created));
}

sub publish_complete_temp {
  my ($opened, $temp, $temp_id, $payload) = @_;
  # CAS the exact old canonical inode and bytes immediately before the only visible mutation.
  check_leaf($opened);
  my $again = read_all($opened->{fh});
  fatal('changelog changed before publish') unless $again eq $opened->{raw};
  check_leaf($opened);
  chdir($opened->{dir}) or fatal('changelog directory unavailable');
  my @temp_named = lstat($temp);
  my @old_named = lstat($opened->{leaf});
  fatal('changelog publish CAS failed')
    unless @temp_named && @old_named && !S_ISLNK($temp_named[2])
      && S_ISREG($temp_named[2]) && did(@temp_named) eq $temp_id
      && did(@old_named) eq did(@{$opened->{opened}});
  rename($temp, $opened->{leaf}) or fatal('changelog atomic publish failed');
  $TEMP = undef;
  $opened->{dir}->sync or fatal('changelog directory fsync failed');
  check_parent_chain($opened);
  chdir($opened->{dir}) or fatal('changelog directory unavailable');
  my @current = lstat($opened->{leaf});
  fatal('published changelog identity invalid')
    unless @current && !S_ISLNK($current[2]) && S_ISREG($current[2])
      && $current[3] == 1 && did(@current) eq $temp_id
      && ($current[2] & 07777) == 0644;
  sysopen(my $current_fh, $opened->{leaf}, O_RDONLY | O_NOFOLLOW)
    or fatal('published changelog open failed');
  my @current_opened = stat($current_fh);
  my $final = read_all($current_fh);
  close($current_fh) or fatal('published changelog close failed');
  fatal('published changelog bytes invalid')
    unless @current_opened && did(@current_opened) eq did(@current)
      && $final eq $payload;
}

sub parse_existing {
  my ($raw, $header, $allowed_stage) = @_;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('changelog is not UTF-8');
  fatal('changelog header mismatch') unless index($text, $header) == 0;
  my $body = substr($text, length($header));
  fatal('changelog must end with one LF') if length($body) && $body !~ /\n\z/;
  my %row;
  for my $line (grep { length } split /\n/, $body, -1) {
    my @column = split /\t/, $line, -1;
    fatal('changelog row malformed') unless @column == 4;
    fatal('changelog stage malformed') unless $column[0] =~ /\Astage-[1-4]\z/;
    fatal('changelog stage is outside its authority')
      if $allowed_stage eq 'stage-2' && $column[0] !~ /\Astage-[12]\z/;
    fatal('changelog stage is outside its authority')
      if $allowed_stage eq 'stage-3' && $column[0] ne 'stage-3';
    fatal('changelog revision malformed')
      unless $column[1] =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/;
    fatal('changelog text malformed')
      if !length($column[2]) || !length($column[3])
        || grep { /[\t\r\n]|\p{Cc}/ } @column;
    $row{$line}++;
  }
  return \%row;
}

sub usage {
  fatal('usage: changelog-append-v1.pl <sdd|delivery> <repo-root> <SPEC_DIR> <revision> <result/change> <evidence/reason>');
}

@ARGV == 6 or usage();
my ($kind, $root_arg, $spec, $revision_raw, $value1_raw, $value2_raw) = @ARGV;
safe_spec($spec);
fatal('revision malformed')
  unless $revision_raw =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/;
my $value1 = text_arg($value1_raw, 'third column');
my $value2 = text_arg($value2_raw, 'fourth column');
my ($leaf, $header, $stage);
if ($kind eq 'sdd') {
  ($leaf, $header, $stage) =
    ('sdd-changelog.tsv', "stage\trevision\tchange\treason\n", 'stage-2');
} elsif ($kind eq 'delivery') {
  ($leaf, $header, $stage) =
    ('delivery-changelog.tsv', "stage\trevision\tresult\tevidence\n", 'stage-3');
} else {
  usage();
}

my $root = open_root($root_arg);
my $opened = open_changelog($root, "$spec/$leaf");
my $raw = read_all($opened->{fh});
$opened->{raw} = $raw;
my $existing = parse_existing($raw, $header, $stage);
my $line_text = join("\t", $stage, $revision_raw, $value1, $value2) . "\n";
my $line = encode(q{UTF-8}, $line_text);
if ($existing->{substr($line_text, 0, -1)}) {
  check_leaf($opened);
  close($opened->{fh}) or fatal('changelog close failed');
  print "existing sha256=", sha256_hex($line), "\n";
  exit 0;
}
fatal('append would exceed 16 MiB') if length($raw) + length($line) > $MAX_FILE;
my $payload = $raw . $line;
my ($temp, $temp_id) = create_complete_temp($opened, $payload);
publish_complete_temp($opened, $temp, $temp_id, $payload);
close($opened->{fh}) or fatal('changelog close failed');
print "appended sha256=", sha256_hex($line), "\n";
