#!/usr/bin/env bash
# dora-metrics.sh — DORA-метрики + метрика автономии из локальных источников репозитория.
#
# Источники — только локальные (никаких внешних систем и сети):
#   git log                — commits total / agent-commits (Co-Authored-By) → автономия по коммитам
#   specs/*/audit.md       — init → quality-verdict (lead time); user-approval approved/revise;
#                            usage:* (стоимость); ticket:linked (прогоны с тикетом)
#   docs/ops-journal.md    — деплои (частота, CFR), incident:open|resolved (MTTR)
#
# Правило подсчёта деплоев (без двойного счёта):
#   - деплой = событие `deploy:done` / `deploy:failed` (пишет деплой-скрипт проекта через ops-log.sh);
#   - `scripts/agent-publish-main.sh` пишет `publish:done` / `publish:failed` (публикация в main) и
#     `publish:pr` (ветка отправлена под PR) — это НЕ деплой;
#   - если в журнале нет НИ ОДНОГО события `deploy:*` (у проекта нет деплой-шага), частота и CFR
#     считаются по `publish:done` / `publish:failed` (публикация в main = поставка); источник
#     печатается в строке метрики. `publish:pr` не считается никогда.
#
# Метрики: Deployment Frequency · Lead Time (медиана init→PASS) · Change Failure Rate
#          (канон Accelerate: failed / (done + failed) — доля неуспешных попыток от всех;
#          инциденты окна аннотируются рядом, но не входят в формулу — журнал не атрибутирует
#          incident к конкретному деплою) · MTTR (медиана open→resolved) ·
#          Autonomy % (агентные коммиты / все; цель ≥ AUTONOMY_TARGET, по умолчанию 40)
#
# Usage: bash scripts/dora-metrics.sh [repo-root] [--days N] [--html] [--usage-agg]
#   --html — HTML-фрагмент для встраивания в pipeline-dashboard.sh
#   --usage-agg — fast-path агрегатор usage-токенов (контракт v=1): stdout ТОЛЬКО key=value
#                 (v, has_data; при has_data=1 — tokens_24h/tokens_30d/tokens_total, sources=<csv>);
#                 git не вызывается вовсе — читаются одни specs/*/audit.md
# ENV (все advisory):
#   RUN_TOKEN_BUDGET=<int> — бюджет токенов прогона; 0/нечисловой = не задан (guard)
#   TICKET_COMMIT_RE=<re>  — perl-регекс тикет-ссылок в commit message; дефолт покрывает
#                            Closes/Fixes/Refs #N и KEY-N; регекс печатается в строке вывода
# Exit: 0 (метрики advisory — coverage-цель с честным отчётом, не гейт) · 2 = ошибка аргументов/среды
set -uo pipefail
set -uo pipefail

ROOT="."; DAYS=30; MODE="text"; USAGE_AGG=0
while [ $# -gt 0 ]; do
  case "$1" in
    --days) DAYS="${2:?}"; shift 2;;
    --html) MODE="html"; shift;;
    --usage-agg) USAGE_AGG=1; shift;;
    -*) echo "dora-metrics: неизвестный флаг '$1'" >&2; exit 2;;
    *) ROOT="$1"; shift;;
  esac
done
cd "$ROOT" 2>/dev/null || { echo "dora-metrics: FATAL: repo root unavailable" >&2; exit 2; }
REPO_ROOT="$(pwd -P)"
TARGET="${AUTONOMY_TARGET:-40}"

