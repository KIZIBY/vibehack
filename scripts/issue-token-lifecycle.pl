#!/usr/bin/env perl
# issue-token-lifecycle.pl — verified issue lifecycle bridge for token-efficiency metrics.
#
# Backend задач (единое правило харнесса): env ISSUE_BACKEND → первая строка PROJECT.md, начинающаяся
# с `ISSUE_BACKEND=` (обязана точно совпасть с `^ISSUE_BACKEND=(github|none)\s*$`) → `none`.
# Неизвестное значение → exit 2 (fail closed). `--backend` может только повторять результат.
#   github — identity `github:<owner>/<repo>#<n>`; репозиторий ВСЕГДА из canonical origin
#            (github.com); `--repo` и env GH_REPO могут только точно повторять его.
#   none   — внешнего трекера нет: usage-мост принимает `--ticket NNN-slug` (или specs/NNN-slug)
#            → identity `spec:NNN-slug`; close/sync → typed BLOCKED (exit 4): закрывать нечего.
use strict;
use warnings;
use utf8;
use Digest::SHA qw(sha256_hex);
use Errno qw(ENOENT);
use Fcntl qw(:mode);
use File::Basename qw(dirname);
use File::Spec;
use FindBin qw($Bin);
use Getopt::Long qw(GetOptionsFromArray);
use IPC::Open3 qw(open3);
use JSON::PP;

binmode STDOUT, ':encoding(UTF-8)';
binmode STDERR, ':encoding(UTF-8)';

sub fatal {
  my ($message, $code) = @_;
  $code //= 2;
  print STDERR "issue-token-lifecycle: $message\n";
  exit $code;
}

