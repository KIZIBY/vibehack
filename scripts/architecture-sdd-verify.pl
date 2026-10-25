#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Cwd qw(abs_path);
use Digest::SHA qw(sha256_hex);
use Encode qw(decode FB_CROAK LEAVE_SRC);
use Errno qw(ENOENT);
use Fcntl qw(:DEFAULT O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISLNK S_ISREG);
use File::Basename qw(dirname);

my $MAX_FILE = 16 * 1024 * 1024;
my $MAX_SET  = 64 * 1024 * 1024;
my $total = 0;
my @pins;
my @dir_sets;
my @absence_pins;

sub fatal { print STDERR "architecture-sdd-verify: FATAL: $_[0]\n"; exit 2 }
sub inode_id { return $_[0] . q{:} . $_[1] }
sub trim { my $v = $_[0] // q{}; $v =~ s/\A\s+|\s+\z//g; return $v }

# Capture this before any descriptor-relative chdir.  Relative CLI invocation must not make the
# sibling receipt helper depend on whichever artifact happened to be read last.
my $SCRIPT_PATH = abs_path($0);
fatal('script path unavailable') unless defined($SCRIPT_PATH);
my $SCRIPT_DIR = dirname($SCRIPT_PATH);

sub safe_rel {
  my ($path) = @_;
  fatal('unsafe repo-relative path') unless defined($path) && length($path)
    && $path !~ m{\A/} && $path !~ /[\x00-\x1f\x7f]/;
  my $decoded;
  eval { $decoded = decode(q{UTF-8}, $path, FB_CROAK | LEAVE_SRC); 1 }
    or fatal('repo-relative path is not UTF-8');
  fatal('Unicode control in repo-relative path') if $decoded =~ /\p{Cc}/;
  my @part = split m{/}, $path, -1;
  fatal('unsafe path segment') if grep { $_ eq q{} || $_ eq q{.} || $_ eq q{..} } @part;
  return @part;
}

sub root_abs {
  my ($root) = @_;
  my @input = lstat($root);
  fatal('repo root must not be a symlink') unless @input && !S_ISLNK($input[2]) && S_ISDIR($input[2]);
  my $abs = abs_path($root);
  fatal('repo root unavailable') unless defined($abs);
  my @s = lstat($abs);
  fatal('repo root must be real directory') unless @s && !S_ISLNK($s[2]) && S_ISDIR($s[2]);
  return $abs;
}

sub read_fd {
  my ($fh, $limit, $label) = @_;
  sysseek($fh, 0, 0) >= 0 or fatal("seek failed: $label");
  my $raw = q{};
  while (1) {
    my $n = sysread($fh, my $buf, 65536);
    fatal("read failed: $label") unless defined($n);
    last unless $n;
    $raw .= $buf;
    fatal("$label exceeds size limit") if length($raw) > $limit;
  }
  return $raw;
}

sub open_chain {
  my ($root, $parts, $label) = @_;
  my @root_named = lstat($root);
  fatal('repo root identity unavailable') unless @root_named && !S_ISLNK($root_named[2]) && S_ISDIR($root_named[2]);
  sysopen(my $dir, $root, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) or fatal('repo root open failed');
  my @root_opened = stat($dir);
  fatal('repo root identity changed') unless @root_opened && inode_id(@root_opened) eq inode_id(@root_named);
  my @hold = ($dir);
  for my $component (@$parts) {
    chdir($dir) or fatal("unsafe parent for $label");
    my @named = lstat($component);
    fatal("unsafe parent for $label") unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
    sysopen(my $next, $component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
      or fatal("unsafe parent for $label");
    my @opened = stat($next);
    fatal("parent identity changed for $label")
      unless @opened && inode_id(@opened) eq inode_id(@named);
    push @hold, $next;
    $dir = $next;
  }
  return ($dir, \@hold);
}

sub revalidate_chain {
  my ($root, $parts, $held, $label) = @_;
  my ($current, $opened) = open_chain($root, $parts, $label);
  fatal("directory chain changed for $label") unless @$opened == @$held;
  for my $i (0 .. $#$held) {
    my @a = stat($opened->[$i]); my @b = stat($held->[$i]);
    fatal("directory chain changed for $label")
      unless @a && @b && inode_id(@a) eq inode_id(@b);
  }
}

sub safe_read {
  my ($root, $rel, $count) = @_;
  my @part = safe_rel($rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable for $rel");
  my @named = lstat($leaf);
  fatal("$rel must be regular, non-symlink, single-link")
    unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  fatal("$rel mode must be 100644") unless ($named[2] & 07777) == 0644;
  fatal("$rel exceeds 16 MiB") if $named[7] > $MAX_FILE;
  sysopen(my $fh, $leaf, O_RDONLY | O_NOFOLLOW) or fatal("cannot open $rel");
  my @opened = stat($fh);
  fatal("$rel identity changed") unless @opened && inode_id(@opened) eq inode_id(@named)
    && S_ISREG($opened[2]) && $opened[3] == 1 && ($opened[2] & 07777) == 0644;
  my $raw = read_fd($fh, $MAX_FILE, $rel);
  my $confirm = read_fd($fh, $MAX_FILE, $rel);
  fatal("$rel changed during read") unless $confirm eq $raw;
  my @after = stat($fh); my @again = lstat($leaf);
  fatal("$rel changed during read") unless @after && @again && !S_ISLNK($again[2])
    && S_ISREG($after[2]) && S_ISREG($again[2]) && $after[3] == 1 && $again[3] == 1
    && inode_id(@after) eq inode_id(@opened) && inode_id(@again) eq inode_id(@opened)
    && $after[7] == length($raw) && $again[7] == length($raw)
    && ($after[2] & 07777) == 0644 && ($again[2] & 07777) == 0644;
  if ($count) { $total += length($raw); fatal('design root set exceeds 64 MiB') if $total > $MAX_SET }
  push @pins, { root => $root, parts => [@part], dirs => $hold, dir => $dir,
    leaf => $leaf, rel => $rel, fh => $fh, raw => $raw };
  return $raw;
}

sub optional_file_present {
  my ($root, $rel) = @_;
  my @part = safe_rel($rel);
  my $leaf = pop @part;
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal("artifact directory unavailable for $rel");
  my @named = lstat($leaf);
  if (!@named) {
    fatal("optional artifact status unavailable: $rel") unless $! == ENOENT;
    push @absence_pins, { root => $root, parts => [@part], dirs => $hold,
      dir => $dir, leaf => $leaf, rel => $rel };
    return 0;
  }
  fatal("optional artifact is not regular 100644: $rel")
    if S_ISLNK($named[2]) || !S_ISREG($named[2]) || $named[3] != 1
      || ($named[2] & 07777) != 0644;
  chdir(q{/}) or fatal('cannot leave optional artifact directory');
  close($_) or fatal("optional artifact probe close failed: $rel") for reverse @$hold;
  return 1;
}

sub revalidate_pins {
  for my $pin (@absence_pins) {
    revalidate_chain($pin->{root}, $pin->{parts}, $pin->{dirs}, $pin->{rel});
    chdir($pin->{dir}) or fatal("artifact directory unavailable for $pin->{rel}");
    my @named = lstat($pin->{leaf});
    fatal("optional Design-Root artifact appeared before authorization: $pin->{rel}") if @named;
    fatal("optional artifact absence cannot be revalidated: $pin->{rel}") unless $! == ENOENT;
  }
  for my $set (@dir_sets) {
    revalidate_chain($set->{root}, $set->{parts}, $set->{dirs}, $set->{rel});
    chdir($set->{dir}) or fatal("directory unavailable: $set->{rel}");
    opendir(my $dh, q{.}) or fatal("directory unreadable: $set->{rel}");
    my @name = sort { use bytes; $a cmp $b }
      grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
    closedir($dh) or fatal("directory close failed: $set->{rel}");
    fatal("closed path-set changed: $set->{rel}") unless join(q{\0}, @name) eq join(q{\0}, @{$set->{names}});
  }
  for my $pin (@pins) {
    revalidate_chain($pin->{root}, $pin->{parts}, $pin->{dirs}, $pin->{rel});
    chdir($pin->{dir}) or fatal("artifact directory unavailable for $pin->{rel}");
    my @named = lstat($pin->{leaf}); my @opened = stat($pin->{fh});
    fatal("$pin->{rel} changed before authorization") unless @named && @opened
      && !S_ISLNK($named[2]) && S_ISREG($named[2]) && S_ISREG($opened[2])
      && $named[3] == 1 && $opened[3] == 1
      && inode_id(@named) eq inode_id(@opened)
      && ($named[2] & 07777) == 0644 && ($opened[2] & 07777) == 0644
      && $named[7] == length($pin->{raw}) && $opened[7] == length($pin->{raw});
    my $now = read_fd($pin->{fh}, $MAX_FILE, $pin->{rel});
    fatal("$pin->{rel} changed before authorization") unless $now eq $pin->{raw};
    my @after = stat($pin->{fh}); my @again = lstat($pin->{leaf});
    fatal("$pin->{rel} changed before authorization") unless @after && @again
      && !S_ISLNK($again[2]) && S_ISREG($after[2]) && S_ISREG($again[2])
      && $after[3] == 1 && $again[3] == 1
      && inode_id(@after) eq inode_id(@opened) && inode_id(@again) eq inode_id(@opened)
      && ($after[2] & 07777) == 0644 && ($again[2] & 07777) == 0644
      && $after[7] == length($pin->{raw}) && $again[7] == length($pin->{raw});
  }
}

sub utf8_text {
  my ($raw, $name) = @_;
  fatal("NUL in $name") if $raw =~ /\x00/;
  my $text;
  eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
    or fatal("$name is not UTF-8");
  return $text;
}

sub section {
  my ($text, $name) = @_;
  my @v = ($text =~ /^## \Q$name\E\s*\n(.*?)(?=^## |\z)/msg);
  fatal("section '$name' missing or duplicated") unless @v == 1 && $v[0] =~ /\S/;
  return $v[0];
}

sub optional_section {
  my ($text, $name) = @_;
  my @v = ($text =~ /^## \Q$name\E\s*\n(.*?)(?=^## |\z)/msg);
  fatal("section '$name' duplicated") if @v > 1;
  return @v ? $v[0] : undef;
}

sub meta_one {
  my ($text, $key) = @_;
  my @v = ($text =~ /^- \Q$key\E: (.+)$/mg);
  fatal("metadata $key missing or duplicated") unless @v == 1;
  return trim($v[0]);
}

my $DECIMAL_RE = qr/-?(?:0|[1-9][0-9]{0,31})(?:\.[0-9]{0,8}[1-9])?/;

sub number {
  my ($v) = @_;
  return 0 unless defined($v) && $v =~ /\A$DECIMAL_RE\z/;
  return 0 if $v =~ /\A-0(?:\.0*)?\z/;
  (my $digits = $v) =~ s/[-.]//g;
  return length($digits) <= 40;
}

sub decimal_cmp { # exact canonical decimal comparison; no NV/IV coercion
  my ($a, $b) = @_;
  fatal('internal non-canonical decimal') unless number($a) && number($b);
  my $as = $a =~ s/\A-// ? -1 : 1;
  my $bs = $b =~ s/\A-// ? -1 : 1;
  return $as <=> $bs if $as != $bs;
  my ($ai, $af) = split /\./, $a, 2; $af //= q{};
  my ($bi, $bf) = split /\./, $b, 2; $bf //= q{};
  my $cmp = length($ai) <=> length($bi);
  $cmp ||= $ai cmp $bi;
  my $width = length($af) > length($bf) ? length($af) : length($bf);
  $af .= q{0} x ($width - length($af));
  $bf .= q{0} x ($width - length($bf));
  $cmp ||= $af cmp $bf;
  return $as == 1 ? $cmp : -$cmp;
}

sub spec_requirements {
  my ($text) = @_;
  my @id = ($text =~ /^- \*\*((?:FR|NFR)-[0-9]{3})(?=[ (])/mg);
  fatal('spec has no canonical FR/NFR definitions') unless @id;
  my %seen;
  fatal('spec requirement definition duplicated') if grep { $seen{$_}++ } @id;
  return { map { $_ => 1 } @id };
}

sub validate_decision {
  my ($text, $file_id, $spec_req) = @_;
  fatal('wrong decision contract') unless meta_one($text, 'Contract-Version') eq 'architecture-decision-v1';
  my $id = meta_one($text, 'Decision-ID');
  fatal('Decision-ID does not match filename') unless $id eq $file_id;
  fatal('decision must be accepted') unless meta_one($text, 'Status') eq 'accepted';
  my $selected = meta_one($text, 'Selected-Option');
  fatal('Selection-Status must be selected for bind')
    unless meta_one($text, 'Selection-Status') eq 'selected';

  my $actor_re = qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
  my $attempt_re = qr/[0-9a-f]{64}/;
  my %identity = (
    author_actor => meta_one($text, 'Author-Actor'),
    author_attempt => meta_one($text, 'Author-Attempt'),
    reviewer_actor => meta_one($text, 'Reviewer-Actor'),
    reviewer_attempt => meta_one($text, 'Reviewer-Attempt'),
  );
  fatal('decision actor identity malformed') unless $identity{author_actor} =~ /\A$actor_re\z/
    && $identity{reviewer_actor} =~ /\A$actor_re\z/;
  fatal('decision attempt identity malformed') unless $identity{author_attempt} =~ /\A$attempt_re\z/
    && $identity{reviewer_attempt} =~ /\A$attempt_re\z/;
  fatal('decision author and reviewer actors must be distinct')
    if $identity{author_actor} eq $identity{reviewer_actor};
  fatal('decision author and reviewer attempts must be distinct')
    if $identity{author_attempt} eq $identity{reviewer_attempt};

  my $requirements = meta_one($text, 'Requirements');
  my @requirements = split /, /, $requirements, -1;
  fatal('Requirements must use canonical sorted comma-space order')
    unless join(q{, }, @requirements) eq join(q{, }, sort @requirements);
  my %requirement;
  for my $r (@requirements) {
    fatal('invalid or duplicate linked requirement')
      unless $r =~ /\A(?:FR|NFR)-[0-9]{3}\z/ && !$requirement{$r}++;
    fatal("linked requirement $r is not a canonical spec definition") unless $spec_req->{$r};
  }
  fatal('decision must link at least one requirement') unless @requirements;

  my $hard = section($text, 'Hard Constraints');
  fatal('Hard Constraints must contain bullets') unless $hard =~ /^- \S/m;
  for my $required ('Problem And Class Boundary', 'Migration And Rollback',
      'Consequences', 'Disconfirming Evidence And Revisit Triggers') {
    section($text, $required);
  }
  my $chosen = section($text, 'Chosen Decision');
  fatal('Chosen Decision does not name Selected-Option') unless $chosen =~ /\b\Q$selected\E\b/;

  my $ff_text = section($text, 'Fitness Functions');
  my @ff_line = grep { /^\|/ } split /\n/, $ff_text;
  fatal('Fitness Functions header malformed') unless @ff_line >= 3
    && $ff_line[0] eq '| ID | Axis | Direction | Unit | Class | Threshold |'
    && $ff_line[1] eq '|---|---|---|---|---|---|';
  shift @ff_line; shift @ff_line;
  my (@ff_id, %ff, %axis);
  my %protected = map { $_ => 1 } qw(correctness data-safety security compatibility);
  for my $line (@ff_line) {
    my @c = map { trim($_) } split /\|/, $line, -1; shift @c; pop @c;
    fatal('Fitness Function row malformed') unless @c == 6;
    my ($fid, $axis, $direction, $unit, $class, $threshold) = @c;
    fatal('invalid or duplicate fitness ID') unless $fid =~ /\AFF-[0-9]{3}\z/ && !$ff{$fid};
    fatal('invalid fitness axis') unless $axis =~ /\A(?:correctness|data-safety|security|compatibility|cost|speed|simplicity|maintainability|performance|other-[a-z0-9][a-z0-9-]{0,31})\z/;
    fatal('invalid fitness direction') unless $direction =~ /\A(?:min|max|bool)\z/;
    fatal('invalid fitness unit') unless $unit =~ /\A[A-Za-z][A-Za-z0-9._%\/-]{0,31}\z/;
    fatal('invalid fitness class') unless $class =~ /\A(?:hard|soft)\z/;
    my $threshold_value;
    if ($direction eq 'bool') {
      fatal('bool threshold must be pass') unless $threshold eq 'pass';
    } elsif ($direction eq 'min') {
      ($threshold_value) = $threshold =~ /\A<=($DECIMAL_RE)\z/;
      fatal('min threshold malformed') unless defined($threshold_value) && number($threshold_value);
    } else {
      ($threshold_value) = $threshold =~ /\A>=($DECIMAL_RE)\z/;
      fatal('max threshold malformed') unless defined($threshold_value) && number($threshold_value);
    }
    fatal("protected axis $axis must be hard") if $protected{$axis} && $class ne 'hard';
    $axis{$axis}++;
    $ff{$fid} = { axis => $axis, direction => $direction, class => $class,
      threshold => $threshold, threshold_value => $threshold_value };
    push @ff_id, $fid;
  }
  for my $axis (sort keys %protected) {
    fatal("protected hard fitness axis missing: $axis") unless $axis{$axis};
  }

  my $options = section($text, 'Options');
  my @option = ($options =~ /^### (OPT-[0-9]{3}[A-Z]?) — .+$/mg);
  my %option; $option{$_}++ for @option;
  fatal('at least three unique generated candidates required')
    unless @option >= 3 && !grep { $option{$_} != 1 } keys %option;
  fatal('Selected-Option absent from candidates') unless $option{$selected};
  for my $oid (@option) {
    fatal("candidate $oid has no rationale")
      unless $options =~ /^### \Q$oid\E — .+\n\n\S.*?(?=^### |\z)/ms;
  }

  my $constraints = section($text, 'Constraint Matrix');
  my @constraint_line = grep { /^\|/ } split /\n/, $constraints;
  fatal('Constraint Matrix header malformed') unless @constraint_line >= 3
    && $constraint_line[0] eq '| Option | Requirement | Result | Evidence |'
    && $constraint_line[1] eq '|---|---|---|---|';
  shift @constraint_line; shift @constraint_line;
  my (%constraint, %constraint_evidence);
  for my $line (@constraint_line) {
    my @c = map { trim($_) } split /\|/, $line, -1; shift @c; pop @c;
    fatal('Constraint Matrix row malformed') unless @c == 4;
    my ($oid, $requirement_id, $result, $evidence) = @c;
    my $key = "$oid\0$requirement_id";
    fatal('Constraint Matrix option unknown') unless $option{$oid};
    fatal('Constraint Matrix requirement not linked by this dossier') unless $requirement{$requirement_id};
    fatal('Constraint Matrix result malformed') unless $result =~ /\A(?:pass|fail|unknown)\z/;
    fatal('Constraint Matrix evidence malformed')
      unless $evidence =~ /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/;
    fatal('Constraint Matrix pair duplicated') if exists $constraint{$key};
    $constraint{$key} = $result; $constraint_evidence{$key} = $evidence;
  }
  for my $oid (@option) {
    for my $r (@requirements) {
      fatal("Constraint Matrix missing $oid/$r") unless exists $constraint{"$oid\0$r"};
    }
  }
  fatal('Constraint Matrix has extra rows')
    unless keys(%constraint) == @option * @requirements;

  my $matrix = section($text, 'Fitness Matrix');
  my @matrix = grep { /^\|/ } split /\n/, $matrix;
  fatal('Fitness Matrix incomplete') unless @matrix >= 3;
  my @head = map { trim($_) } split /\|/, shift(@matrix), -1; shift @head; pop @head;
  fatal('Fitness Matrix header mismatch') unless join(q{|}, @head) eq join(q{|}, 'Option', @ff_id);
  my $separator = shift @matrix;
  fatal('Fitness Matrix separator malformed')
    unless $separator eq q{|} . join(q{|}, (q{---}) x (@ff_id + 1)) . q{|};
  my %value;
  for my $line (@matrix) {
    my @c = map { trim($_) } split /\|/, $line, -1; shift @c; pop @c;
    fatal('Fitness Matrix row width mismatch') unless @c == @ff_id + 1;
    my $oid = shift @c;
    fatal('unknown or duplicate matrix option') unless $option{$oid} && !$value{$oid};
    for my $i (0 .. $#ff_id) {
      my $fid = $ff_id[$i]; my $v = $c[$i];
      if ($ff{$fid}{direction} eq 'bool') {
        fatal('bool fitness malformed') unless $v =~ /\A(?:pass|fail|unknown)\z/;
      } else {
        fatal('numeric fitness malformed') unless $v eq 'unknown' || number($v);
      }
      $value{$oid}{$fid} = $v;
    }
  }
  fatal('matrix must cover every option') unless keys(%value) == keys(%option);

  my (%failure, @viable);
  for my $oid (@option) {
    for my $r (@requirements) {
      $failure{$oid}{$r} = 'requirement' if $constraint{"$oid\0$r"} ne 'pass';
    }
    for my $fid (@ff_id) {
      next unless $ff{$fid}{class} eq 'hard';
      my $v = $value{$oid}{$fid};
      if ($v eq 'unknown' || ($ff{$fid}{direction} eq 'bool' && $v ne 'pass')) {
        $failure{$oid}{$fid} = 'hard-fitness'; next;
      }
      if ($ff{$fid}{direction} eq 'min'
          && decimal_cmp($v, $ff{$fid}{threshold_value}) > 0) {
        $failure{$oid}{$fid} = 'hard-fitness';
      }
      if ($ff{$fid}{direction} eq 'max'
          && decimal_cmp($v, $ff{$fid}{threshold_value}) < 0) {
        $failure{$oid}{$fid} = 'hard-fitness';
      }
    }
    push @viable, $oid unless keys %{$failure{$oid} // {}};
  }
  fatal('selected option violates a requirement or hard fitness')
    unless grep { $_ eq $selected } @viable;

  my $single = optional_section($text, 'Single Feasible Option Evidence');
  if (@viable < 2) {
    fatal("section 'Single Feasible Option Evidence' missing") unless defined($single);
    my @line = grep { /^\|/ } split /\n/, $single;
    fatal('Single Feasible Option Evidence header malformed') unless @line >= 3
      && $line[0] eq '| Option | Kind | Ref | Evidence |'
      && $line[1] eq '|---|---|---|---|';
    shift @line; shift @line; my %excluded;
    for my $line (@line) {
      my @c = map { trim($_) } split /\|/, $line, -1; shift @c; pop @c;
      fatal('Single Feasible Option Evidence row malformed') unless @c == 4;
      my ($oid, $kind, $ref, $evidence) = @c;
      fatal('single-feasible option invalid or duplicated')
        unless $option{$oid} && $oid ne $selected && !$excluded{$oid}++;
      fatal('single-feasible kind malformed') unless $kind =~ /\A(?:requirement|hard-fitness)\z/;
      fatal('single-feasible ref does not prove exclusion')
        unless ($failure{$oid}{$ref} // q{}) eq $kind;
      fatal('single-feasible evidence malformed')
        unless $evidence =~ /\A[A-Za-z0-9][A-Za-z0-9._:\/-]{0,127}\z/;
    }
    for my $oid (@option) {
      next if $oid eq $selected;
      fatal("single-feasible evidence missing excluded $oid") unless $excluded{$oid};
    }
    fatal('single-feasible evidence row count mismatch') unless keys(%excluded) == @option - 1;
  } else {
    fatal('Single Feasible Option Evidence present with multiple viable options') if defined($single);
  }

  for my $oid (@viable) {
    for my $fid (@ff_id) {
      fatal('viable option has unknown fitness; NEEDS_ORACLE') if $value{$oid}{$fid} eq 'unknown';
    }
  }
  for my $other (@viable) {
    next if $other eq $selected;
    my ($all_no_worse, $strict) = (1, 0);
    my ($selected_all_no_worse, $selected_strict) = (1, 0);
    for my $fid (@ff_id) {
      my ($a, $b) = ($value{$other}{$fid}, $value{$selected}{$fid});
      my $cmp;
      if ($ff{$fid}{direction} eq 'bool') {
        $cmp = ($a eq $b ? 0 : $a eq 'pass' ? 1 : -1);
      } elsif ($ff{$fid}{direction} eq 'min') {
        $cmp = -decimal_cmp($a, $b);
      } else {
        $cmp = decimal_cmp($a, $b);
      }
      $all_no_worse = 0 if $cmp < 0; $strict = 1 if $cmp > 0;
      $selected_all_no_worse = 0 if $cmp > 0; $selected_strict = 1 if $cmp < 0;
    }
    fatal("selected option is Pareto-dominated by $other") if $all_no_worse && $strict;
    fatal("selected option ties $other; NEEDS_ORACLE") if $all_no_worse && !$strict;
    fatal("selected option has unresolved Pareto trade-off with $other; NEEDS_ORACLE")
      unless $selected_all_no_worse && $selected_strict;
  }
  return { id => $id, selected => $selected, requirements => \@requirements, %identity };
}

sub validate_trace {
  my ($text, $relations, $decision_ids, $spec_req) = @_;
  my @line = split /\n/, $text, -1;
  fatal('traceability.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('traceability header mismatch') unless shift(@line) eq "requirement\tdecision\ttest_intent\tacceptance";
  my %seen;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('traceability row malformed') unless @c == 4
      && !grep { $_ eq q{} || /[\r\n]/ || /\p{Cc}/ } @c;
    fatal('traceability requirement is not a canonical spec definition') unless $spec_req->{$c[0]};
    fatal('traceability decision unknown') unless $decision_ids->{$c[1]};
    my $pair = "$c[0]\0$c[1]";
    fatal('traceability pair is not linked by its dossier') unless $relations->{$pair};
    fatal('traceability requirement/decision pair duplicated') if $seen{$pair}++;
    fatal('traceability test intent malformed') unless $c[2] =~ /\AT-[A-Z0-9][A-Z0-9-]{1,63}\z/;
  }
  for my $pair (keys %$relations) {
    my ($r, $id) = split /\0/, $pair, 2;
    fatal("trace missing $r/$id") unless $seen{$pair};
  }
  fatal('traceability contains extra pairs') unless keys(%seen) == keys(%$relations);
}

sub validate_changelog {
  my ($text) = @_;
  my @line = split /\n/, $text, -1;
  fatal('sdd-changelog.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('sdd changelog header mismatch') unless shift(@line) eq "stage\trevision\tchange\treason";
  fatal('sdd changelog must not be empty') unless @line;
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('sdd changelog row malformed') unless @c == 4 && $c[0] =~ /\Astage-[1-4]\z/
      && $c[1] =~ /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/
      && $c[2] =~ /\S/ && $c[3] =~ /\S/ && !grep { /\p{Cc}/ } @c;
  }
}

sub additional_architecture_paths {
  my ($text, $spec) = @_;
  my @line = split /\n/, $text, -1;
  fatal('architecture-artifacts.tsv must end with one LF') unless pop(@line) eq q{};
  fatal('architecture-artifacts.tsv header mismatch')
    unless shift(@line) eq "path\tmode\tsha256";
  fatal('architecture-artifacts.tsv must not be empty') unless @line;
  my (@path, %seen);
  my $previous = q{};
  for my $line (@line) {
    my @c = split /\t/, $line, -1;
    fatal('architecture-artifacts.tsv row malformed')
      unless @c == 3 && $c[1] eq '100644' && $c[2] =~ /\A[0-9a-f]{64}\z/;
    safe_rel($c[0]);
    fatal('additional architecture artifact must stay inside SPEC_DIR')
      unless index($c[0], "$spec/") == 0;
    fatal('additional architecture artifact path is forbidden')
      if $c[0] =~ m{/(?:audit|state)[.]md\z}
        || $c[0] =~ m{/reviews/}
        || $c[0] =~ m{/decisions/}
        || $c[0] =~ m{/(?:spec|plan|roadmap-handoff)[.]md\z}
        || $c[0] =~ m{/(?:traceability|sdd-changelog|architecture-artifacts)[.]tsv\z};
    fatal('architecture-artifacts.tsv path duplicated') if $seen{$c[0]}++;
    fatal('architecture-artifacts.tsv paths must be bytewise sorted')
      if length($previous) && do { use bytes; $previous ge $c[0] };
    $previous = $c[0];
    push @path, [$c[0], $c[2]];
  }
  return @path;
}

sub decision_paths {
  my ($root, $spec) = @_;
  my $rel = "$spec/decisions";
  my @part = safe_rel($rel);
  my ($dir, $hold) = open_chain($root, \@part, $rel);
  chdir($dir) or fatal('decisions directory unavailable');
  opendir(my $dh, q{.}) or fatal('decisions directory unreadable');
  my @name = sort { use bytes; $a cmp $b }
    grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
  closedir($dh) or fatal('decisions directory close failed');
  fatal('decisions directory empty') unless @name;
  for my $name (@name) { fatal('closed decisions path-set violation') unless $name =~ /\AAD-[0-9]{3}\.md\z/ }
  push @dir_sets, { root => $root, parts => [@part], dirs => $hold, dir => $dir,
    rel => $rel, names => [@name] };
  return map { "$spec/decisions/$_" } @name;
}

sub build_candidate {
  my ($root, $spec) = @_;
  $total = 0; @pins = (); @dir_sets = (); @absence_pins = ();
  fatal('SPEC_DIR grammar mismatch') unless $spec =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
  my @path = ("$spec/spec.md", "$spec/plan.md", "$spec/roadmap-handoff.md",
    "$spec/traceability.tsv", "$spec/sdd-changelog.tsv", decision_paths($root, $spec));
  my $bootstrap_path = "$spec/producer-bootstrap-v1.tsv";
  push @path, $bootstrap_path if optional_file_present($root, $bootstrap_path);
  my $architecture_artifacts_path = "$spec/architecture-artifacts.tsv";
  my %raw;
  my @additional;
  if (optional_file_present($root, $architecture_artifacts_path)) {
    push @path, $architecture_artifacts_path;
    $raw{$architecture_artifacts_path} =
      safe_read($root, $architecture_artifacts_path, 1);
    @additional = additional_architecture_paths(
      utf8_text(
        $raw{$architecture_artifacts_path},
        'architecture-artifacts.tsv',
      ),
      $spec,
    );
    push @path, map { $_->[0] } @additional;
  }
  my %path_seen;
  for my $path (@path) {
    fatal("Design-Root artifact duplicated: $path") if $path_seen{$path}++;
    $raw{$path} = safe_read($root, $path, 1) unless exists($raw{$path});
  }
  for my $entry (@additional) {
    fatal("additional architecture artifact digest mismatch: $entry->[0]")
      unless sha256_hex($raw{$entry->[0]}) eq $entry->[1];
  }
  my $spec_text = utf8_text($raw{"$spec/spec.md"}, 'spec.md');
  my $spec_req = spec_requirements($spec_text);
  fatal('plan.md empty') unless utf8_text($raw{"$spec/plan.md"}, 'plan.md') =~ /\S/;
  fatal('roadmap-handoff.md empty') unless utf8_text($raw{"$spec/roadmap-handoff.md"}, 'roadmap-handoff.md') =~ /\S/;
  my (%requirements, %relations, %decision_id, @decision);
  for my $path (grep { m{/decisions/} } @path) {
    my ($file_id) = $path =~ m{/(AD-[0-9]{3})\.md\z};
    my $record = validate_decision(utf8_text($raw{$path}, $path), $file_id, $spec_req);
    fatal('decision ID duplicated') if $decision_id{$record->{id}}++;
    push @decision, $record;
    for my $r (@{$record->{requirements}}) {
      $requirements{$r} = 1;
      $relations{"$r\0$record->{id}"} = 1;
    }
  }
  for my $r (keys %$spec_req) { fatal("spec requirement $r missing from all dossiers") unless $requirements{$r} }
  for my $r (keys %requirements) { fatal("dossier requirement $r absent from spec definitions") unless $spec_req->{$r} }
  fatal('spec and dossier requirement sets differ') unless keys(%requirements) == keys(%$spec_req);
  validate_trace(utf8_text($raw{"$spec/traceability.tsv"}, 'traceability.tsv'),
    \%relations, \%decision_id, $spec_req);
  validate_changelog(utf8_text($raw{"$spec/sdd-changelog.tsv"}, 'sdd-changelog.tsv'));
  if (exists($raw{$bootstrap_path})) {
    my $bootstrap = utf8_text($raw{$bootstrap_path}, 'producer-bootstrap-v1.tsv');
    my @line = split /\n/, $bootstrap, -1;
    fatal('producer-bootstrap-v1.tsv must end with one LF') unless pop(@line) eq q{};
    fatal('producer-bootstrap-v1.tsv header mismatch')
      unless shift(@line) eq "path\tmode\tsha256";
    my @expected = qw(scripts/implementation-tdd-verify.pl scripts/tdd-receipt-v1.pl);
    fatal('producer-bootstrap-v1.tsv must bind the exact TDD producer set')
      unless @line == @expected;
    for my $i (0 .. $#expected) {
      my @c = split /\t/, $line[$i], -1;
      fatal('producer-bootstrap-v1.tsv row malformed')
        unless @c == 3 && $c[0] eq $expected[$i]
          && $c[1] eq '100644' && $c[2] =~ /\A[0-9a-f]{64}\z/;
    }
  }
  for my $field (qw(author_actor author_attempt reviewer_actor reviewer_attempt)) {
    my %v = map { $_->{$field} => 1 } @decision;
    fatal("candidate decisions disagree on $field") unless keys(%v) == 1;
  }
  my $manifest = "HARNESS-DESIGN-ROOT-V1\n";
  for my $path (sort { use bytes; $a cmp $b } @path) {
    $manifest .= join("\t", 'F', $path, '100644', length($raw{$path}), sha256_hex($raw{$path})) . "\n";
  }
  my %identity = map { $_ => $decision[0]{$_} }
    qw(author_actor author_attempt reviewer_actor reviewer_attempt);
  return ($manifest, sha256_hex($manifest), [sort keys %decision_id], \%identity);
}

sub validate_review {
  my ($root, $spec, $design_root, $decision_ids, $identity) = @_;
  my $rel = "$spec/reviews/architecture-critical-review.md";
  my $raw = safe_read($root, $rel, 0);
  my $text = utf8_text($raw, $rel);
  fatal('wrong architecture review contract') unless meta_one($text, 'Contract-Version') eq 'architecture-review-v1';
  my $listed = meta_one($text, 'Decision-IDs');
  my @listed = split /, /, $listed, -1;
  fatal('review Decision-IDs are not canonical sorted unique IDs')
    unless @listed && join(q{, }, @listed) eq join(q{, }, sort @listed);
  my %listed; fatal('review Decision-ID duplicated or malformed')
    if grep { $_ !~ /\AAD-[0-9]{3}\z/ || $listed{$_}++ } @listed;
  fatal('review Decision-IDs do not cover the complete candidate')
    unless keys(%listed) == @$decision_ids && !grep { !$listed{$_} } @$decision_ids;
  fatal('review subject does not equal Design candidate root') unless meta_one($text, 'Subject') eq $design_root;
  my %review_identity = (
    author_actor => meta_one($text, 'Author-Actor'),
    author_attempt => meta_one($text, 'Author-Attempt'),
    reviewer_actor => meta_one($text, 'Reviewer-Actor'),
    reviewer_attempt => meta_one($text, 'Reviewer-Attempt'),
  );
  fatal('review actor handle malformed') unless $review_identity{author_actor} =~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/
    && $review_identity{reviewer_actor} =~ /\A[A-Za-z0-9][A-Za-z0-9._:-]{0,127}\z/;
  fatal('review attempt handle malformed') unless $review_identity{author_attempt} =~ /\A[0-9a-f]{64}\z/
    && $review_identity{reviewer_attempt} =~ /\A[0-9a-f]{64}\z/;
  for my $field (sort keys %review_identity) {
    fatal("review $field does not match candidate dossier")
      unless $review_identity{$field} eq $identity->{$field};
  }
  fatal('review is not actor-independent')
    if $review_identity{author_actor} eq $review_identity{reviewer_actor};
  fatal('review is not attempt-independent')
    if $review_identity{author_attempt} eq $review_identity{reviewer_attempt};
  fatal('review verdict must PASS') unless meta_one($text, 'Verdict') eq 'PASS';
  for my $p (qw(P0 P1 P2)) { fatal("review $p must be zero") unless meta_one($text, $p) eq '0' }
  meta_one($text, 'P3') =~ /\A[0-9]+\z/ or fatal('review P3 malformed');
  section($text, 'Findings'); section($text, 'Verification');

  # The receipt helper owns audit grammar/lifecycle parsing.  The parent still pins the exact audit
  # inode+bytes across the child call so a concurrent invalidation cannot be hidden between child
  # verification and the binding record returned to the canonical writer.
  my $audit_raw = safe_read($root, "$spec/audit.md", 0);
  my $helper = "$SCRIPT_DIR/receipt-v1.pl";
  fatal('receipt helper unavailable') unless -f $helper;
  local %ENV = %ENV;
  delete @ENV{qw(PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC)};
  open(my $pipe, '-|', $^X, $helper, 'verify-finished', $root, $spec, 'architecture',
    $review_identity{reviewer_attempt})
    or fatal('receipt verifier launch failed');
  my $out = do { local $/; <$pipe> // q{} };
  close($pipe) or fatal('architecture receipt invalid');
  my @expected = qw(attempt generation actor subject capability artifact sha256 auditsha256);
  my @line = split /\n/, $out, -1;
  fatal('receipt verifier output must end with one LF') unless pop(@line) eq q{};
  fatal('receipt verifier output field count mismatch') unless @line == @expected;
  my %receipt;
  for my $i (0 .. $#expected) {
    my ($key, $value) = $line[$i] =~ /\A([a-z0-9]+)=(.*)\z/;
    fatal('receipt verifier output malformed') unless defined($key) && $key eq $expected[$i];
    $receipt{$key} = $value;
  }
  fatal('receipt attempt does not match reviewer attempt')
    unless $receipt{attempt} eq $review_identity{reviewer_attempt};
  fatal('receipt actor does not match reviewer actor')
    unless $receipt{actor} eq $review_identity{reviewer_actor};
  fatal('receipt subject does not match Design candidate root') unless $receipt{subject} eq $design_root;
  fatal('receipt capability mismatch') unless $receipt{capability} eq 'architecture-review-v1';
  fatal('receipt artifact mismatch') unless $receipt{artifact} eq $rel;
  fatal('receipt artifact SHA mismatch') unless $receipt{sha256} eq sha256_hex($raw);
  fatal('receipt audit snapshot mismatch')
    unless $receipt{auditsha256} eq sha256_hex($audit_raw);
  $receipt{audit_raw} = $audit_raw;
  return \%receipt;
}

sub validate_design_bind {
  my ($raw, $expected) = @_;
  my $text = utf8_text($raw, 'audit.md');
  my $modern = "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n"
    . "| ts (UTC) | event | detail |\n|---|---|---|\n";
  my $legacy = "# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
  my $body;
  if (index($text, $modern) == 0) { $body = substr($text, length($modern)) }
  elsif (index($text, $legacy) == 0) { $body = substr($text, length($legacy)) }
  else { fatal('audit.md header is not canonical') }
  my $last;
  while (length($body)) {
    $body =~ s/\A\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
      or fatal('audit.md row is not canonical');
    my ($event, $detail) = ($1, $2);
    if ($event eq 'design-bind') {
      $detail =~ /\Aroot=[0-9a-f]{64};attempt=[0-9a-f]{64};generation=(?:0|[1-9][0-9]*);actor=[A-Za-z0-9][A-Za-z0-9._:-]{0,127};sha256=[0-9a-f]{64}\z/
        or fatal('design-bind detail is not canonical');
      $last = $detail;
    } elsif ($event =~ /\Adesign-bind/) {
      fatal('spoofed design-bind event');
    }
  }
  fatal('current design-bind absent or stale') unless defined($last) && $last eq $expected;
}

sub usage { fatal('usage: architecture-sdd-verify.pl <manifest|candidate|verify|verify-bound> <repo-root> <SPEC_DIR>') }
my $cmd = shift // usage();
@ARGV >= 2 or usage();
my $root = root_abs(shift @ARGV);
my $spec = shift @ARGV;
my ($manifest, $design_root, $decision_ids, $identity) = build_candidate($root, $spec);
if ($cmd eq 'manifest') {
  @ARGV == 0 or usage(); revalidate_pins(); binmode(STDOUT); print $manifest; exit 0;
}
if ($cmd eq 'candidate') {
  @ARGV == 0 or usage(); revalidate_pins(); print "$design_root\n"; exit 0;
}
if ($cmd eq 'verify' || $cmd eq 'verify-bound') {
  @ARGV == 0 or usage();
  my $receipt = validate_review($root, $spec, $design_root, $decision_ids, $identity);
  if ($cmd eq 'verify-bound') {
    my $detail = join(q{;},
      "root=$design_root", "attempt=$receipt->{attempt}",
      "generation=$receipt->{generation}", "actor=$receipt->{actor}",
      "sha256=$receipt->{sha256}");
    validate_design_bind($receipt->{audit_raw}, $detail);
  }
  revalidate_pins();
  print "Design-Root: $design_root\n";
  print "Review-Attempt: $receipt->{attempt}\n";
  print "Review-Generation: $receipt->{generation}\n";
  print "Review-Actor: $receipt->{actor}\n";
  print "Review-SHA256: $receipt->{sha256}\n";
  print "Audit-SHA256: $receipt->{auditsha256}\n";
  exit 0;
}
usage();