# Local repository state is authority; inherited Git plumbing/configuration is not.  A caller may
# still choose PATH (normal CLI discovery), but cannot redirect rev-parse/log/config through
# GIT_DIR, alternate object stores, replace refs, namespaces, dynamic config KEY_n/VALUE_n, or
# global/system config injection.  DORA performs no git network operation, so no Git transport
# environment needs to survive this boundary.
DORA_GIT_BIN="$(type -P git 2>/dev/null || true)"
case "$DORA_GIT_BIN" in /*) :;; *) DORA_GIT_BIN="";; esac
dora_git() {
  [ -n "$DORA_GIT_BIN" ] || return 127
  DORA_GIT_EXEC="$DORA_GIT_BIN" perl -e '
    use strict; use warnings;
    my $git=$ENV{DORA_GIT_EXEC};
    delete @ENV{grep { /^GIT_/ } keys %ENV};
    $ENV{GIT_CONFIG_NOSYSTEM}=1;
    $ENV{GIT_CONFIG_SYSTEM}="/dev/null";
    $ENV{GIT_CONFIG_GLOBAL}="/dev/null";
    $ENV{GIT_ATTR_NOSYSTEM}=1;
    $ENV{GIT_CONFIG_COUNT}=0;
    $ENV{GIT_OPTIONAL_LOCKS}=0;
    exec {$git} $git,@ARGV; exit 127;
  ' -- "$@"
}

# Temporary data must never land in the measured worktree.  An explicitly supplied TMPDIR inside
# the repository is treated as untrusted: per-run files move to a safe system temp root.  This also
# keeps a killed/aborted run from leaving commit messages ready for an accidental `git add`.
DORA_TMP_BASE=""
DORA_TMP_BASE_EXPECT_ID=""
DORA_REQUESTED_TMP="${TMPDIR:-/tmp}"
dora_temp_base_record() {
  ( cd "$1" 2>/dev/null && perl -MCwd=abs_path -e '
      my $p=abs_path(q{.}); my @s=stat(q{.}); exit 1 unless defined($p) && @s;
      print "$s[0]:$s[1]|$p";
    ' )
}
DORA_REQUESTED_TMP_RECORD="$(dora_temp_base_record "$DORA_REQUESTED_TMP" 2>/dev/null || true)"
if [ -n "$DORA_REQUESTED_TMP_RECORD" ] && [ "${DORA_REQUESTED_TMP_RECORD#*|}" != "$DORA_REQUESTED_TMP_RECORD" ]; then
  DORA_TMP_BASE_EXPECT_ID="${DORA_REQUESTED_TMP_RECORD%%|*}"
  DORA_REQUESTED_TMP_ABS="${DORA_REQUESTED_TMP_RECORD#*|}"
  case "$DORA_REQUESTED_TMP_ABS" in
    "$REPO_ROOT"|"$REPO_ROOT"/*) : ;;
    *) DORA_TMP_BASE="$DORA_REQUESTED_TMP_ABS" ;;
  esac
fi
if [ -z "$DORA_TMP_BASE" ]; then
  DORA_FALLBACK_TMP_RECORD="$(dora_temp_base_record /tmp 2>/dev/null || true)"
  DORA_TMP_BASE_EXPECT_ID="${DORA_FALLBACK_TMP_RECORD%%|*}"
  DORA_TMP_BASE="${DORA_FALLBACK_TMP_RECORD#*|}"
  if [ -z "$DORA_FALLBACK_TMP_RECORD" ] || [ "$DORA_TMP_BASE" = "$DORA_FALLBACK_TMP_RECORD" ]; then
    echo "dora-metrics: FATAL: safe temporary root unavailable" >&2; exit 2;
  fi
  case "$DORA_TMP_BASE" in
    "$REPO_ROOT"|"$REPO_ROOT"/*)
      echo "dora-metrics: FATAL: safe temporary root unavailable" >&2; exit 2;;
  esac
fi

# --- git: автономия по коммитам за окно ---
# fast-path: при --usage-agg git не вызывается вовсе (short-circuit ДО rev-parse)
C_TOTAL=0; C_AGENT=0
if [ "$USAGE_AGG" -eq 0 ] && dora_git rev-parse --git-dir >/dev/null 2>&1; then
  C_TOTAL="$(dora_git log --since="$DAYS days ago" --pretty=%H 2>/dev/null | wc -l | tr -d ' ')"
  C_AGENT="$(dora_git log --since="$DAYS days ago" --grep='Co-Authored-By' --pretty=%H 2>/dev/null | wc -l | tr -d ' ')"
fi

# --- autonomy v2: ЕДИНЫЙ git log с датами и полным message за прогон ---
# Общий источник ISO-недельных трендов и тикет-ссылок коммитов: per-неделя git-вызовы запрещены.
# The per-run directory is created relative to an opened temp-base descriptor; there is no path
# check→mkdir window through a swapped parent.
DORA_RUN_RECORD="$(DORA_IO_BASE="$DORA_TMP_BASE" DORA_IO_BASE_ID="$DORA_TMP_BASE_EXPECT_ID" perl \
  -MFcntl=:DEFAULT,O_NOFOLLOW,O_DIRECTORY,S_ISDIR -e '
    use strict; use warnings; umask 0077;
    my $base=$ENV{DORA_IO_BASE};
    sysopen(my $bf,$base,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
    my @bs=stat($bf); my @bp=lstat($base);
    exit 1 unless @bs && @bp && S_ISDIR($bs[2])
      && "$bs[0]:$bs[1]" eq "$bp[0]:$bp[1]"
      && "$bs[0]:$bs[1]" eq ($ENV{DORA_IO_BASE_ID}//q{});
    chdir($bf) or exit 1;
    sysopen(my $ur,q{/dev/urandom},O_RDONLY|O_NOFOLLOW) or exit 1;
    sysread($ur,my $random,16)==16 or exit 1; close($ur) or exit 1;
    my $stem=q{dora-v2.}.unpack(q{H*},$random); my ($name,$rf);
    for my $try (0..31) {
      $name=$stem.q{.}.$try; next unless mkdir($name,0700);
      sysopen($rf,$name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; last;
    }
    exit 1 unless defined $rf;
    my @rs=stat($rf); my @rp=lstat($name);
    exit 1 unless @rs && @rp && S_ISDIR($rs[2]) && $rs[4]==$< && ($rs[2]&07777)==0700
      && "$rs[0]:$rs[1]" eq "$rp[0]:$rp[1]";
    print "$bs[0]:$bs[1]|$name|$rs[0]:$rs[1]";
  ' 2>/dev/null || true)"
DORA_TMP_BASE_ID="${DORA_RUN_RECORD%%|*}"; DORA_RUN_REST="${DORA_RUN_RECORD#*|}"
DORA_RUN_NAME="${DORA_RUN_REST%%|*}"; DORA_RUN_ID="${DORA_RUN_REST#*|}"
case "$DORA_TMP_BASE_ID|$DORA_RUN_NAME|$DORA_RUN_ID" in
  [0-9]*:[0-9]*\|dora-v2.[0-9a-f]*.[0-9]*\|[0-9]*:[0-9]*) :;;
  *) echo "dora-metrics: FATAL: private temporary namespace unavailable" >&2; exit 2;;
esac
V2TMP="$DORA_TMP_BASE/$DORA_RUN_NAME"
# The descriptor cleanup helper is installed below before any commit byte can exist.  Until then a
# rare early abort leaves an owned private directory; it never performs path-recursive deletion.
trap ':' EXIT

# --- журналы: собираем строки таблиц (audit per spec + ops-journal) и считаем в perl ---
AUDITS=()
for a in specs/*/audit.md; do [ -f "$a" ] && AUDITS+=("$a"); done
OPS="docs/ops-journal.md"