sub valid_timestamp {
  my ($value) = @_;
  return defined($value)
    && $value =~ /\A\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z\z/;
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

sub project_issue_backend {
  my ($root) = @_;
  my $path = File::Spec->catfile($root, 'PROJECT.md');
  my @named = lstat($path);
  if (!@named) {
    fatal('PROJECT.md is unreadable') if !$!{ENOENT};
    return 'none';
  }
  fatal('PROJECT.md must be one regular non-symlink file')
    if S_ISLNK($named[2]) || !S_ISREG($named[2]) || $named[7] > 1048576;
  open(my $fh, '<:raw', $path) or fatal('cannot read PROJECT.md');
  my $raw = do { local $/; <$fh> } // '';
  close($fh) or fatal('cannot close PROJECT.md');
  for my $line (split /\n/, $raw) {
    $line =~ s/\r\z//;
    next if $line !~ /\AISSUE_BACKEND=/;
    return $1 if $line =~ /\AISSUE_BACKEND=(github|none)\s*\z/;
    fatal('invalid ISSUE_BACKEND declaration in PROJECT.md');
  }
  return 'none';
}

sub origin_github_repo {
  my $url = command_output('git', 'config', '--local', '--no-includes', '--get', 'remote.origin.url') // '';
  my $repo = '';
  if ($url =~ m{\Ahttps://github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?\z}
      || $url =~ m{\Agit\@github\.com:([^/\s]+/[^/\s]+?)(?:\.git)?\z}
      || $url =~ m{\Assh://git\@github\.com/([^/\s]+/[^/\s]+?)(?:\.git)?/?\z}) {
    $repo = $1;
  }
  fatal('github backend requires a github.com origin remote')
    if $repo !~ /\A[A-Za-z0-9_.-]+\/[A-Za-z0-9_.-]+\z/;
  return $repo;
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
  fatal('ledger path contains NUL') if $ledger =~ /\x00/;
  return length($ledger) ? File::Spec->rel2abs($ledger) : '';
}

sub common_options {
  my ($argv, $need_comment) = @_;
  my %o;
  GetOptionsFromArray($argv,
    'backend=s' => \$o{backend}, 'repo=s' => \$o{repo},
    'ticket=s' => \$o{ticket}, 'comment=s' => \$o{comment},
    'harness=s' => \$o{harness}) or fatal('invalid lifecycle options');
  fatal('unexpected lifecycle arguments') if @$argv;
  fatal('missing --ticket') if !defined($o{ticket}) || $o{ticket} eq '';
  fatal('invalid comment') if $need_comment
    && (!defined($o{comment}) || $o{comment} eq '' || length($o{comment}) > 2000
      || $o{comment} =~ /[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]/);
  return \%o;
}

sub effective_backend {
  my ($o, $root) = @_;
  my $backend;
  if (defined($ENV{ISSUE_BACKEND})) {
    fatal('invalid issue backend') if $ENV{ISSUE_BACKEND} !~ /\A(?:github|none)\z/;
    $backend = $ENV{ISSUE_BACKEND};
  } else {
    $backend = project_issue_backend($root);
  }
  if (defined($o->{backend})) {
    fatal('invalid issue backend') if $o->{backend} !~ /\A(?:github|none)\z/;
    fatal('--backend conflicts with the resolved ISSUE_BACKEND (env or PROJECT.md)')
      if $o->{backend} ne $backend;
  }
  return $backend;
}

sub github_identity {
  my ($o) = @_;
  my $repo = origin_github_repo();
  for my $pin ([ '--repo', $o->{repo} ], [ 'GH_REPO', $ENV{GH_REPO} ]) {
    my ($name, $value) = @$pin;
    next if !defined($value);
    (my $normalized = $value) =~ s{\Agithub\.com/}{};
    fatal("$name may only repeat the origin repository") if $normalized ne $repo;
  }
  my $ticket = $o->{ticket};
  $ticket =~ s/\A#//;
  fatal('invalid GitHub issue number') if $ticket !~ /\A[1-9][0-9]{0,9}\z/;
  return ($repo, 0 + $ticket, "github:$repo#$ticket");
}

sub spec_identity {
  my ($o) = @_;
  fatal('--repo is meaningless with ISSUE_BACKEND=none') if defined($o->{repo});
  my $ticket = $o->{ticket} // '';
  $ticket =~ s{\Aspecs/}{};
  fatal('ISSUE_BACKEND=none expects --ticket NNN-slug (spec directory)')
    if $ticket !~ /\A[0-9]{3}-[a-z0-9][a-z0-9-]{0,120}\z/;
  return "spec:$ticket";
}

sub capture_command {
  my (@argv) = @_;
  open(my $null, '>', File::Spec->devnull()) or fatal('cannot open null sink');
  my ($out, $pid);
  eval { $pid = open3(undef, $out, $null, @argv); 1 }
    or return (127, '');
  binmode($out, ':raw');
  my $body = '';
  while (1) {
    my $n = sysread($out, my $chunk, 65536);
    last if defined($n) && $n == 0;
    if (!defined($n)) { waitpid($pid, 0); return (127, ''); }
    $body .= $chunk;
    if (length($body) > 1024 * 1024) {
      close($out);
      waitpid($pid, 0);
      return (126, '');
    }
  }
  close($out);
  waitpid($pid, 0);
  my $rc = $? == -1 ? 127 : $? & 127 ? 128 + ($? & 127) : $? >> 8;
  return ($rc, $body);
}

my $json = JSON::PP->new->utf8;

sub decode_object {
  my ($raw) = @_;
  my $object = eval { $json->decode($raw) };
  return ref($object) eq 'HASH' ? $object : undef;
}

sub context_exec {
  my ($ledger, @argv) = @_;
  my $script = File::Spec->catfile($Bin, 'context-budget.pl');
  fatal('context-budget.pl is unavailable') if !-f $script;
  my @command = ($^X, $script);
  push @command, '--ledger', $ledger if length($ledger);
  push @command, @argv;
  exec {$^X} @command or fatal('cannot execute context-budget.pl');
}

sub context_resolve {
  my ($ledger, $ticket, $resolution, $at, $harness) = @_;
  my $script = File::Spec->catfile($Bin, 'context-budget.pl');
  my @command = ($^X, $script);
  push @command, '--ledger', $ledger if length($ledger);
  push @command, 'resolve', '--ticket', $ticket, '--resolution', $resolution, '--at', $at;
  push @command, '--harness', $harness if defined($harness) && length($harness);
  system {$^X} @command;
  my $rc = $? == -1 ? 127 : $? & 127 ? 128 + ($? & 127) : $? >> 8;
  fatal('token ledger rejected verified resolution', $rc == 3 ? 3 : 4) if $rc != 0;
}

sub github_verified_close {
  my ($mutate, $o) = @_;
  my ($repo, $number, $ticket) = github_identity($o);
  if ($mutate) {
    my ($rc) = capture_command('gh', 'issue', 'close', $number, '--repo', $repo,
      '--comment', $o->{comment});
    fatal('BLOCKED: github-close-failed', 4) if $rc != 0;
  }
  my ($rc, $raw) = capture_command('gh', 'issue', 'view', $number, '--repo', $repo,
    '--json', 'number,state,closedAt');
  fatal('BLOCKED: github-verify-unavailable', 4) if $rc != 0;
  my $view = decode_object($raw);
  fatal('BLOCKED: github-verify-invalid', 4) if !defined($view)
    || ($view->{number} // 0) != $number || ($view->{state} // '') ne 'CLOSED';
  my $at = $view->{closedAt};
  fatal('BLOCKED: github-close-timestamp-unavailable', 4) if !valid_timestamp($at);
  return ($ticket, $at);
}

sub run_usage_bridge {
  my ($command, $ledger, $root, $argv) = @_;
  my %o = (cached_input => 0);
  GetOptionsFromArray($argv,
    'backend=s' => \$o{backend}, 'repo=s' => \$o{repo},
    'ticket=s' => \$o{ticket}, 'attempt=s' => \$o{attempt}, 'class=s' => \$o{class},
    'runtime=s' => \$o{runtime}, 'model=s' => \$o{model}, 'harness=s' => \$o{harness},
    'input=s' => \$o{input}, 'output=s' => \$o{output},
    'cached-input=s' => \$o{cached_input}, 'at=s' => \$o{at})
    or fatal('invalid usage bridge options');
  fatal('unexpected usage bridge arguments') if @$argv;
  fatal('missing --ticket') if !defined($o{ticket}) || $o{ticket} eq '';
  my $backend = effective_backend(\%o, $root);
  my $ticket = $backend eq 'github' ? (github_identity(\%o))[2] : spec_identity(\%o);
  my @forward = ($command, '--ticket', $ticket, '--attempt', $o{attempt} // '',
    '--class', $o{class} // '', '--runtime', $o{runtime} // '', '--model', $o{model} // '');
  push @forward, '--harness', $o{harness} if defined($o{harness}) && length($o{harness});
  push @forward, '--at', $o{at} if defined($o{at}) && length($o{at});
  if ($command eq 'record-usage') {
    push @forward, '--input', $o{input} // '', '--output', $o{output} // '',
      '--cached-input', $o{cached_input};
  }
  context_exec($ledger, @forward);
}

my @args = @ARGV;
my $ledger = take_global_ledger(\@args);
my $command = shift(@args) // '';
my $root = repo_root();

if ($command eq 'ingest-jsonl' || $command eq 'record-usage') {
  run_usage_bridge($command, $ledger, $root, \@args);
} elsif ($command eq 'close' || $command eq 'sync') {
  my $o = common_options(\@args, $command eq 'close');
  my $backend = effective_backend($o, $root);
  fatal('BLOCKED: issue-backend-none — внешнего тикета нет; resolution по спеке пишется '
    . 'через context-budget.pl resolve --ticket spec:NNN-slug', 4) if $backend eq 'none';
  my ($ticket, $at) = github_verified_close($command eq 'close', $o);
  my $resolution = 'issue-close-' . substr(sha256_hex("$ticket\0$at"), 0, 40);
  context_resolve($ledger, $ticket, $resolution, $at, $o->{harness});
  print "backend=$backend\nmetric=resolved\n";
} else {
  fatal('usage: issue-token-lifecycle.pl [--ledger PATH] <ingest-jsonl|record-usage|close|sync> ...');
}
