#!/usr/bin/env perl
use strict;
use warnings;
use utf8;

use Digest::SHA qw(sha256_hex);
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG S_ISLNK);

if (@ARGV == 1 && $ARGV[0] eq q{--contract}) {
  print "pipeline-state-reader-v4/1\n";
  exit 0;
}
my $f = shift // q{};

sub bad {
  print STDERR encode(q{UTF-8}, "pipeline-state: FATAL: malformed state: $_[0]\n");
  exit 2;
}

sub did {
  my (@s) = @_;
  return $s[0] . q{:} . $s[1];
}

my $trusted_stream = $f eq q{-}
  && ($ENV{PIPELINE_STATE_TRUSTED_STDIN} // q{}) eq q{1};
my ($src, @named, @opened);
if ($trusted_stream) {
  open($src, q{<&=3}) or bad('trusted state stream недоступен');
  binmode($src);
} else {
  @named = lstat($f);
  bad('не regular/no-symlink state.md') unless @named
    && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3] == 1;
  sysopen($src, $f, O_RDONLY | O_NOFOLLOW) or bad('не читается state.md');
  @opened = stat($src);
  bad('state.md inode изменился до чтения') unless @opened
    && did(@opened) eq did(@named) && $opened[3] == 1;
}

my $raw = q{};
while (1) {
  my $n = sysread($src, my $buf, 65536);
  bad('ошибка чтения state.md') unless defined($n);
  last unless $n;
  $raw .= $buf;
  bad('state.md слишком велик') if length($raw) > 16777216;
}
my $text;
eval { $text = decode(q{UTF-8}, $raw, FB_CROAK | LEAVE_SRC); 1 }
  or bad('state.md не UTF-8');

my @stages = qw(stage-1-creative stage-2-audit stage-3-dev stage-4-quality);
my @gates = qw(constitution-gate user-approval quality-verdict);
my @roots = qw(Design-Root Implementation-Root Evidence-Root);
my (%stage_ok, %gate_ok, %conf_ok, %headers, %meta, %units);
my ($section, $version, $delivery_contract, $unit_seen, $body_started, $quality_head);
my %root_value;
my %is_stage = map { $_ => 1 } @stages;
my $after_units = 0;

