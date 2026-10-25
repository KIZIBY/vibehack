#!/usr/bin/env bash
# pipeline-dashboard.sh — Flight Deck: статический HTML-дашборд прогонов /pipeline.
#
# Источник истины — репозиторий: рендерит specs/*/state.md + audit.md в самодостаточный HTML
# (per-run trace: этапы → гейты → юниты → таймлайн событий с длительностями `X:start`→`X:done`)
# плюс DORA-фрагмент scripts/dora-metrics.sh --html. Никаких демонов/БД/внешних ресурсов — файл
# открывается локально. Семантика событий близка к GenAI-трейсингу (agent:*:start|done ≈ invoke_agent).
#
# Зависимость: scripts/lib/deck-lib.pl — общие perl-хелперы/парсеры (одна копия, анти-дрейф).
#
# Usage: bash scripts/pipeline-dashboard.sh [repo-root] [output.html]
#   repo-root по умолчанию: . · output по умолчанию: docs/pipeline-dashboard.html
# Exit: 0 (пустой specs/ = валидный пустой дашборд) · 2 = repo-root не найден
set -euo pipefail

ROOT="${1:-.}"
OUT="${2:-docs/pipeline-dashboard.html}"
# SELF_DIR — ДО cd "$ROOT": при относительном вызове (bash scripts/pipeline-dashboard.sh <dir>)
# dirname "$0" относителен исходному cwd и после cd перестаёт существовать
SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
[ -d "$ROOT" ] || { echo "pipeline-dashboard: FATAL: нет каталога $ROOT" >&2; exit 2; }
cd "$ROOT"

dirs=()
for s in specs/*/state.md; do
  [ -f "$s" ] && dirs+=("$(dirname "$s")")
done

mkdir -p "$(dirname "$OUT")"
# атомарная запись: рендер в tmp, mv только при успехе — упавший perl (битый audit.md и т.п.)
# не должен затирать прежний дашборд усечённым файлом (находка ревью 2026-07-02)
TMP_OUT="$OUT.tmp.$$"

# DORA-панель (advisory): фрагмент от dora-metrics.sh, если скрипт рядом; сбой → панель пропускается
DORA_FRAG="$TMP_OUT.dora"
if [ -f "$SELF_DIR/dora-metrics.sh" ]; then
  bash "$SELF_DIR/dora-metrics.sh" . --html > "$DORA_FRAG" 2>/dev/null || : > "$DORA_FRAG"
else
  : > "$DORA_FRAG"
fi

if ! GEN_TS="$(date -u +%FT%TZ)" DORA_FRAG="$DORA_FRAG" SELF_DIR="$SELF_DIR" perl - "${dirs[@]:-}" > "$TMP_OUT" <<'PERL'
use strict; use warnings; use utf8;
binmode STDOUT, ':utf8';

# Хелперы (esc/ts2e/dur/icon/gate_cls) и парсеры state.md/audit.md — общая библиотека
# scripts/lib/deck-lib.pl (одна копия парсеров — анти-дрейф).
# SELF_DIR прокинут из bash через ENV; провал загрузки → die → рендер падает целиком,
# и обёртка НЕ трогает прежний HTML (та же атомарная запись tmp/mv, что и при битом audit.md).
do "$ENV{SELF_DIR}/lib/deck-lib.pl"
  or die "pipeline-dashboard: deck-lib не загрузился ($ENV{SELF_DIR}/lib/deck-lib.pl): " . ($@ || $! || 'файл вернул ложь') . "\n";

my @runs;
for my $d (grep { length } @ARGV) {
  # parse_state → undef, если state.md нет; rows/total прогона — из audit.md
  # (FIFO-спаривание одноимённых :start/:done живёт в parse_audit)
  my $r = parse_state($d) or next;
  ($r->{rows}, $r->{total}) = parse_audit($d);
  push @runs, $r;
}
@runs = sort { $a->{dir} cmp $b->{dir} } @runs;

my $gen = $ENV{GEN_TS} // '';
print <<"HEAD";
<!doctype html><html lang="ru"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Pipeline Flight Deck</title>
<style>
:root{--bg:#0f1117;--card:#171a23;--line:#262b38;--fg:#d7dce6;--dim:#8b93a7;--ok:#3fb950;--bad:#f85149;--warn:#d29922;--acc:#58a6ff}
*{box-sizing:border-box}body{margin:0;padding:24px;background:var(--bg);color:var(--fg);font:14px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace}
h1{font-size:20px;margin:0 0 4px}h2{font-size:15px;margin:0 0 10px;color:var(--acc)}
.sub{color:var(--dim);margin-bottom:20px}
table{border-collapse:collapse;width:100%;margin:8px 0}
th,td{border:1px solid var(--line);padding:5px 9px;text-align:left;vertical-align:top}
th{color:var(--dim);font-weight:600;background:#12141c}
.card{background:var(--card);border:1px solid var(--line);border-radius:10px;padding:16px 18px;margin:0 0 18px}
.ok{color:var(--ok)}.bad{color:var(--bad)}.warn{color:var(--warn)}.pending{color:var(--dim)}
.meta{color:var(--dim);font-size:12px}
.stages{font-size:17px;letter-spacing:2px}
details{margin-top:8px}summary{cursor:pointer;color:var(--acc)}
.wrap{overflow-x:auto}
a{color:var(--acc);text-decoration:none}
.empty{color:var(--dim);padding:30px;text-align:center;border:1px dashed var(--line);border-radius:10px}
</style></head><body>
<h1>&#128640; Pipeline Flight Deck</h1>
<div class="sub">Сгенерировано: $gen &middot; источник: <code>specs/*/state.md + audit.md + docs/ops-journal.md + git</code> &middot; <code>scripts/pipeline-dashboard.sh</code></div>
HEAD

