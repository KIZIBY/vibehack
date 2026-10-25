#!/usr/bin/env bash
# agent-eval.sh — execution-grounded eval-harness («% Resolved»).
# Прогоняет курируемые задачи tests/agent-evals/NNN-slug/ через worktree/tmpdir-изоляцию и
# скорит по контракту SWE-bench: FAIL→PASS ∧ PASS→PASS (по exit-коду скрытого verify.sh, НЕ по прозе).
#
# Формат задачи: tests/agent-evals/NNN-slug/ с:
#   instruction.md  — что сделать (может нести блок <!-- eval:apply --> … <!-- /eval:apply --> с bash-
#                     правкой для детерминированного actor); подаётся как «хотелка».
#   verify.sh       — СКРЫТЫЙ судья (запускается в CWD=рабочая-копия; exit 0 = решено). ОБЯЗАТЕЛЕН.
#   snapshot.sh|snapshot/ — опц. детерминированное исходное состояние (скрипт готовит CWD | каталог копируется).
#   regress.sh      — опц. проверка «не сломано ранее проходившее» (PASS→PASS): exit 0 после apply.
#
# Контракт: baseline verify (ожидание FAIL) → apply/actor → final verify (PASS) [∧ regress PASS] = resolved.
# pass@k — задача решена, если ≥1 из k прогонов resolved. Инвариант-гейт (pass^k) — bash scripts/check.sh
# (или, если его нет, self-test сьют tests/harness/run-tests.sh) ОДИН раз на прогон (детерминированный
# actor: инварианты не варьируются между k); красный = прогон FAIL.
#
# ТРАСТ-ГРАНИЦА: verify.sh/snapshot.sh/apply/--actor — произвольный bash с правами оператора, БЕЗ sandbox.
# Гоняй только доверенные наборы (ревьюь как скрипты). Изоляция — репо-чистота, не machine-sandbox.
#
# Usage: bash scripts/agent-eval.sh [<TASKS_DIR>] [--out <file|->] [--k <n>] [--judge-only]
#                                   [--actor <cmd>] [--no-gate] [--keep]
#   env AGENT_EVAL_GATE_CMD — переопределяет команду инвариант-гейта (для тестов; дефолт scripts/check.sh).
# Exit: 0 (прогон отработал; % Resolved в отчёте) · 2 = каталога задач/аргумента нет.
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TASKS=""; OUT="-"; K=3; KEEP=0; JUDGE_ONLY=0; ACTOR=""; NOGATE=0
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?}"; shift 2;;
    --k) K="${2:?}"; shift 2;;
    --judge-only) JUDGE_ONLY=1; shift;;
    --actor) ACTOR="${2:?}"; shift 2;;
    --no-gate) NOGATE=1; shift;;
    --keep) KEEP=1; shift;;
    --*) echo "agent-eval: неизвестный флаг '$1'" >&2; exit 2;;
    *) TASKS="$1"; shift;;
  esac
done
[ -n "$TASKS" ] || TASKS="$ROOT/tests/agent-evals"
[ -d "$TASKS" ] || { echo "agent-eval: FATAL: нет каталога задач '$TASKS'" >&2; exit 2; }
case "$K" in ''|*[!0-9]*) echo "agent-eval: FATAL: --k должно быть целым" >&2; exit 2;; esac
[ "$K" -ge 1 ] || K=1

# tmp-рабочая директория самого прогонщика (файл записей) — mktemp 0700, trap на все сигналы
WORK="$(mktemp -d "${TMPDIR:-/tmp}/ageval.XXXXXX")" || { echo "agent-eval: FATAL: mktemp" >&2; exit 2; }
cleanup(){ [ -n "${WORK:-}" ] && [ -d "$WORK" ] && rm -rf "$WORK"; }
trap cleanup EXIT INT TERM HUP
REC="$WORK/records"; : > "$REC"