for my $line (split /(?<=\n)/, $text) {
  chomp $line;
  if ($line =~ /^## (Stages|Gates|Confidence|Units)$/) {
    $body_started = 1;
    $section = $1;
    $headers{$section}++;
    $after_units = 1 if $section eq 'Units';
    next;
  }
  if ($line =~ /^## /) {
    bad('секция после ## Units') if $after_units;
    $body_started = 1;
    $section = 'other';
    next;
  }
  if ($line =~ /^- State-Version: (.*)$/) {
    bad('metadata вне header') if $body_started;
    $meta{version}++;
    $version = $1;
    next;
  }
  if ($line =~ /^- Delivery-Contract: (.*)$/) {
    bad('metadata вне header') if $body_started;
    $meta{delivery_contract}++;
    $delivery_contract = $1;
    next;
  }
  if ($line =~ /^- (Design-Root|Implementation-Root|Evidence-Root): (.*)$/) {
    bad('metadata вне header') if $body_started;
    $meta{$1}++;
    $root_value{$1} = $2;
    next;
  }
  if ($line =~ /^- Quality-HEAD: (.*)$/) {
    bad('metadata вне header') if $body_started;
    $meta{quality_head}++;
    $quality_head = $1;
    next;
  }
  if ($line =~ /^- (SPEC_DIR|Scope|Started|Updated): (.*)$/) {
    bad('metadata вне header') if $body_started;
    $meta{$1}++;
    $meta{"$1.value"} = $2;
    next;
  }
  if ($line =~ /^- Ticket: /) {
    bad('metadata вне header') if $body_started;
    $meta{Ticket}++;
    next;
  }
  if ($line =~ /^- \[([ x-])\] (stage-[A-Za-z0-9-]+)$/) {
    bad('stage anchor вне ## Stages') unless ($section // q{}) eq 'Stages';
    bad('неизвестная стадия') unless $is_stage{$2};
    $stage_ok{$2}++;
    next;
  }
  bad('битый stage anchor') if $line =~ /^- \[.*\] stage-/;
  if ($line =~ /^- (constitution-gate|user-approval|quality-verdict): (.*)$/) {
    bad('gate anchor вне ## Gates') unless ($section // q{}) eq 'Gates';
    $gate_ok{$1}++;
    $gate_ok{"$1.value"} = $2;
    next;
  }
  if ($line =~ /^- (confidence-(stage-[A-Za-z0-9-]+)): (.*)$/) {
    bad('confidence anchor вне ## Confidence') unless ($section // q{}) eq 'Confidence';
    bad('confidence неизвестной стадии') unless $is_stage{$2};
    $conf_ok{$2}++;
    $conf_ok{"$2.value"} = $3;
    next;
  }
  if ($line =~ /^- \[([ x-])\] unit:(.*)$/) {
    bad('unit anchor вне ## Units') unless ($section // q{}) eq 'Units';
    my $u = $2;
    bad('невалидное имя unit') unless $u =~ /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;
    bad('duplicate unit') if $units{$u}++;
    $unit_seen++;
    next;
  }
  bad('битый unit anchor') if $line =~ /^- \[.*\] unit:/;
  bad('контент после ## Units') if $after_units && $line ne q{};
}

my $profile;
if (!($meta{version} // 0)) {
  $profile = 'legacy';
} elsif (($version // q{}) eq '2') {
  $profile = 'v2';
} elsif (($version // q{}) eq '3') {
  $profile = 'v3';
} elsif (($version // q{}) eq '4') {
  $profile = 'v4-current';
} else {
  bad('неподдерживаемая State-Version');
}

for my $m (qw(SPEC_DIR Started Updated)) {
  bad("anchor $m не уникален") unless ($meta{$m} // 0) == 1;
}
if ($profile eq 'legacy') {
  bad('Scope дублирован') if ($meta{Scope} // 0) > 1;
  bad('невалидный legacy Scope') if ($meta{Scope} // 0) == 1
    && ($meta{'Scope.value'} // q{}) !~ /^(?:feature|bugfix|enterprise)$/;
} else {
  bad('anchor Scope не уникален') unless ($meta{Scope} // 0) == 1;
  bad('невалидный Scope') unless ($meta{'Scope.value'} // q{}) =~ /^(?:feature|bugfix|enterprise)$/;
}
bad('пустой SPEC_DIR') unless length($meta{'SPEC_DIR.value'} // q{});
bad('Ticket дублирован') if ($meta{Ticket} // 0) > 1;
bad('State-Version дублирован') if ($meta{version} // 0) > 1;
bad('## Stages не уникальна') unless ($headers{Stages} // 0) == 1;
bad('## Gates не уникальна') unless ($headers{Gates} // 0) == 1;
for my $s (@stages) {
  bad("stage $s не уникален") unless ($stage_ok{$s} // 0) == 1;
}
for my $g (@gates) {
  bad("gate $g не уникален") unless ($gate_ok{$g} // 0) == 1;
}
bad('## Units дублирована') if ($headers{Units} // 0) > 1;
bad('## Units пуста') if ($headers{Units} // 0) == 1 && !$unit_seen;

if ($profile ne 'legacy') {
  bad('Ticket не уникален') unless ($meta{Ticket} // 0) == 1;
  bad('## Confidence не уникальна') unless ($headers{Confidence} // 0) == 1;
} else {
  bad('## Confidence дублирована') if ($headers{Confidence} // 0) > 1;
}

if ($profile eq 'v4-current') {
  bad('Delivery-Contract не уникален') unless ($meta{delivery_contract} // 0) == 1;
  bad('unknown Delivery-Contract')
    unless defined($delivery_contract) && $delivery_contract eq 'architecture-evidence-v1';
  for my $root (@roots) {
    bad("$root не уникален") unless ($meta{$root} // 0) == 1;
    my $value = $root_value{$root};
    bad("невалидный $root") unless defined($value)
      && ($value eq "\x{2014}" || $value =~ /^[0-9a-f]{64}$/);
  }
} else {
  bad('Delivery-Contract допустим только в V4') if ($meta{delivery_contract} // 0) > 0;
  for my $root (@roots) {
    bad("$root допустим только в V4") if ($meta{$root} // 0) > 0;
  }
}

if ($profile eq 'v3' || $profile eq 'v4-current') {
  bad('Quality-HEAD не уникален') unless ($meta{quality_head} // 0) == 1;
  bad('невалидный Quality-HEAD') unless defined($quality_head)
    && ($quality_head eq "\x{2014}" || $quality_head =~ /^(?:[0-9a-f]{40}|[0-9a-f]{64})$/);
} else {
  bad('Quality-HEAD допустим только в V3/V4') if ($meta{quality_head} // 0) > 0;
}

if (($headers{Confidence} // 0) == 1) {
  for my $s (@stages) {
    bad("confidence $s не уникален") unless ($conf_ok{$s} // 0) == 1;
    my $v = $conf_ok{"$s.value"};
    my $ts = qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;
    my $ok = $v eq "\x{2014}" || $v =~ /^green(?: \x{2014} .+)? \($ts\)$/
      || $v =~ /^(?:yellow|red) \x{2014} .+ \($ts\)(?: \x{b7} ack: .+ \($ts\))?$/;
    bad("невалидный confidence $s") unless $ok;
  }
}

my $ts = qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;
my $cg = $gate_ok{'constitution-gate.value'};
my $ua = $gate_ok{'user-approval.value'};
my $qv = $gate_ok{'quality-verdict.value'};
if ($profile ne 'legacy') {
  bad('невалидный constitution-gate') unless $cg eq "\x{2014}"
    || $cg =~ /^MUST-FLAG: \d+ \x{b7} SHOULD-FLAG: \d+ \x{b7} NEEDS-INFO: \d+ \($ts\)$/;
  bad('невалидный quality-verdict') unless $qv eq "\x{2014}"
    || $qv =~ /^FAIL(?: \x{2014} .+)? \($ts\)$/
    || $qv =~ /^PASS \x{2014} \S.* \($ts\)$/;
} else {
  bad('невалидный legacy constitution-gate') unless $cg eq "\x{2014}"
    || $cg =~ /^(?:.* )?MUST-FLAG: \d+(?: .*)? \($ts\)$/;
  bad('невалидный legacy quality-verdict') unless $qv eq "\x{2014}"
    || $qv =~ /^(?:PASS|FAIL)(?: \x{2014} .+)? \($ts\)$/;
}
if ($profile eq 'v4-current') {
  bad('невалидный V4 user-approval') unless $ua eq "\x{2014}"
    || $ua =~ /^approved design=[0-9a-f]{64} \($ts, .+\)$/
    || $ua =~ /^approved \($ts, .+\)$/
    || $ua =~ /^(?:revise|abort) \($ts, .+\)$/;
} else {
  bad('невалидный user-approval') unless $ua eq "\x{2014}"
    || $ua =~ /^(?:approved|revise|abort) \($ts, .+\)$/;
}

my $output = $ENV{PIPELINE_STATE_OUTPUT} // q{profile};
if (!$trusted_stream) {
  my @after = stat($src);
  my @again = lstat($f);
  close($src) or bad('state.md close failed');
  bad('state.md inode/bytes изменились во время проверки') unless @after && @again
    && !S_ISLNK($again[2]) && S_ISREG($again[2]) && did(@after) eq did(@opened)
    && did(@again) eq did(@opened) && $after[7] == length($raw);
}
if ($output eq q{profile}) {
  print $profile;
} elsif ($output eq q{record} && !$trusted_stream) {
  print join(q{|}, $profile, did(@opened), sha256_hex($raw), length($raw),
    sprintf(q{%04o}, $opened[2] & 0777));
} elsif ($output eq q{raw}) {
  binmode(STDOUT);
  print $raw;
} else {
  bad('невалидный internal output mode');
}
