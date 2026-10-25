#!/usr/bin/env perl
# context-budget.pl — portable context guard + tokens/resolved-ticket evolution metric.
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(:DEFAULT :flock O_NOFOLLOW S_ISREG);
use File::Basename qw(dirname);
use File::Spec;
use Getopt::Long qw(GetOptionsFromArray);
use JSON::PP;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

sub fatal {
  my ($message, $code) = @_;
  $code //= 2;
  print STDERR "context-budget: $message\n";
  exit $code;
}

sub valid_uint {
  my ($value, $positive) = @_;
  return 0 if !defined($value) || $value !~ /\A\d{1,15}\z/;
  return 0 if $positive && $value == 0;
  return 1;
}

sub valid_atom {
  my ($value) = @_;
  return defined($value) && $value =~ /\A[A-Za-z0-9][A-Za-z0-9._:+\@-]{0,127}\z/;
}

sub valid_model {
  my ($value) = @_;
  return defined($value) && length($value) <= 192
    && $value =~ /\A[A-Za-z0-9][A-Za-z0-9._:+\@\/-]*\z/
    && $value !~ m{(?:\A|/)\.{1,2}(?:/|\z)};
}

sub valid_ticket {
  my ($value) = @_;
  return defined($value)
    && length($value) <= 512
    && $value =~ /\A[A-Za-z][A-Za-z0-9_-]*:[^\x00-\x20\x7f]+\z/;
}

sub valid_timestamp {
  my ($value) = @_;
  return defined($value)
    && $value =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;
}

sub now_utc {
  my @g = gmtime(time);
  return sprintf('%04d-%02d-%02dT%02d:%02d:%02dZ',
    $g[5] + 1900, $g[4] + 1, $g[3], $g[2], $g[1], $g[0]);
}

sub command_output {
  my (@argv) = @_;
  local %ENV = %ENV;
  delete @ENV{grep { /^GIT_/ } keys %ENV};
  $ENV{GIT_CONFIG_NOSYSTEM} = 1;
  $ENV{GIT_CONFIG_SYSTEM} = '/dev/null';
  $ENV{GIT_CONFIG_GLOBAL} = '/dev/null';
  $ENV{GIT_CONFIG_COUNT} = 0;
  open(my $fh, '-|', @argv) or return;
  my $out = do { local $/; <$fh> };
  close($fh) or return;
  $out //= '';
  $out =~ s/[\r\n]+\z//;
  return $out;
}

sub repo_root {
  my $root = command_output('git', 'rev-parse', '--show-toplevel');
  fatal('not inside a Git repository') if !defined($root) || $root eq '';
  return File::Spec->rel2abs($root);
}

sub default_harness_revision {
  return $ENV{HARNESS_REVISION} if valid_atom($ENV{HARNESS_REVISION});
  my $root = repo_root();
  my $revision = command_output('git', '-C', $root, 'rev-parse', '--short=12', 'HEAD') // '';
  fatal('cannot determine harness revision; pass --harness') if !valid_atom($revision);
  return $revision;
}

sub default_ledger {
  return $ENV{HARNESS_TOKEN_LEDGER} if defined($ENV{HARNESS_TOKEN_LEDGER}) && length($ENV{HARNESS_TOKEN_LEDGER});
  my $root = repo_root();
  my $common = command_output('git', '-C', $root, 'rev-parse', '--git-common-dir');
  fatal('cannot resolve canonical git dir') if !defined($common) || $common eq '';
  $common = File::Spec->rel2abs($common, $root) if !File::Spec->file_name_is_absolute($common);
  return File::Spec->catfile($common, 'agent-harness', 'token-efficiency.jsonl');
}

sub ensure_parent {
  my ($path) = @_;
  my $parent = dirname($path);
  return if -d $parent && !-l $parent;
  my $grand = dirname($parent);
  fatal('ledger parent is unavailable') if !-d $grand || -l $grand;
  mkdir($parent, 0700) or fatal('cannot create private ledger directory');
}