# DORA-панель — доверенный фрагмент собственного генератора (dora-metrics.sh --html)
if (my $df = $ENV{DORA_FRAG}) {
  if (open(my $h, '<:utf8', $df)) { local $/; my $c = <$h>; print $c if defined $c && length $c; close $h }
}

if (!@runs) {
  print qq{<div class="empty">Прогонов пока нет — state.md появляется после \`pipeline-state.sh init\` (шаг «Подготовка» /pipeline).</div>\n};
} else {
  print qq{<h2>Обзор прогонов (}.scalar(@runs).qq{)</h2><div class="wrap"><table><tr><th>Прогон</th><th>Фича</th><th>Scope</th><th>Этапы 1&middot;2&middot;3&middot;4</th><th>Conf</th><th>Approve</th><th>Вердикт</th><th>Юниты</th><th>Длит.</th><th>Обновлён</th></tr>\n};
  my $i = 0;
  for my $r (@runs) {
    my $anchor = 'run-' . ++$i;   # индексный якорь: уникален и не вырождается на не-ASCII именах каталогов
    my $st = join '', map { icon($_->[1]) } @{$r->{stages}};
    my $ud = scalar(grep { $_->[1] eq 'x' } @{$r->{units}});
    my $ut = scalar(@{$r->{units}});
    my $ap = $r->{gates}{'user-approval'} // "\x{2014}";
    my $vd = $r->{gates}{'quality-verdict'} // "\x{2014}";
    # worst-of confidence по прогону → эмодзи-светофор; «—» = нет деклараций (pending, пусто)
    my $cw = conf_worst($r->{conf});
    my $cemo = $cw eq 'green' ? '&#128994;' : $cw eq 'yellow' ? '&#128993;' : $cw eq 'red' ? '&#128308;' : '';
    printf qq{<tr><td><a href="#%s">%s</a></td><td>%s</td><td>%s</td><td class="stages">%s</td><td class="%s">%s</td><td class="%s">%s</td><td class="%s">%s</td><td>%s</td><td>%s</td><td class="meta">%s</td></tr>\n},
      $anchor, esc($r->{disp}), esc($r->{feature}).($r->{ticket} ? qq{ <span class="meta">[}.esc($r->{ticket}).qq{]</span>} : ''), esc($r->{scope}), $st,
      gate_cls($cw), $cemo,
      gate_cls($ap), esc($ap =~ /^(\S+)/ ? $1 : $ap),
      gate_cls($vd), esc($vd =~ /^(\S+)/ ? $1 : $vd),
      ($ut ? "$ud/$ut" : "\x{2014}"), ($r->{total} || "\x{2014}"), esc($r->{updated});
  }
  print qq{</table></div>\n};

  # advisory (не блокирует): deferred-тикет в unattended иначе невидим —
  # прогоны без Ticket: перечисляются с рецептом догона (link-ticket идемпотентен)
  my @noticket = grep { !$_->{ticket} } @runs;
  if (@noticket) {
    print qq{<div class="meta">&#9888; advisory: SPEC_DIR без Ticket: }
        . join(', ', map { esc($_->{disp}) } @noticket)
        . qq{ &mdash; догон: <code>bash scripts/pipeline-state.sh link-ticket &lt;SPEC_DIR&gt; &lt;KEY&gt;</code></div>\n};
  }

  $i = 0;
  for my $r (@runs) {
    my $anchor = 'run-' . ++$i;
    print qq{<div class="card" id="$anchor"><h2>}.esc($r->{disp}).qq{ &middot; }.esc($r->{feature}).qq{</h2>\n};
    print qq{<div class="meta">scope: }.esc($r->{scope}).($r->{ticket} ? qq{ &middot; ticket: }.esc($r->{ticket}) : '').qq{ &middot; started: }.esc($r->{started}).qq{ &middot; updated: }.esc($r->{updated}).($r->{total} ? qq{ &middot; длительность: $r->{total}} : '').qq{</div>\n};
    print qq{<p class="stages">};
    print join ' &nbsp; ', map { icon($_->[1]).' '.esc($_->[0]) } @{$r->{stages}};
    print qq{</p>\n<table><tr><th>Гейт</th><th>Статус</th></tr>\n};
    for my $g ('constitution-gate','user-approval','quality-verdict') {
      my $v = $r->{gates}{$g} // "\x{2014}";
      printf qq{<tr><td>%s</td><td class="%s">%s</td></tr>\n}, $g, gate_cls($v), esc($v);
    }
    print qq{</table>\n};
    # блок confidence-строк рядом с гейтами — родной Flight Deck рендерит
    # причину ЦЕЛИКОМ (свой периметр). Отдельная таблица, чтобы не ломать цикл 3 гейтов выше.
    if (@{$r->{conf}}) {
      print qq{<table><tr><th>Confidence</th><th>Статус</th></tr>\n};
      for my $c (@{$r->{conf}}) {
        my ($cls, $emo) = (gate_cls($c->[1]), '');
        $emo = $cls eq 'ok' ? '&#128994; ' : $cls eq 'warn' ? '&#128993; ' : $cls eq 'bad' ? '&#128308; ' : '';
        printf qq{<tr><td>%s</td><td class="%s">%s%s</td></tr>\n}, esc($c->[0]), $cls, $emo, esc($c->[1]);
      }
      print qq{</table>\n};
    }
    if (@{$r->{units}}) {
      print qq{<table><tr><th>Юнит</th><th>Convergence-check</th></tr>\n};
      printf qq{<tr><td>%s</td><td>%s</td></tr>\n}, esc($_->[0]), icon($_->[1]) for @{$r->{units}};
      print qq{</table>\n};
    }
    if (@{$r->{rows}}) {
      print qq{<details open><summary>Таймлайн (}.scalar(@{$r->{rows}}).qq{ событий)</summary><div class="wrap"><table><tr><th>ts (UTC)</th><th>событие</th><th>детали</th><th>длит.</th></tr>\n};
      printf qq{<tr><td class="meta">%s</td><td>%s</td><td class="meta">%s</td><td>%s</td></tr>\n}, esc($_->[0]), esc($_->[1]), esc($_->[2]), $_->[3] for @{$r->{rows}};
      print qq{</table></div></details>\n};
    }
    print qq{</div>\n};
  }
}
print qq{</body></html>\n};
PERL
then
  rm -f "$TMP_OUT" "$DORA_FRAG"
  echo "pipeline-dashboard: FATAL: рендер не удался — прежний $OUT не тронут" >&2
  exit 1
fi
rm -f "$DORA_FRAG"
mv "$TMP_OUT" "$OUT"
echo "pipeline-dashboard: → $OUT ($(wc -c < "$OUT" | tr -d ' ') байт, прогонов: ${#dirs[@]})"
