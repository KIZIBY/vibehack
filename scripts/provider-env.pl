#!/usr/bin/env perl
# provider-env.pl — shared fail-closed environment boundary for the GitHub issue-provider CLI (gh).
#
# Usage:
#   perl provider-env.pl github <private-root> <private-root-id> <test-copy-mode:0|1>
#     <pinned-secret-regex> -- <command> [args...]
#
# Consumers pin this source before execution and pass the identity returned by private-temp-dir.pl.
# The verified directory becomes cwd and HOME/TMPDIR are cwd-relative.  They therefore keep resolving
# to the pinned inode even if a same-UID actor replaces the original pathname before the post-call
# guard. Production consumers always pass test-copy-mode=0; repository tests execute mechanically
# patched private copies with the bit fixed to 1, so no ambient production switch exists.
use strict;
use warnings;
use Fcntl qw(O_RDONLY O_DIRECTORY O_NOFOLLOW S_ISDIR S_ISLNK);
use POSIX ();

sub fail { exit 125 }
sub oid { my (@s)=@_; return $s[0].q{:}.$s[1] }

my ($backend,$private_root,$private_id,$test_enabled,$secret_pattern,$separator,@command)=@ARGV;
fail() unless defined($backend) && $backend eq q{github}
  && defined($private_root) && $private_root =~ m{\A/} && $private_root !~ /[\x00-\x1f\x7f]/
  && defined($private_id)
  && $private_id =~ /\A([0-9]+:[0-9]+)\|([0-9]+:[0-9]+)\z/
  && defined($test_enabled) && ($test_enabled eq q{0} || $test_enabled eq q{1})
  && defined($secret_pattern) && length($secret_pattern) && length($secret_pattern)<=1048576
  && $secret_pattern !~ /[\x00-\x1f\x7f]/
  && defined($separator) && $separator eq q{--} && @command;
my ($parent_want,$root_want)=split /\|/,$private_id,2;
my $secret_re=eval { qr/$secret_pattern/ };
fail() if $@ || !defined($secret_re);

sysopen(my $root,$private_root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or fail();
my @opened=stat($root); my @named=lstat($private_root);
fail() unless @opened && @named && S_ISDIR($opened[2]) && !S_ISLNK($named[2])
  && oid(@opened) eq $root_want && oid(@named) eq $root_want
  && $opened[4] == $< && ($opened[2]&0777) == 0700;
chdir($root) or fail();
my @cwd=stat(q{.}); fail() unless @cwd && S_ISDIR($cwd[2]) && oid(@cwd) eq $root_want;
sysopen(my $parent,q{..},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or fail();
my @parent=stat($parent); fail() unless @parent && S_ISDIR($parent[2]) && oid(@parent) eq $parent_want;
close($parent) or fail();
close($root) or fail();

my %common=map { $_=>1 } qw(
  PATH USER LOGNAME LANG LC_ALL LC_CTYPE TZ
);
my %github_credential=map { $_=>1 } qw(
  GH_TOKEN GITHUB_TOKEN GH_ENTERPRISE_TOKEN GITHUB_ENTERPRISE_TOKEN
);
# Exact fixture controls only. No production wildcard: adding a test control requires code review.
my %github_test=map { $_=>1 } qw(
  FAKE_GH_CAPPED FAKE_GH_CHMOD_AUDIT FAKE_GH_DEDUP_AMBIGUOUS FAKE_GH_DEDUP_CLOSED
  FAKE_GH_DEDUP_HIT FAKE_GH_DESCENDANT FAKE_GH_DESC_PID_FILE FAKE_GH_DESC_SURVIVED
  FAKE_GH_DESC_TERM_MARKER FAKE_GH_DIR FAKE_GH_DOWN FAKE_GH_ENV_STATE_FILE
  FAKE_GH_ESCAPED_PID_FILE FAKE_GH_EXISTING_BODY FAKE_GH_HANG FAKE_GH_HOST_STATE_FILE
  FAKE_GH_GIT_STATE_FILE FAKE_GH_LATE_HIT FAKE_GH_LIST_INVALID FAKE_GH_LIST_MARKER FAKE_GH_LIST_PAUSE
  FAKE_GH_LIST_PAUSE_ONCE FAKE_GH_MARKER FAKE_GH_NEW_NUMBER FAKE_GH_RC
  FAKE_GH_RECONCILE_FAIL FAKE_GH_RECONCILE_MODE FAKE_GH_REPO
  FAKE_GH_REQUIRE_HOST_QUALIFIED FAKE_GH_REQUIRE_HOST_UNSET FAKE_GH_STATION_HOME
  FAKE_GH_SWAP_SPEC_DIR FAKE_GH_SWAP_TARGET FAKE_GH_VIEW_BODY_MISMATCH
  FAKE_GH_VIEW_CLOSED FAKE_GH_VIEW_MISMATCH FAKE_GH_VIEW_RC FAKE_GH_VIEW_STATE
  FAKE_GH_VISIBILITY FAKE_GH_VISIBILITY_INVALID
);
my %clean;
for my $key (keys %ENV) {
  my $allowed=$common{$key} || $github_credential{$key}
    || ($test_enabled eq q{1} && $github_test{$key});
  next unless $allowed;
  fail() if !$github_credential{$key} && $ENV{$key}=~/$secret_re/;
  $clean{$key}=$ENV{$key};
}
%ENV=%clean;
$ENV{HOME}=q{.};
$ENV{TMPDIR}=q{.};
$ENV{TMP}=q{.};
$ENV{TEMP}=q{.};
$ENV{GIT_CONFIG_NOSYSTEM}=q{1};
$ENV{GIT_CONFIG_GLOBAL}=q{/dev/null};
$ENV{GIT_CONFIG_SYSTEM}=q{/dev/null};
$ENV{GIT_NO_REPLACE_OBJECTS}=q{1};
$ENV{GIT_DIR}=q{/dev/null};
$ENV{GIT_WORK_TREE}=q{/dev/null};

# Do not leak orchestration/test-control descriptors to the provider: every descriptor above
# stderr is closed before exec.
opendir(my $fds,q{/dev/fd}) or fail();
my @close=grep { /\A[0-9]+\z/ && $_>2 } readdir($fds);
closedir($fds) or fail();
POSIX::close($_) for @close;

umask 0077;
exec @command or fail();