# Descriptor-anchored run-directory I/O.  A helper invocation first opens the canonical temp base
# and checks its recorded device/inode, then opens the per-run directory relative to that pinned
# descriptor.  Every leaf is a slash-free name, so a renamed/replaced ancestor cannot redirect the
# cleanup outside the private run directory.
DORA_RUN_IO_PERL=""
IFS= read -r -d '' DORA_RUN_IO_PERL <<'PERL' || true
use strict;
use warnings;
use Fcntl qw(:DEFAULT O_NOFOLLOW O_DIRECTORY S_ISDIR);
use Errno qw(ENOENT);

sub fail { exit 1 }
sub oid { my (@s)=@_; join(q{:},@s[0,1]) }
sub leaf_ok { defined($_[0]) && $_[0] =~ /\A[A-Za-z0-9._-]+\z/ && $_[0] ne q{.} && $_[0] ne q{..} }

sub open_abs_dir {
  my ($path,$expect,$owned)=@_;
  fail() if !defined($path) || $path eq q{} || $path =~ /\x00/;
  sysopen(my $fh,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or fail();
  my @s=stat($fh); my @p=lstat($path);
  fail() unless @s && @p && S_ISDIR($s[2]) && oid(@s) eq oid(@p);
  fail() if defined($expect) && $expect ne q{} && oid(@s) ne $expect;
  fail() if $owned && ($s[4] != $< || ($s[2]&07777) != 0700);
  return ($fh,oid(@s));
}

sub open_child_dir {
  my ($parent,$name,$expect,$owned)=@_;
  fail() unless leaf_ok($name); chdir($parent) or fail();
  my @before=lstat($name); fail() unless @before && S_ISDIR($before[2]);
  sysopen(my $fh,$name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or fail();
  my @s=stat($fh); my @after=lstat($name);
  fail() unless @s && @after && S_ISDIR($s[2])
    && oid(@s) eq oid(@before) && oid(@s) eq oid(@after);
  fail() if defined($expect) && $expect ne q{} && oid(@s) ne $expect;
  fail() if $owned && ($s[4] != $< || ($s[2]&07777) != 0700);
  return ($fh,oid(@s));
}

my ($op,$base,$base_id,$run_name,$run_id,@arg)=@ARGV;
my ($base_fh,$actual_base)=open_abs_dir($base,$base_id,0);
my ($run_fh,$actual_run)=open_child_dir($base_fh,$run_name,$run_id,1);
if ($op eq q{run-ids}) { print $actual_base,q{|},$actual_run; exit 0 }
if ($op eq q{cleanup}) {
  chdir($run_fh) or fail();
  for my $leaf (qw(commits)) {
    my @s=lstat($leaf); next if !@s && $! == ENOENT;
    fail() unless @s && !S_ISDIR($s[2]); unlink($leaf) or fail();
  }
  chdir($base_fh) or fail(); my @r=lstat($run_name);
  fail() unless @r && S_ISDIR($r[2]) && oid(@r) eq $run_id;
  rmdir($run_name) or fail(); exit 0;
}

fail();
PERL

dora_run_io() {
  perl -e "$DORA_RUN_IO_PERL" -- "$@"
}

DORA_IO_IDS="$(dora_run_io run-ids "$DORA_TMP_BASE" "$DORA_TMP_BASE_ID" \
  "$DORA_RUN_NAME" "$DORA_RUN_ID" 2>/dev/null || true)"
if [ "$DORA_IO_IDS" != "$DORA_TMP_BASE_ID|$DORA_RUN_ID" ]; then
  echo "dora-metrics: FATAL: private temporary namespace changed" >&2; exit 2
fi
dora_run_cleanup() {
  dora_run_io cleanup "$DORA_TMP_BASE" "$DORA_TMP_BASE_ID" \
    "$DORA_RUN_NAME" "$DORA_RUN_ID" >/dev/null 2>&1 || true
}
trap 'dora_run_cleanup' EXIT

if [ "$USAGE_AGG" -eq 0 ] && dora_git rev-parse --git-dir >/dev/null 2>&1; then
  dora_git log --since="$DAYS days ago" --pretty=format:'%x1e%H|%at|%B' >"$V2TMP/commits" 2>/dev/null
fi

# --- журналы: собираем строки таблиц (audit per spec + ops-journal) и считаем в perl ---
AUDITS=()
for a in specs/*/audit.md; do [ -f "$a" ] && AUDITS+=("$a"); done
OPS="docs/ops-journal.md"

C_TOTAL="$C_TOTAL" C_AGENT="$C_AGENT" DAYS="$DAYS" MODE="$MODE" TARGET="$TARGET" OPS_J="$([ -f "$OPS" ] && echo "$OPS")" \
USAGE_AGG="$USAGE_AGG" RUN_TOKEN_BUDGET="${RUN_TOKEN_BUDGET:-}" V2_DIR="$V2TMP" \
TICKET_COMMIT_RE="${TICKET_COMMIT_RE:-}" \
EVAL_JSON="$([ -f "$ROOT/tests/agent-evals/last-run.json" ] && echo "$ROOT/tests/agent-evals/last-run.json")" \
perl - "${AUDITS[@]:-}" <<'PERL'
use strict; use warnings; use utf8;
use Time::Local qw(timegm);
binmode STDOUT, ':utf8';

my ($days, $mode, $target) = ($ENV{DAYS}, $ENV{MODE}, $ENV{TARGET});
my ($c_total, $c_agent)    = ($ENV{C_TOTAL} // 0, $ENV{C_AGENT} // 0);
my $uagg = ($ENV{USAGE_AGG} // '') eq '1';   # режим-маркер fast-path из bash-слоя
my $now = time; my $cut = $now - $days * 86400;

# autonomy v2 — пороги-константы (экспертные; каждый печатается в своей строке вывода — «панель
# без порога лжёт молча»; пересмотр — по накопленной истории)
my $TREND_MIN = 3;   # минимум непустых ISO-недель для рендера тренда
my $XCHK_K  = 5;     # минимум прогонов с гейтом для cross-check осей
my $XCHK_M  = 20;    # минимум коммитов окна для cross-check осей
my $XCHK_PP = 25;    # порог расхождения осей, процентные пункты

sub ts2e { my $t = shift // ''; return $t =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/ ? eval { timegm($6,$5,$4,$3,$2-1,$1) } : undef }
sub rows { my $f = shift; my @r;
  open(my $h, '<:utf8', $f) or return @r;
  while (<$h>) { chomp;
    next unless /^\| (.*?) \| (.*?) \| (.*?) \|$/;
    my ($ts,$ev,$det) = ($1,$2,$3);
    next if $ts eq 'ts (UTC)' || $ts =~ /^-+$/;
    my $e = ts2e($ts); next unless defined $e;
    push @r, [$e,$ev,$det];
  } @r }
sub median { my @s = sort { $a <=> $b } @_; return undef unless @s; return $s[$#s/2] }
sub hdur { my $s = shift; return 'n/a' unless defined $s;
  return $s < 3600 ? sprintf('%dm', $s/60) : $s < 86400 ? sprintf('%.1fh', $s/3600) : sprintf('%.1fd', $s/86400) }
# локальная копия scripts/lib/deck-lib.pl::esc (dora-metrics автономен, зависимость от lib дашбордов
# не вводится; esc стабилен, правки только синхронно там и тут). Через esc() идёт ЛЮБОЕ не-числовое
# внешнее значение в --html.
sub esc { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
# ISO-8601 неделя (UTC) из epoch → 'YYYY-Wnn': чистая арифметика вместо POSIX::strftime %V
# (%V/%G делегируются libc — непереносимо); алгоритм канонический: w = (yday - dow + 10) / 7
sub isoweek { my $e = shift; my @t = gmtime($e);
  my ($y, $yd, $dow) = ($t[5] + 1900, $t[7] + 1, $t[6] == 0 ? 7 : $t[6]);
  my $p = sub { my $x = shift; ($x + int($x/4) - int($x/100) + int($x/400)) % 7 };
  my $wk_in = sub { my $yy = shift; 52 + ($p->($yy) == 4 || $p->($yy - 1) == 3 ? 1 : 0) };
  my $w = int(($yd - $dow + 10) / 7);
  if    ($w < 1)            { $y--; $w = $wk_in->($y) }
  elsif ($w > $wk_in->($y)) { $y++; $w = 1 }
  sprintf('%04d-W%02d', $y, $w) }
sub v2_trend { # \%{ISO-неделя → значение} → компактная строка либо undef при < $min непустых бакетов
  my ($h, $min) = @_;
  my @w = sort keys %$h;
  return undef if @w < $min;
  return join(' · ', map { my $l = $_; $l =~ s/^\d{4}-//; "$l $h->{$_}" } @w) }

# lead time + revise по прогонам пайплайна
my (@lead, $appr, $rev); $appr = $rev = 0;
# autonomy v2: агрегаты ПО ПРОГОНАМ; «активность» прогона в окне — только
# по user-approval/init/usage:*/ticket:linked (осиротевшие agent:*:start не влияют by construction)
my ($v2_act, $v2_ucov, $v2_usum, @v2_umed, %v2_usrc) = (0, 0, 0);
my ($v2_k, $v2_rev, $v2_ab, $v2_asis, $v2_iman) = (0, 0, 0, 0, 0);
my ($v2_kt, $v2_revt, $v2_asist) = (0, 0, 0);   # срез по тикет-связанным прогонам
my (%wk_init, %wk_rev);
# --usage-agg: аккумуляторы фиксированных окон 24ч/30д/всего — pre-cut
# (НЕ зависят от --days: событие вне --days-окна живёт в tokens_total)
my ($ua_24, $ua_30, $ua_tot, $ua_n, %ua_src) = (0, 0, 0, 0);
for my $f (grep { length } @ARGV) {
  my @r = rows($f);
  my ($init) = map { $_->[0] } grep { $_->[1] eq 'init' } @r;
  my ($pass) = map { $_->[0] } grep { $_->[1] eq 'quality-verdict' && $_->[2] =~ /^PASS/ } @r;
  push @lead, $pass - $init if defined $init && defined $pass && $pass >= $cut;
  for (@r) { next unless $_->[0] >= $cut && $_->[1] eq 'user-approval';
    $appr++ if $_->[2] =~ /^approved/; $rev++ if $_->[2] =~ /^revise/; }
  # autonomy v2: per-run флаги отдельным аддитивным проходом (существующий счёт выше не тронут)
  my ($run_act, $run_us, $run_uok, $g_any, $g_rev, $g_ab, $run_t) = (0, 0, 0, 0, 0, 0, 0);
  for (@r) {
    my ($e, $ev, $det) = @$_;
    $run_t = 1 if $ev eq 'ticket:linked';   # связь исторична: флаг считается и ВНЕ окна
    # guard usage (I-13/I-17) в pre-cut-зоне:
    # событие валидно ТОЛЬКО при tokens=<int> И непустом source= (tokens=0 валиден — defined-,
    # не truthy-проверка); кламп \d{1,15} — честность рендера; eval — изоляция парсера;
    # результат реюзается post-cut ниже — второго guard'а нет
    my ($ev_tok, $ev_src);
    if ($ev =~ /^usage:/) {
      ($ev_tok, $ev_src) = eval {
        my ($t) = ($det // '') =~ /\btokens=(\d{1,15})\b/;
        my ($s) = ($det // '') =~ /\bsource=(\S+)/;
        (defined $t && defined $s && length $s) ? ($t, $s) : ();
      };
      if (defined $ev_tok) {
        $ua_n++; $ua_tot += $ev_tok; $ua_src{$ev_src} = 1;
        $ua_24 += $ev_tok if $now - $e <= 86400;
        $ua_30 += $ev_tok if $now - $e <= 30 * 86400;
      }
    }
    next unless $e >= $cut;
    if ($ev eq 'user-approval') {
      $run_act = 1; $g_any++;
      if    (($det // '') =~ /^revise/) { $g_rev++; eval { $wk_rev{isoweek($e)}++; 1 } }
      elsif (($det // '') =~ /^abort/)  { $g_ab++ }
    }
    elsif ($ev eq 'init')                { $run_act = 1; eval { $wk_init{isoweek($e)}++; 1 } }
    elsif ($ev eq 'ticket:linked')       { $run_act = 1 }
    elsif ($ev eq 'intervention:manual') { $run_act = 1; $v2_iman++ }
    elsif ($ev =~ /^usage:/) {
      $run_act = 1;
      # guard исполнен в pre-cut-зоне выше: здесь только окно-зависимые
      # аккумуляторы прогона — pre-cut usage-событие сюда НЕ доходит (next unless $e >= $cut)
      if (defined $ev_tok) { $v2_usrc{$ev_src} = 1; $run_us += $ev_tok; $run_uok = 1 }
    }
  }
  if ($run_act) {
    $v2_act++;
    if ($run_uok) { $v2_ucov++; $v2_usum += $run_us; push @v2_umed, $run_us }
  }
  # прогон = одна единица независимо от числа событий; abort ≠ revise
  if ($g_any) {
    $v2_k++;
    $v2_rev++  if $g_rev;
    $v2_ab++   if $g_ab;
    $v2_asis++ if !$g_rev && !$g_ab;
    if ($run_t) { $v2_kt++; $v2_revt++ if $g_rev; $v2_asist++ if !$g_rev && !$g_ab }
  }
}

# ── контракт --usage-agg v=1 — stdout ТОЛЬКО key=value; при has_data=0
#    tokens-ключи ОТСУТСТВУЮТ (absence ≠ 0); ранний выход — perl-половина fast-path
#    (git уже пропущен bash-слоем, рендер prose/html не исполняется) ──
if ($uagg) {
  print "v=1\n";
  if ($ua_n) {
    print "has_data=1\n";
    print "tokens_24h=$ua_24\n";
    print "tokens_30d=$ua_30\n";
    print "tokens_total=$ua_tot\n";
    print 'sources=' . join(',', sort keys %ua_src) . "\n";
  } else {
    print "has_data=0\n";
  }
  exit 0;
}

# ── autonomy v2: разбор единого git-источника (SHA|epoch|message) — недели + Co-Authored-By;
#    тот же проход считает тикет-ссылки коммитов — второго git-вызова нет ──
my $v2dir = $ENV{V2_DIR} // '';
my ($v2_ct, $v2_ca, $v2_cref) = (0, 0, 0);
my (%wk_ct, %wk_ca);
# регекс тикет-ссылок — константа с ENV-переопределением; источник печатается
my $v2_re = $ENV{TICKET_COMMIT_RE} // ''; utf8::decode($v2_re);
my $re_src;
if ($v2_re ne '') { $re_src = "ENV TICKET_COMMIT_RE: $v2_re" }
else { $v2_re = '\b(?:[Cc]loses|[Ff]ixes|[Rr]efs)\s+#(\d+)|\b([A-Z][A-Z0-9]+-\d+)\b';
       $re_src = 'дефолт (Closes/Fixes/Refs #N · KEY-N)' }
my $v2_qr = eval { qr/$v2_re/ };
$re_src .= ' — НЕ КОМПИЛИРУЕТСЯ: тикет-ссылки не считаны (advisory)' unless defined $v2_qr;
if ($v2dir ne '' && -s "$v2dir/commits") {
  eval {  # die парсера деградирует только v2-коммит-метрики, не остальной рендер
    open(my $h, '<:utf8', "$v2dir/commits") or die "open: $!";
    local $/; my $raw = <$h>; close $h;
    for my $rec (split /\x1e/, $raw) {
      next unless $rec =~ /^([0-9a-f]{7,40})\|(\d+)\|(.*)$/s;
      my ($sha, $at, $msg) = ($1, $2, $3);
      $v2_ct++;
      my $agent = $msg =~ /Co-Authored-By/ ? 1 : 0;
      $v2_ca++ if $agent;
      eval { my $w = isoweek($at); $wk_ct{$w}++; $wk_ca{$w}++ if $agent; 1 };
      # тикет-ссылки из ПОЛНОГО message (ссылка может стоять в теле)
      $v2_cref++ if defined $v2_qr && $msg =~ /$v2_qr/;
    }
    1;
  } or do { ($v2_ct, $v2_ca, $v2_cref) = (0, 0, 0); %wk_ct = (); %wk_ca = (); };
}

# деплои/инциденты из ops-journal. Деплой = deploy:done|failed; если в журнале нет НИ ОДНОГО
# deploy:* события (у проекта нет деплой-шага), поставкой считается публикация в main
# (publish:done|failed от agent-publish-main.sh). publish:pr не считается никогда — без двойного счёта.
my ($dep_ok, $dep_fail, $pub_ok, $pub_fail, $has_deploy, $inc_open, @mttr, %open) = (0, 0, 0, 0, 0, 0);
if (my $oj = $ENV{OPS_J}) {
  for my $r (rows($oj)) {
    my ($e, $ev, $det) = @$r;
    my ($slug) = ($det // '') =~ /^(\S+)/;
    $has_deploy = 1 if $ev =~ /^deploy:/;
    if    ($ev eq 'incident:open')     { $open{$slug // ''} = $e; $inc_open++ if $e >= $cut }
    elsif ($ev eq 'incident:resolved') { my $o = delete $open{$slug // ''};
                                         push @mttr, $e - $o if defined $o && $e >= $cut }
    next unless $e >= $cut;
    $dep_ok++   if $ev eq 'deploy:done';
    $dep_fail++ if $ev eq 'deploy:failed';
    $pub_ok++   if $ev eq 'publish:done';
    $pub_fail++ if $ev eq 'publish:failed';
  }
}
my $dep_src = 'deploy:done|failed';
if (!$has_deploy) { ($dep_ok, $dep_fail, $dep_src) = ($pub_ok, $pub_fail, 'publish:done|failed — deploy:* в журнале нет') }

my $dep_all = $dep_ok + $dep_fail;
my $freq  = $dep_ok ? sprintf('%.1f/нед (источник: %s)', $dep_ok / ($days / 7), $dep_src)
                    : 'нет данных (deploy:done или publish:done в ops-journal)';
my $lead  = @lead ? hdur(median(@lead)) . ' (медиана, ' . scalar(@lead) . ' прогонов)' : 'нет завершённых прогонов';
# CFR по канону Accelerate: доля попыток деплоя, завершившихся сбоем, от ВСЕХ попыток.
# Формула (fail+incidents)/done давала бы >100% и 'n/a' при «0 done + N failed».
# Инциденты не атрибутируемы к деплою из журнала — аннотация рядом.
my $cfr   = $dep_all
  ? sprintf('%.0f%% (%d fail из %d попыток)%s', 100*$dep_fail/$dep_all, $dep_fail, $dep_all,
            $inc_open ? " · +$inc_open incident(ов) в окне" : '')
  : 'n/a (нет деплоев в окне)';
my $mttr  = @mttr ? hdur(median(@mttr)) . ' (медиана, ' . scalar(@mttr) . ' инцидентов)' : ($inc_open ? "$inc_open открыт(о) без resolve" : 'инцидентов нет');
my $auto  = $c_total ? sprintf('%.0f', 100 * $c_agent / $c_total) : undef;
my $auto_s = defined $auto ? "$auto% ($c_agent из $c_total коммитов)" : 'нет git-истории';
my $auto_ok = defined $auto && $auto >= $target;
my $gates = ($appr + $rev) ? sprintf('%d approved / %d revise', $appr, $rev) : 'нет данных';

# ── autonomy v2: intervention rate / merged-as-is —
#    каждая строка несёт источник и выборку; guard на нулевой знаменатель ──
my $v2_gate_nd = 'нет прогонов с гейтом в окне · источник: specs/*/audit.md user-approval';
my $v2_ir = $v2_k
  ? sprintf('%.0f%% (%d из %d прогонов с гейтом)', 100 * $v2_rev / $v2_k, $v2_rev, $v2_k)
    . ($v2_kt   ? sprintf(' · по тикетным: %.0f%% (%d из %d)', 100 * $v2_revt / $v2_kt, $v2_revt, $v2_kt) : '')
    . ($v2_ab   ? " · (+$v2_ab abort)" : '')
    . ($v2_iman ? " · +$v2_iman задекларированных ручных правок (нижняя граница, self-declared)" : '')
    . ' · источник: specs/*/audit.md user-approval'
  : $v2_gate_nd;
my $v2_ma = $v2_k
  ? sprintf('%.0f%% (%d из %d прогонов с гейтом; все user-approval=approved — по гейтам владельца, не PR)',
            100 * $v2_asis / $v2_k, $v2_asis, $v2_k)
    . ($v2_kt ? sprintf(' · по тикетным: %.0f%% (%d из %d)', 100 * $v2_asist / $v2_kt, $v2_asist, $v2_kt) : '')
    . ' · источник: specs/*/audit.md user-approval'
  : $v2_gate_nd;

# ── autonomy v2: тикет-покрытие прогонов и тикет-ссылки коммитов ──
my $v2_tc = $v2_k
  ? sprintf('%d из %d прогонов с гейтом (событие ticket:linked) · источник: specs/*/audit.md', $v2_kt, $v2_k)
  : 'нет прогонов с гейтом в окне · источник: specs/*/audit.md ticket:linked';
my $v2_cr = $v2_ct
  ? sprintf('%.0f%% (%d из %d коммитов окна) · источник: git log, регекс %s', 100 * $v2_cref / $v2_ct, $v2_cref, $v2_ct, $re_src)
  : 'нет коммитов в окне · источник: git log';
# постоянная сноска-легенда ограничений коммит-оси (строка «Автономия» не меняется)
my $v2_fn = 'по коммитам: Co-Authored-By бинарен — интервенции внутри сессии не видны; вес = число коммитов · источник: git log';

# ── autonomy v2: cross-check коммит-оси и гейт-оси — только на достаточной выборке,
#    ниже порогов строка НЕ печатается (не шумим на малых данных) ──
my $v2_xchk;
if ($v2_k >= $XCHK_K && $v2_ct >= $XCHK_M && defined $auto) {
  my $ma_pct = 100 * $v2_asis / $v2_k;
  my $d = abs($auto - $ma_pct);
  if ($d > $XCHK_PP) {
    $v2_xchk = sprintf('оси автономии расходятся: коммиты %d%% vs гейты %.0f%% (Δ %.0f п.п. > %d п.п.; пороги выборки K≥%d прогонов, M≥%d коммитов) — интервенции внутри сессий или мелкие коммиты искажают ось · источник: git log + audit.md',
                       $auto, $ma_pct, $d, $XCHK_PP, $XCHK_K, $XCHK_M);
  }
}

# ── autonomy v2: weekly trends: < TREND_MIN непустых ISO-недель → честное «нет данных» ──
my $T_NOTREND = 'нет данных для тренда (< 3 нед. истории)';
my %wk_auto   = map { $_ => sprintf('%.0f%%', 100 * ($wk_ca{$_} // 0) / $wk_ct{$_}) } grep { $wk_ct{$_} } keys %wk_ct;
my %wk_init_d = map { $_ => $wk_init{$_} } grep { $wk_init{$_} } keys %wk_init;
my %wk_rev_d  = map { $_ => $wk_rev{$_} }  grep { $wk_rev{$_} }  keys %wk_rev;
my $v2_t_auto = (v2_trend(\%wk_auto,   $TREND_MIN) // $T_NOTREND) . ' · источник: git log · ISO-недели UTC, порог ≥3 непустых';
my $v2_t_init = (v2_trend(\%wk_init_d, $TREND_MIN) // $T_NOTREND) . ' · источник: audit.md init · ISO-недели UTC, порог ≥3 непустых';
my $v2_t_rev  = (v2_trend(\%wk_rev_d,  $TREND_MIN) // $T_NOTREND) . ' · источник: audit.md user-approval revise · ISO-недели UTC, порог ≥3 непустых';

# ── autonomy v2: стоимость прогона — источник/выборка/порог в строке ──
my $budget = ($ENV{RUN_TOKEN_BUDGET} // '') =~ /^([1-9]\d*)$/ ? $1 : 0;  # guard: 0/нечисловой = не задан
my ($v2_cost, $v2_cost_cls) = (undef, '');
if ($v2_ucov) {
  my $med  = median(@v2_umed);
  my $srcs = join(',', sort keys %v2_usrc);
  $v2_cost = sprintf('%d токенов за окно · медиана %d на прогон (%d из %d прогонов окна с usage-данными) · источник: audit.md usage:* (source=%s)',
                     $v2_usum, $med, $v2_ucov, $v2_act, $srcs);
  if ($budget) {
    my $pct = sprintf('%.0f', 100 * $med / $budget);
    $v2_cost .= " · медиана = $pct% бюджета (порог RUN_TOKEN_BUDGET=$budget)";
    $v2_cost_cls = $pct <= 100 ? 'ok' : 'bad';
  }
} else {
  $v2_cost = 'нет данных (usage-события не пишутся; конвенция — шапка pipeline-state.sh)';
}

# eval-harness: % Resolved из tests/agent-evals/last-run.json — АДДИТИВНО и graceful.
# Отсутствие файла / битый JSON → $eval_pct undef → строка НЕ печатается. JSON::PP — core-модуль.
my ($eval_pct, $eval_gate);
if (($ENV{EVAL_JSON} // '') ne '' && -f $ENV{EVAL_JSON}) {
  my $lr = eval {
    require JSON::PP;
    open(my $h, '<:raw', $ENV{EVAL_JSON}) or die;
    local $/; JSON::PP::decode_json(scalar <$h>);
  };
  if (ref $lr eq 'HASH' && defined $lr->{pct_resolved}) {
    $eval_pct  = "$lr->{pct_resolved}% ($lr->{resolved}/$lr->{total})";
    $eval_gate = $lr->{invariant_gate};
  }
}

if ($mode eq 'html') {
  my $cls = $auto_ok ? 'ok' : (defined $auto ? 'bad' : 'pending');
  print qq{<h2>DORA &middot; окно ${days}д</h2><div class="wrap"><table>\n};
  print qq{<tr><th>Метрика</th><th>Значение</th></tr>\n};
  print qq{<tr><td>&#128640; Deployment Frequency</td><td>$freq</td></tr>\n};
  print qq{<tr><td>&#9201;&#65039; Lead Time (init&rarr;PASS)</td><td>$lead</td></tr>\n};
  print qq{<tr><td>&#128165; Change Failure Rate</td><td>$cfr</td></tr>\n};
  print qq{<tr><td>&#128736;&#65039; MTTR</td><td>$mttr</td></tr>\n};
  print qq{<tr><td>&#129302; <b>Автономия (цель &ge;$target%)</b></td><td class="$cls">$auto_s</td></tr>\n};
  print qq{<tr><td>&#128737;&#65039; Гейты владельца</td><td>$gates</td></tr>\n};
  # ── autonomy v2: аддитивные строки ВНУТРИ той же таблицы (pipeline-dashboard.sh подхватывает
  #    без правок); значения с внешним текстом — через локальный esc() ──
  print qq{<tr><td>&#127919; Intervention rate</td><td>} . esc($v2_ir) . qq{</td></tr>\n};
  print qq{<tr><td>&#129309; Merged-as-is</td><td>} . esc($v2_ma) . qq{</td></tr>\n};
  print qq{<tr><td>&#127915; Прогоны с тикетом</td><td>} . esc($v2_tc) . qq{</td></tr>\n};
  print qq{<tr><td>&#128279; Коммиты с тикет-ссылкой</td><td>} . esc($v2_cr) . qq{</td></tr>\n};
  print qq{<tr><td>&#8505;&#65039; автономия &middot; сноска</td><td>} . esc($v2_fn) . qq{</td></tr>\n};
  my $costcls = $v2_cost_cls ? qq{ class="$v2_cost_cls"} : '';
  print qq{<tr><td>&#128176; Стоимость &middot; токены</td><td$costcls>} . esc($v2_cost) . qq{</td></tr>\n};
  print qq{<tr><td>&#128200; Тренд &middot; автономия/нед</td><td>} . esc($v2_t_auto) . qq{</td></tr>\n};
  print qq{<tr><td>&#128200; Тренд &middot; init-прогоны/нед</td><td>} . esc($v2_t_init) . qq{</td></tr>\n};
  print qq{<tr><td>&#128200; Тренд &middot; revise/нед</td><td>} . esc($v2_t_rev) . qq{</td></tr>\n};
  print qq{<tr><td class="warn">&#9888;&#65039; Cross-check осей</td><td class="warn">} . esc($v2_xchk) . qq{</td></tr>\n} if defined $v2_xchk;
  # eval-harness строка: печатается ТОЛЬКО при наличии last-run.json (иначе инертно)
  print qq{<tr><td>&#129514; % Resolved (eval &middot; gate=} . esc($eval_gate) . qq{)</td><td>} . esc($eval_pct) . qq{</td></tr>\n} if defined $eval_pct;
  print qq{</table></div>\n};
} else {
  print "DORA (окно ${days}д):\n";
  print "  deployment frequency : $freq\n";
  print "  lead time            : $lead\n";
  print "  change failure rate  : $cfr\n";
  print "  mttr                 : $mttr\n";
  printf "  автономия            : %s — %s цели ≥%d%%\n", $auto_s, ($auto_ok ? 'ДОСТИГАЕТ' : 'НЕ достигает'), $target;
  print "  гейты владельца      : $gates\n";
  # autonomy v2 — те же строки, что в --html (режимы симметричны)
  print "  intervention rate    : $v2_ir\n";
  print "  merged-as-is         : $v2_ma\n";
  print "  прогоны с тикетом    : $v2_tc\n";
  print "  коммиты с тикет-ссылкой : $v2_cr\n";
  print "  автономия · сноска   : $v2_fn\n";
  print "  стоимость · токены   : $v2_cost\n";
  print "  тренд · автономия    : $v2_t_auto\n";
  print "  тренд · init-прогоны : $v2_t_init\n";
  print "  тренд · revise       : $v2_t_rev\n";
  print "  cross-check осей     : $v2_xchk\n" if defined $v2_xchk;
  print "  % Resolved (eval)    : $eval_pct · gate=$eval_gate\n" if defined $eval_pct;
}
PERL