# --- обнаружение задач: каталоги с verify.sh, лексически по slug (детерминизм) ---
raw=""
for d in "$TASKS"/*/; do [ -d "$d" ] || continue; raw="$raw
$(basename "$d")"; done
slugs="$(printf '%s' "$raw" | grep -v '^$' | LC_ALL=C sort)"

# оценка объёма ВКЛЮЧАЯ гейт-член (честная модель)
ntask="$(printf '%s\n' "$slugs" | grep -c . || true)"
gate_note="+ инвариант-гейт (bash scripts/check.sh, 1×/прогон)"
[ "$NOGATE" -eq 1 ] && gate_note="(гейт отключён --no-gate)"
echo "agent-eval: $ntask задач × k=$K = $((ntask*K)) verify-прогонов $gate_note" >&2

# извлечь apply-блок из instruction.md (между маркерами) в файл; пусто если нет
extract_apply(){ # <instruction.md> <out.sh>
  [ -f "$1" ] || return 1
  awk '/<!-- eval:apply -->/{f=1;next} /<!-- \/eval:apply -->/{f=0} f' "$1" > "$2"
  [ -s "$2" ]
}

for slug in $slugs; do
  src="$TASKS/$slug"
  if [ ! -f "$src/verify.sh" ]; then
    echo "agent-eval: пропуск '$slug': нет verify.sh (invalid)" >&2
    printf 'TASK|%s|0|-|-|0|invalid-no-verify\n' "$slug" >> "$REC"; continue
  fi
  k=1
  while [ "$k" -le "$K" ]; do
    wd="$WORK/run-$slug-$k"; mkdir -p "$wd"
    # материализация snapshot (в рабочую копию, НИКОГДА не в исходную папку задачи — I-2)
    if [ -f "$src/snapshot.sh" ]; then
      if ! ( cd "$wd" && bash "$src/snapshot.sh" ) >/dev/null 2>&1; then
        printf 'TASK|%s|%d|-|-|0|error-snapshot-failed\n' "$slug" "$k" >> "$REC"
        [ "$KEEP" -eq 1 ] || rm -rf "$wd"; k=$((k+1)); continue
      fi
    elif [ -d "$src/snapshot" ]; then
      cp -R "$src/snapshot/." "$wd/" 2>/dev/null || true
    fi
    # baseline (ожидание FAIL/exit≠0)
    ( cd "$wd" && bash "$src/verify.sh" ) >/dev/null 2>&1; base_rc=$?
    # apply
    applied=1
    if [ -n "$ACTOR" ]; then
      ( cd "$wd" && AGENT_EVAL_INSTRUCTION="$src/instruction.md" eval "$ACTOR" ) >/dev/null 2>&1 || true
    elif extract_apply "$src/instruction.md" "$wd/.eval-apply.sh"; then
      ( cd "$wd" && bash "$wd/.eval-apply.sh" ) >/dev/null 2>&1 || true; rm -f "$wd/.eval-apply.sh"
    elif [ "$JUDGE_ONLY" -eq 1 ]; then
      applied=0   # судим уже применённое состояние (snapshot как есть)
    else
      printf 'TASK|%s|%d|%d|-|0|no-actor\n' "$slug" "$k" "$base_rc" >> "$REC"
      [ "$KEEP" -eq 1 ] || rm -rf "$wd"; k=$((k+1)); continue
    fi
    # final
    ( cd "$wd" && bash "$src/verify.sh" ) >/dev/null 2>&1; final_rc=$?
    # regress (PASS→PASS), если есть
    reg_ok=1
    if [ -f "$src/regress.sh" ]; then
      ( cd "$wd" && bash "$src/regress.sh" ) >/dev/null 2>&1 || reg_ok=0
    fi
    # скоринг: baseline FAIL (≠0) ∧ final PASS (=0) ∧ regress ok
    if [ "$base_rc" -eq 0 ]; then
      status="baseline-already-green"; resolved=0
    elif [ "$final_rc" -eq 0 ] && [ "$reg_ok" -eq 1 ]; then
      status="resolved"; resolved=1
    else
      status="not-resolved"; resolved=0
    fi
    printf 'TASK|%s|%d|%d|%d|%d|%s\n' "$slug" "$k" "$base_rc" "$final_rc" "$resolved" "$status" >> "$REC"
    [ "$KEEP" -eq 1 ] || rm -rf "$wd"
    k=$((k+1))
  done
done

# --- инвариант-гейт (pass^k), 1×/прогон; команда переопределяема env для тестов ---
if [ "$NOGATE" -eq 1 ]; then
  gate="skipped-flag"
else
  gcmd="${AGENT_EVAL_GATE_CMD:-}"
  if [ -z "$gcmd" ] && [ -f "$ROOT/scripts/check.sh" ]; then gcmd="bash $ROOT/scripts/check.sh"; fi
  if [ -z "$gcmd" ] && [ -f "$ROOT/tests/harness/run-tests.sh" ]; then gcmd="bash $ROOT/tests/harness/run-tests.sh --tier fast"; fi
  if [ -z "$gcmd" ]; then gate="skipped"
  elif ( eval "$gcmd" ) >/dev/null 2>&1; then gate="pass"
  else gate="fail"; fi
fi

STAMP="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo unknown)"

# --- сборка JSON в perl (свой jstr; без внешних JSON-тулов) ---
REC="$REC" GATE="$gate" STAMP="$STAMP" perl - > "$WORK/report.json" <<'PERL'
use strict; use warnings; use utf8;
binmode STDOUT, ':utf8';
sub jstr { my $s = shift // ''; $s =~ s/\\/\\\\/g; $s =~ s/"/\\"/g; $s =~ s/\n/ /g; $s =~ s/[\x00-\x1f]/ /g; '"'.$s.'"' }
sub num { my $v = shift; return '"-"' if !defined $v || $v eq '-' || $v eq ''; $v =~ /^-?\d+$/ ? $v : jstr($v) }
my ($rec,$gate,$stamp) = @ENV{qw(REC GATE STAMP)};
my (%runs,@order);
open(my $f,'<',$rec) or die "records: $!";
while (<$f>) { chomp; my @c = split /\|/; next unless @c && $c[0] eq 'TASK';
  my ($slug,$k,$base,$final,$res,$status) = @c[1..6];
  push @order,$slug unless exists $runs{$slug};
  push @{$runs{$slug}}, {k=>$k,base=>$base,final=>$final,res=>($res//0)+0,status=>($status//'')};
}
close $f;
my ($total,$resolved) = (0,0); my @tasks;
for my $slug (@order) {
  $total++;
  my $rs = $runs{$slug};
  my $passk = (grep { $_->{res} } @$rs) ? 1 : 0;   # pass@k: ≥1 прогон resolved
  $resolved += $passk;
  my $rj = join(',', map {
    '{"k":'.num($_->{k}).',"baseline":'.num($_->{base}).',"final":'.num($_->{final}).
    ',"resolved":'.($_->{res}?'true':'false').',"status":'.jstr($_->{status}).'}'
  } @$rs);
  push @tasks, '{"slug":'.jstr($slug).',"resolved":'.($passk?'true':'false').
    ',"k":'.scalar(@$rs).',"runs":['.$rj.']}';
}
my $pct = $total ? sprintf('%.1f',100*$resolved/$total) : '0.0';
# полный отчёт
print '{"schema":"agent-eval/1","total":'.$total.',"resolved":'.$resolved.
  ',"pct_resolved":'.$pct.',"invariant_gate":'.jstr($gate).
  ',"generated_at":'.jstr($stamp).',"tasks":['.join(',',@tasks).']}',"\n";
# минимальный last-run.json (сток плитки) — на STDERR-канал не идёт; пишем во второй файл
open(my $lr,'>:utf8',$ENV{REC}.'.lastrun') or die;
print $lr '{"pct_resolved":'.$pct.',"total":'.$total.',"resolved":'.$resolved.
  ',"invariant_gate":'.jstr($gate).',"generated_at":'.jstr($stamp).'}',"\n";
close $lr;
PERL
rc=$?
[ "$rc" -eq 0 ] && [ -s "$WORK/report.json" ] || { echo "agent-eval: FATAL: сборка отчёта не удалась (rc=$rc)" >&2; exit 2; }

# --- вывод полного отчёта ---
if [ "$OUT" = "-" ]; then cat "$WORK/report.json"; else mkdir -p "$(dirname "$OUT")"; cp "$WORK/report.json" "$OUT"; fi

# --- сток плитки: <TASKS>/last-run.json (generated, gitignored; НЕ audit.md — I-3) ---
if [ -f "$WORK/records.lastrun" ]; then cp "$WORK/records.lastrun" "$TASKS/last-run.json"; fi

# --- человекочитаемая сводка ---
pct="$(perl -ne 'print $1 if /"pct_resolved":([0-9.]+)/' "$WORK/report.json")"
tot="$(perl -ne 'print $1 if /"total":([0-9]+)/' "$WORK/report.json")"
res="$(perl -ne 'print $1 if /"resolved":([0-9]+),/' "$WORK/report.json")"
echo "agent-eval: % Resolved = ${pct}% ($res/$tot) · invariant_gate=$gate" >&2
