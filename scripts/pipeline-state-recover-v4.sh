#!/usr/bin/env bash
# Stable read-only State V4 recovery surface. It intentionally has no writer or pair-WAL code.
set -euo pipefail

# A recovery surface must not load caller-supplied Perl modules before it validates state bytes.
unset PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC 2>/dev/null || true
unset CDPATH 2>/dev/null || true

die() { echo "pipeline-state-recover-v4: FATAL: $*" >&2; exit 2; }

[ "$#" -eq 2 ] \
  || die 'usage: pipeline-state-recover-v4.sh <validate-state|status> <SPEC_DIR>'
CMD="$1"
DIR="$2"
STATE="$DIR/state.md"
AUDIT="$DIR/audit.md"
SCRIPT_DIR="$(cd -- "$(dirname -- "$0")" && pwd -P)"
READER="$SCRIPT_DIR/lib/pipeline-state-reader-v4.pl"

[ -f "$STATE" ] || die "нет $STATE"
[ -f "$AUDIT" ] || die "нет $AUDIT"
[ -r "$READER" ] || die "shared V4 reader недоступен: $READER"
[ "$(perl "$READER" --contract 2>/dev/null)" = 'pipeline-state-reader-v4/1' ] \
  || die "shared V4 reader contract несовместим"

PROFILE="$(PIPELINE_STATE_TRUSTED_STDIN=0 PIPELINE_STATE_OUTPUT=profile perl "$READER" "$STATE")"
# This read-only surface cannot reconcile pair-WAL or acquire the canonical writer lock.  It still
# descriptor-validates the audit table so a lone/corrupt audit is never presented as a usable pair;
# even a shape-valid pair remains explicitly non-authorizing until the writer reconciles it.
perl -MEncode=decode,FB_CROAK,LEAVE_SRC -MFcntl=O_RDONLY,O_NOFOLLOW,S_ISREG,S_ISLNK -e '
  use strict; use warnings; use utf8;
  sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
  my $f=shift; my @n=lstat($f); exit 2 unless @n && !S_ISLNK($n[2])
    && S_ISREG($n[2]) && $n[3]==1;
  sysopen(my $fh,$f,O_RDONLY|O_NOFOLLOW) or exit 2; my @o=stat($fh);
  exit 2 unless @o && did(@o) eq did(@n) && $o[3]==1;
  my $raw=q{}; while (1) { my $r=sysread($fh,my $b,65536); exit 2 unless defined($r);
    last unless $r; $raw.=$b; exit 2 if length($raw)>16777216 }
  my $v; eval { $v=decode(q{UTF-8},$raw,FB_CROAK|LEAVE_SRC); 1 } or exit 2;
  my $modern="# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
  my $legacy="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
  my $body;
  if (index($v,$modern)==0) { $body=substr($v,length($modern)) }
  elsif (index($v,$legacy)==0) { $body=substr($v,length($legacy)) }
  else { exit 2 }
  while (length($body)) {
    $body =~ s/\A\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| [^|\r\n]+ \| [^|\r\n]+ \|\n//
      or exit 2;
  }
  my @a=stat($fh); my @p=lstat($f); close($fh) or exit 2;
  exit 2 unless @a && @p && !S_ISLNK($p[2]) && S_ISREG($p[2]) && $p[3]==1
    && did(@a) eq did(@o) && did(@p) eq did(@o) && $a[7]==length($raw);
' "$AUDIT" || die "audit.md malformed или изменился во время чтения"
case "$CMD" in
  validate-state)
    echo "pipeline-state-recover-v4: validate-state OK: profile=$PROFILE audit=shape-valid authority=unverified"
    ;;
  status)
    case "$PROFILE" in
      v4-current)
        echo 'pipeline-state-recover-v4: profile=v4-current audit=shape-valid authority=unverified'
        echo 'pipeline-state-recover-v4: note=canonical writer lock/WAL reconciliation required before authority'
        ;;
      legacy|v2|v3)
        echo "pipeline-state-recover-v4: profile=$PROFILE authority=migration-required"
        echo 'pipeline-state-recover-v4: command=bash scripts/pipeline-state.sh migrate-v4 <SPEC_DIR>'
        ;;
      *) die "contract-migration-required: profile=$PROFILE" ;;
    esac
    ;;
  *) die 'command ожидаю validate-state|status' ;;
esac