sub open_ledger {
  my ($path, $write) = @_;
  ensure_parent($path) if $write;
  my $flags = $write ? O_RDWR | O_APPEND | O_CREAT : O_RDONLY;
  $flags |= O_NOFOLLOW if defined(&O_NOFOLLOW);
  sysopen(my $fh, $path, $flags, 0600) or do {
    return if !$write && !-e $path;
    fatal('cannot open ledger');
  };
  my @opened = stat($fh);
  my @named = lstat($path);
  fatal('ledger identity/type rejected')
    if !@opened || !@named || !S_ISREG($opened[2]) || !S_ISREG($named[2])
      || $opened[0] != $named[0] || $opened[1] != $named[1]
      || $opened[3] != 1 || $opened[4] != $<;
  if ($write) {
    chmod(0600, $fh) or fatal('cannot set private ledger mode');
    flock($fh, LOCK_EX) or fatal('cannot lock ledger');
  } else {
    flock($fh, LOCK_SH) or fatal('cannot lock ledger');
  }
  return $fh;
}

my $json = JSON::PP->new->utf8->canonical(1);

sub read_events_from_fh {
  my ($fh) = @_;
  return () if !defined($fh);
  sysseek($fh, 0, 0) >= 0 or fatal('cannot seek ledger');
  my @events;
  my %ids;
  while (my $line = <$fh>) {
    fatal('ledger has an incomplete final record') if $line !~ /\n\z/;
    my $event = eval { $json->decode($line) };
    fatal('ledger contains invalid JSON') if ref($event) ne 'HASH';
    fatal('ledger schema mismatch')
      if ($event->{v} // 0) != 1 || !valid_atom($event->{event_id})
        || ($event->{type} // '') !~ /\A(?:usage|resolved)\z/;
    my $key = "$event->{type}:$event->{event_id}";
    my $canonical = $json->encode($event);
    if (exists $ids{$key}) {
      fatal('ledger contains conflicting duplicate event') if $ids{$key} ne $canonical;
      next;
    }
    $ids{$key} = $canonical;
    push @events, $event;
  }
  return @events;
}

sub append_event {
  my ($ledger, $event) = @_;
  my $fh = open_ledger($ledger, 1);
  my @events = read_events_from_fh($fh);
  my $key = "$event->{type}:$event->{event_id}";
  my $encoded = $json->encode($event);
  for my $existing (@events) {
    next unless "$existing->{type}:$existing->{event_id}" eq $key;
    if ($json->encode($existing) eq $encoded) {
      close($fh) or fatal('cannot close ledger');
      print "record=idempotent\n";
      return;
    }
    close($fh);
    fatal('event id already exists with different data', 3);
  }
  my $record = $encoded . "\n";
  my $offset = 0;
  while ($offset < length($record)) {
    my $written = syswrite($fh, $record, length($record) - $offset, $offset);
    fatal('cannot append ledger') if !defined($written) || $written == 0;
    $offset += $written;
  }
  close($fh) or fatal('cannot close ledger');
  print "record=appended\n";
}

sub take_global_ledger {
  my ($argv) = @_;
  my $ledger = '';
  for (my $i = 0; $i < @$argv; $i++) {
    next unless $argv->[$i] eq '--ledger';
    fatal('--ledger requires a path') if $i + 1 >= @$argv;
    fatal('--ledger specified more than once') if length($ledger);
    $ledger = $argv->[$i + 1];
    splice(@$argv, $i, 2);
    $i--;
  }
  $ledger ||= default_ledger();
  fatal('ledger path contains NUL') if $ledger =~ /\x00/;
  return File::Spec->rel2abs($ledger);
}

sub run_budget {
  my ($argv) = @_;
  my ($limit, $used, $telemetry, $enforce) = ('', '', '', 0);
  GetOptionsFromArray($argv,
    'limit=s' => \$limit, 'used=s' => \$used, 'telemetry=s' => \$telemetry,
    'enforce' => \$enforce) or fatal('invalid budget options');
  fatal('unexpected budget arguments') if @$argv;
  fatal('invalid --limit') if !valid_uint($limit, 1);
  fatal('invalid --used') if !valid_uint($used, 0);
  fatal('invalid --telemetry') if $telemetry !~ /\A(?:exact|estimated)\z/;
  my $percent = $used * 100 / $limit;
  my $state = $percent >= 100 ? 'EXHAUSTED'
    : $percent >= 75 ? 'HANDOFF'
    : $percent >= 50 ? 'FREEZE'
    : $percent >= 30 ? 'CHECKPOINT' : 'NORMAL';
  my $remaining = $used >= $limit ? 0 : $limit - $used;
  printf "schema=context-budget/v1\nstate=%s\ntelemetry=%s\nused=%s\nlimit=%s\nremaining=%s\npercent=%.2f\n",
    $state, uc($telemetry), $used, $limit, $remaining, $percent;
  exit 4 if $enforce && ($state eq 'HANDOFF' || $state eq 'EXHAUSTED');
  exit 0;
}

sub run_record_usage {
  my ($ledger, $argv) = @_;
  my %o = (cached_input => 0, at => now_utc());
  GetOptionsFromArray($argv,
    'ticket=s' => \$o{ticket}, 'attempt=s' => \$o{attempt}, 'class=s' => \$o{class},
    'runtime=s' => \$o{runtime}, 'model=s' => \$o{model}, 'harness=s' => \$o{harness},
    'input=s' => \$o{input}, 'output=s' => \$o{output},
    'cached-input=s' => \$o{cached_input}, 'at=s' => \$o{at})
    or fatal('invalid record-usage options');
  fatal('unexpected record-usage arguments') if @$argv;
  $o{harness} ||= default_harness_revision();
  fatal('invalid ticket; use a namespaced id such as github:owner/repo#1 or spec:NNN-slug')
    if !valid_ticket($o{ticket});
  fatal('invalid attempt') if !valid_atom($o{attempt});
  fatal('invalid task class') if ($o{class} // '') !~ /\A(?:bug|feature|docs|ops|other)\z/;
  fatal('invalid runtime') if !valid_atom($o{runtime});
  fatal('invalid model') if !valid_model($o{model});
  fatal('invalid harness revision') if !valid_atom($o{harness});
  fatal('invalid token counters')
    if !valid_uint($o{input}, 0) || !valid_uint($o{output}, 0)
      || !valid_uint($o{cached_input}, 0) || $o{cached_input} > $o{input};
  fatal('invalid timestamp') if !valid_timestamp($o{at});
  append_event($ledger, {
    v => 1, type => 'usage', event_id => $o{attempt},
    ticket_hash => sha256_hex("harness-ticket-v1\0$o{ticket}"),
    task_class => $o{class}, runtime => lc($o{runtime}), model => $o{model},
    harness => $o{harness}, input_tokens => 0 + $o{input}, output_tokens => 0 + $o{output},
    cached_input_tokens => 0 + $o{cached_input}, at => $o{at},
  });
}

sub run_resolve {
  my ($ledger, $argv) = @_;
  my %o = (at => now_utc());
  GetOptionsFromArray($argv,
    'ticket=s' => \$o{ticket}, 'resolution=s' => \$o{resolution},
    'harness=s' => \$o{harness}, 'at=s' => \$o{at})
    or fatal('invalid resolve options');
  fatal('unexpected resolve arguments') if @$argv;
  $o{harness} ||= default_harness_revision();
  fatal('invalid ticket') if !valid_ticket($o{ticket});
  fatal('invalid resolution') if !valid_atom($o{resolution});
  fatal('invalid harness revision') if !valid_atom($o{harness});
  fatal('invalid timestamp') if !valid_timestamp($o{at});
  append_event($ledger, {
    v => 1, type => 'resolved', event_id => $o{resolution},
    ticket_hash => sha256_hex("harness-ticket-v1\0$o{ticket}"),
    harness => $o{harness}, at => $o{at},
  });
}

sub usage_from_stream {
  my ($runtime, $fallback_model, $fh) = @_;
  my $best;
  my $seen_model = $fallback_model;
  while (my $line = <$fh>) {
    next if length($line) > 10 * 1024 * 1024;
    my $object = eval { $json->decode($line) };
    next if ref($object) ne 'HASH';
    for my $candidate ($object->{model},
      ref($object->{message}) eq 'HASH' ? $object->{message}{model} : undef) {
      $seen_model = $candidate if valid_model($candidate);
    }
    my @usage_candidates;
    push @usage_candidates, $object->{usage} if ref($object->{usage}) eq 'HASH';
    push @usage_candidates, $object->{token_usage} if ref($object->{token_usage}) eq 'HASH';
    if (ref($object->{payload}) eq 'HASH') {
      push @usage_candidates, $object->{payload}{usage} if ref($object->{payload}{usage}) eq 'HASH';
    }
    for my $usage (@usage_candidates) {
      my $input = $usage->{input_tokens};
      $input = $usage->{prompt_tokens} if !defined($input);
      my $output = $usage->{output_tokens};
      $output = $usage->{completion_tokens} if !defined($output);
      next if !valid_uint($input, 0) || !valid_uint($output, 0);
      my $cached = 0;
      my $creation = 0;
      if ($runtime eq 'claude') {
        $cached = $usage->{cache_read_input_tokens} // 0;
        $creation = $usage->{cache_creation_input_tokens} // 0;
        next if !valid_uint($cached, 0) || !valid_uint($creation, 0);
        $input += $cached + $creation;
        $cached += $creation;
      } else {
        $cached = $usage->{cached_input_tokens} // 0;
        if (ref($usage->{input_tokens_details}) eq 'HASH') {
          $cached = $usage->{input_tokens_details}{cached_tokens}
            if defined($usage->{input_tokens_details}{cached_tokens});
        }
        next if !valid_uint($cached, 0) || $cached > $input;
      }
      my $total = $input + $output;
      $best = { input => 0 + $input, output => 0 + $output, cached => 0 + $cached,
        model => $seen_model, total => $total }
        if !defined($best) || $total >= $best->{total};
    }
  }
  fatal('provider stream has no supported usage receipt') if !defined($best);
  $best->{model} = $fallback_model if !valid_model($best->{model});
  return $best;
}

sub run_parse_usage {
  my ($argv) = @_;
  my ($runtime, $model) = ('', '');
  GetOptionsFromArray($argv, 'runtime=s' => \$runtime, 'model=s' => \$model)
    or fatal('invalid parse-usage options');
  fatal('unexpected parse-usage arguments') if @$argv;
  fatal('invalid runtime') if $runtime !~ /\A(?:claude|codex)\z/;
  fatal('invalid fallback model') if !valid_model($model);
  my $usage = usage_from_stream($runtime, $model, *STDIN);
  print "schema=provider-usage/v1\n";
  print "input=$usage->{input}\noutput=$usage->{output}\ncached_input=$usage->{cached}\nmodel=$usage->{model}\n";
}

sub run_ingest_jsonl {
  my ($ledger, $argv) = @_;
  my %o = (at => now_utc());
  GetOptionsFromArray($argv,
    'ticket=s' => \$o{ticket}, 'attempt=s' => \$o{attempt}, 'class=s' => \$o{class},
    'runtime=s' => \$o{runtime}, 'model=s' => \$o{model}, 'harness=s' => \$o{harness},
    'at=s' => \$o{at}) or fatal('invalid ingest-jsonl options');
  fatal('unexpected ingest-jsonl arguments') if @$argv;
  $o{harness} ||= default_harness_revision();
  fatal('invalid ticket') if !valid_ticket($o{ticket});
  fatal('invalid attempt') if !valid_atom($o{attempt});
  fatal('invalid task class') if ($o{class} // '') !~ /\A(?:bug|feature|docs|ops|other)\z/;
  fatal('invalid runtime') if ($o{runtime} // '') !~ /\A(?:claude|codex)\z/;
  fatal('invalid fallback model') if !valid_model($o{model});
  fatal('invalid harness revision') if !valid_atom($o{harness});
  fatal('invalid timestamp') if !valid_timestamp($o{at});
  my $usage = usage_from_stream($o{runtime}, $o{model}, *STDIN);
  append_event($ledger, {
    v => 1, type => 'usage', event_id => $o{attempt},
    ticket_hash => sha256_hex("harness-ticket-v1\0$o{ticket}"),
    task_class => $o{class}, runtime => $o{runtime}, model => $usage->{model},
    harness => $o{harness}, input_tokens => $usage->{input}, output_tokens => $usage->{output},
    cached_input_tokens => $usage->{cached}, at => $o{at},
  });
}

sub mean {
  my (@values) = @_;
  return 0 if !@values;
  my $sum = 0; $sum += $_ for @values;
  return $sum / @values;
}

sub median {
  my (@values) = sort { $a <=> $b } @_;
  return 0 if !@values;
  return $values[int(@values / 2)] if @values % 2;
  return ($values[@values / 2 - 1] + $values[@values / 2]) / 2;
}

sub fmt_number {
  my ($value) = @_;
  my $out = sprintf('%.2f', $value);
  $out =~ s/\.00\z//;
  $out =~ s/(\.\d)0\z/$1/;
  return $out;
}

sub build_report {
  my ($ledger, $min_sample, $threshold) = @_;
  my $fh = open_ledger($ledger, 0);
  my @events = read_events_from_fh($fh);
  close($fh) if defined($fh);
  my (%usage, %resolved);
  for my $event (@events) {
    my $ticket = $event->{ticket_hash} // '';
    next if $ticket !~ /\A[0-9a-f]{64}\z/;
    if ($event->{type} eq 'usage') {
      next if !valid_uint($event->{input_tokens}, 0) || !valid_uint($event->{output_tokens}, 0)
        || !valid_uint($event->{cached_input_tokens}, 0)
        || $event->{cached_input_tokens} > $event->{input_tokens}
        || !valid_timestamp($event->{at}) || !valid_atom($event->{harness})
        || ($event->{task_class} // '') !~ /\A(?:bug|feature|docs|ops|other)\z/
        || !valid_atom($event->{runtime}) || !valid_model($event->{model});
      push @{$usage{$ticket}}, $event;
    } elsif ($event->{type} eq 'resolved') {
      next if !valid_timestamp($event->{at}) || !valid_atom($event->{harness});
      $resolved{$ticket} = $event
        if !exists($resolved{$ticket}) || $event->{at} gt $resolved{$ticket}{at};
    }
  }

  my (@tickets, %harness_latest);
  for my $ticket (keys %resolved) {
    my $resolution = $resolved{$ticket};
    my @attempts = grep { $_->{at} le $resolution->{at} } @{$usage{$ticket} // []};
    next if !@attempts;
    my $total = 0; $total += $_->{input_tokens} + $_->{output_tokens} for @attempts;
    my %classes = map { $_->{task_class} => 1 } @attempts;
    my %runtimes = map { $_->{runtime} => 1 } @attempts;
    my %models = map { $_->{model} => 1 } @attempts;
    my $class = keys(%classes) == 1 ? (keys %classes)[0] : 'mixed';
    my $runtime = keys(%runtimes) == 1 ? (keys %runtimes)[0] : 'mixed';
    my $model = keys(%models) == 1 ? (keys %models)[0] : 'mixed';
    my $harness = $resolution->{harness};
    push @tickets, { total => $total, class => $class, runtime => $runtime,
      model => $model, harness => $harness, at => $resolution->{at} };
    $harness_latest{$harness} = $resolution->{at}
      if !exists($harness_latest{$harness}) || $resolution->{at} gt $harness_latest{$harness};
  }

  my @harnesses = sort {
    $harness_latest{$a} cmp $harness_latest{$b} || $a cmp $b
  } keys %harness_latest;
  my $latest = @harnesses ? $harnesses[-1] : '';
  my $baseline = @harnesses >= 2 ? $harnesses[-2] : '';
  my @latest_values = map { $_->{total} } grep { $_->{harness} eq $latest } @tickets;
  my @baseline_values = map { $_->{total} } grep { length($baseline) && $_->{harness} eq $baseline } @tickets;
  my $latest_avg = mean(@latest_values);
  my $baseline_avg = mean(@baseline_values);
  my $delta = $baseline_avg > 0 ? ($latest_avg - $baseline_avg) * 100 / $baseline_avg : undef;

  my (%groups, @group_rows);
  for my $ticket (@tickets) {
    my $key = join("\0", @{$ticket}{qw(class runtime model)});
    push @{$groups{$key}{$ticket->{harness}}}, $ticket->{total};
  }
  my ($red_flags, $comparable) = (0, 0);
  if (length($latest) && length($baseline)) {
    for my $key (sort keys %groups) {
      my @current = @{$groups{$key}{$latest} // []};
      my @prior = @{$groups{$key}{$baseline} // []};
      next if !@current || !@prior;
      my ($class, $runtime, $model) = split(/\0/, $key, -1);
      my ($cur_avg, $prior_avg) = (mean(@current), mean(@prior));
      my $group_delta = $prior_avg > 0 ? ($cur_avg - $prior_avg) * 100 / $prior_avg : undef;
      my $state = 'WARMUP';
      if (@current >= $min_sample && @prior >= $min_sample) {
        $comparable++;
        $state = defined($group_delta) && $group_delta > $threshold ? 'RED' : 'GREEN';
        $red_flags++ if $state eq 'RED';
      }
      push @group_rows, {
        state => $state, class => $class, runtime => $runtime, model => $model,
        baseline_n => scalar(@prior), latest_n => scalar(@current),
        baseline_avg => $prior_avg, latest_avg => $cur_avg, delta => $group_delta,
      };
    }
  }
  my $status = $red_flags ? 'RED' : $comparable ? 'GREEN' : 'WARMUP';
  return {
    status => $status, latest => $latest, baseline => $baseline,
    latest_values => \@latest_values, baseline_values => \@baseline_values,
    latest_avg => $latest_avg, baseline_avg => $baseline_avg, delta => $delta,
    red_flags => $red_flags, comparable => $comparable, groups => \@group_rows,
    resolved_tickets => scalar(@tickets), min_sample => $min_sample, threshold => $threshold,
  };
}

sub emit_report {
  my ($report) = @_;
  print "schema=token-efficiency/v1\n";
  print "status=$report->{status}\n";
  print "threshold_pct=" . fmt_number($report->{threshold}) . "\n";
  print "min_sample=$report->{min_sample}\n";
  print "resolved_tickets=$report->{resolved_tickets}\n";
  print "latest_harness=" . ($report->{latest} || '-') . "\n";
  print "baseline_harness=" . ($report->{baseline} || '-') . "\n";
  print "latest_resolved=" . scalar(@{$report->{latest_values}}) . "\n";
  print "baseline_resolved=" . scalar(@{$report->{baseline_values}}) . "\n";
  print "latest_avg_tokens=" . fmt_number($report->{latest_avg}) . "\n";
  print "baseline_avg_tokens=" . fmt_number($report->{baseline_avg}) . "\n";
  print "latest_median_tokens=" . fmt_number(median(@{$report->{latest_values}})) . "\n";
  print "baseline_median_tokens=" . fmt_number(median(@{$report->{baseline_values}})) . "\n";
  print "delta_pct=" . (defined($report->{delta}) ? sprintf('%.2f', $report->{delta}) : 'NA') . "\n";
  print "red_flags=$report->{red_flags}\n";
  print "comparable_groups=$report->{comparable}\n";
  for my $group (@{$report->{groups}}) {
    print join(' ',
      "group_status=$group->{state}", "class=$group->{class}", "runtime=$group->{runtime}",
      "model=$group->{model}", "baseline_n=$group->{baseline_n}", "latest_n=$group->{latest_n}",
      "baseline_avg=" . fmt_number($group->{baseline_avg}),
      "latest_avg=" . fmt_number($group->{latest_avg}),
      "delta_pct=" . (defined($group->{delta}) ? sprintf('%.2f', $group->{delta}) : 'NA')) . "\n";
  }
}

sub run_report {
  my ($ledger, $argv, $gate) = @_;
  my ($min_sample, $threshold) = (5, 15);
  GetOptionsFromArray($argv, 'min-sample=s' => \$min_sample, 'threshold-pct=s' => \$threshold)
    or fatal('invalid report options');
  fatal('unexpected report arguments') if @$argv;
  fatal('invalid --min-sample') if !valid_uint($min_sample, 1) || $min_sample > 100000;
  fatal('invalid --threshold-pct')
    if !defined($threshold) || $threshold !~ /\A\d{1,3}(?:\.\d{1,2})?\z/ || $threshold > 999;
  my $report = build_report($ledger, 0 + $min_sample, 0 + $threshold);
  emit_report($report);
  exit 4 if $gate && $report->{status} eq 'RED';
  exit 0;
}

my @args = @ARGV;
my $ledger = take_global_ledger(\@args);
my $command = shift(@args) // '';
if ($command eq 'budget') { run_budget(\@args); }
elsif ($command eq 'record-usage') { run_record_usage($ledger, \@args); }
elsif ($command eq 'parse-usage') { run_parse_usage(\@args); }
elsif ($command eq 'ingest-jsonl') { run_ingest_jsonl($ledger, \@args); }
elsif ($command eq 'resolve') { run_resolve($ledger, \@args); }
elsif ($command eq 'report') { run_report($ledger, \@args, 0); }
elsif ($command eq 'check') { run_report($ledger, \@args, 1); }
else {
  fatal('usage: context-budget.pl [--ledger PATH] <budget|record-usage|parse-usage|ingest-jsonl|resolve|report|check> ...');
}
