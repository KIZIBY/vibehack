# scripts/lib/deck-lib.pl — общие perl-хелперы HTML-дашборда пайплайна (Flight Deck).
#
# Назначение — анти-дрейф: парсинг state.md/audit.md, цвета, иконки и трактовка гейтов живут
# ЗДЕСЬ один раз; pipeline-dashboard.sh и любые будущие потребители не держат параллельных копий.
#
# Подключение (из perl-heredoc; SELF_DIR прокидывает bash-обёртка через ENV):
#   do "$ENV{SELF_DIR}/lib/deck-lib.pl" or die "...: " . ($@ || $!);
#
# Состав:
#   esc($s)         — HTML-экранирование (& < >)
#   ts2e($ts)       — ISO-8601 UTC → epoch; undef на битом/range-невалидном ts (месяц 13 и т.п.)
#   dur($sec)       — секунды → человекочитаемо (42s / 3m 05s / 2h 07m)
#   icon($c)        — чекбокс state.md ('x'|'-'|' ') → ✅ 🔵 ⬜
#   gate_cls($v)    — значение гейта → CSS-класс ok|bad|warn|pending (green/PASS/approved→ok,
#                     red/FAIL/abort/MUST-FLAG>0→bad, yellow и прочее→warn)
#   conf_worst(\@c) — worst-of цвет строк ## Confidence (red>yellow>green>«—»); ascii-строка
#   parse_state($d) — $d/state.md → hashref прогона: dir/disp/feature/scope/ticket
#                     (плейсхолдер «—» нормализуется в '')/started/updated/stages/gates/conf
#                     (## Confidence, [[key,val],…])/units + пустые rows/total под audit; undef, если
#                     state.md не открылся
#   parse_audit($d) — $d/audit.md → (\@rows, $total): строки таймлайна [ts, event, detail, dur]
#                     с FIFO-спариванием :start/:done, сбросом pending-start по :invalidated
#                     и общей длительностью прогона
#
# Формат state.md/audit.md — frozen contract (I-6), генератор scripts/pipeline-state.sh.
# Библиотека без side effects: только subs, никакого I/O при загрузке.
use strict; use warnings; use utf8;
use Time::Local qw(timegm);
use Encode qw(decode);

sub esc { my $s = shift // ''; $s =~ s/&/&amp;/g; $s =~ s/</&lt;/g; $s =~ s/>/&gt;/g; $s }
# eval: формально-валидный, но range-невалидный ts (месяц 13, час 24…) в рукописной строке
# audit.md не должен ронять весь рендер — такая строка просто остаётся без epoch/длительности
sub ts2e { my $t = shift // ''; return $t =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z/ ? eval { timegm($6,$5,$4,$3,$2-1,$1) } : undef }
sub dur { my $s = shift; return '' unless defined $s && $s >= 0;
  return $s < 60 ? "${s}s" : $s < 3600 ? sprintf("%dm %02ds",$s/60,$s%60) : sprintf("%dh %02dm",$s/3600,($s%3600)/60) }
sub icon { my $c = shift // ' '; return $c eq 'x' ? '&#9989;' : $c eq '-' ? '&#128309;' : '&#11036;' } # ✅ 🔵 ⬜
sub gate_cls { my $v = shift // "\x{2014}";
  return 'pending' if $v =~ /^\x{2014}/ || $v eq '' || $v eq '-';
  return 'bad' if $v =~ /MUST-FLAG:\s*[1-9]/ || $v =~ /^(FAIL|abort)/ || $v =~ /^red\b/;
  return 'ok'  if $v =~ /MUST-FLAG:\s*0(?![0-9])/ || $v =~ /^(approved|PASS)/ || $v =~ /^green\b/;
  return 'warn' }

# worst-of цвет по строкам ## Confidence (red>yellow>green>«—»).
# Возвращает ascii-строку цвета (green|yellow|red) или «—», если деклараций нет / все «—».
# Питает Conf-колонку обоих дашбордов (worst-of), gate_cls красит её по этой же строке.
sub conf_worst {
  my %rk = (red=>3, yellow=>2, green=>1);
  my ($w, $b) = ("\x{2014}", 0);
  for (@{$_[0] // []}) {
    my ($c) = $_->[1] =~ /^(green|yellow|red)\b/;
    ($b, $w) = ($rk{$c}, $c) if $c && $rk{$c} > $b;
  }
  $w
}

sub parse_state {
  my ($d) = @_;
  # $d — байты из ARGV (для open); disp — декодированная строка для вывода в :utf8 STDOUT
  # (иначе кириллические имена каталогов рендерятся дважды закодированными).
  # decode с CHECK потребляет исходник in-place — передаём КОПИЮ, иначе $d пустеет и open ломается
  my $bytes = $d;
  my $disp = eval { decode('UTF-8', $bytes, Encode::FB_CROAK) } // $d;
  my %r = (dir=>$d, disp=>$disp, feature=>'', scope=>'', ticket=>'', started=>'', updated=>'', stages=>[], gates=>{}, conf=>[], units=>[], rows=>[], total=>'');
  open(my $f, '<:utf8', "$d/state.md") or return undef;
  while (<$f>) {
    chomp;
    if    (/^# Pipeline State \x{2014} (.*)/)                    { $r{feature} = $1 }
    elsif (/^- Scope: (.*)/)                                     { $r{scope} = $1 }
    # связь прогона с тикетом; «—» = плейсхолдер «без тикета», не рендерим
    elsif (/^- Ticket: (.*)/)                                    { $r{ticket} = $1 eq "\x{2014}" ? '' : $1 }
    elsif (/^- Started: (.*)/)                                   { $r{started} = $1 }
    elsif (/^- Updated: (.*)/)                                   { $r{updated} = $1 }
    elsif (/^- \[([ x-])\] (stage-\S+)/)                         { push @{$r{stages}}, [$2, $1] }
    elsif (/^- \[([ x-])\] unit:(.*)/)                           { push @{$r{units}}, [$2, $1] }
    elsif (/^- (constitution-gate|user-approval|quality-verdict): (.*)/) { $r{gates}{$1} = $2 }
    # секция ## Confidence — светофор уверенности на переходах стадий.
    # Строки без чекбокса, поэтому не пересекаются с stage-/unit-ветками выше; идёт после gates.
    elsif (/^- (confidence-stage-\S+): (.*)/)                            { push @{$r{conf}}, [$1, $2] }
  }
  close $f;
  return \%r;
}

# pair_events — ЧИСТЫЙ парсер audit.md с FIFO-спариванием :start/:done.
# Единственный источник спаривания: Flight Deck (parse_audit ниже, берёт 4-tuple); epoch/
# start_epoch отдаются для любых будущих потребителей (экспорт трейсов) — копию спаривания не заводить.
# Возвращает (\@events, $total, $first_epoch, $last_epoch); каждое событие — хэш:
#   { ts, epoch, event, detail, dur (строка), start_epoch (для :done — эпоха спаренного :start, иначе undef) }
sub pair_events {
  my ($d) = @_;
  my (@ev, %startq, $first, $last);
  if (open(my $a, '<:utf8', "$d/audit.md")) {
    while (<$a>) {
      chomp;
      next unless /^\| (.*?) \| (.*?) \| (.*?) \|$/;
      my ($ts, $name, $det) = ($1, $2, $3);
      next if $ts eq 'ts (UTC)' || $ts =~ /^-+$/;
      my $e = ts2e($ts);
      if (defined $e) { $first //= $e; $last = $e }
      my ($dd, $se) = ('', undef);
      # FIFO-очередь per имя: параллельные одноимённые агенты спариваются первый-start ↔ первый-done
      # (точная атрибуция при пересечении невозможна из плоского журнала — очередь честнее перезаписи)
      if    ($name =~ /^(.*):start$/) { push @{$startq{$1}}, $e }
      # re-open ранней стадии инвалидирует незавершённую downstream-попытку.
      # Удаляем pending FIFO-start без completed span: следующий :done спарится только с новым :start.
      elsif ($name =~ /^(.*):invalidated$/) { delete $startq{$1} }
      elsif ($name =~ /^(.*):done$/ && @{$startq{$1} // []}) {
        my $s = shift @{$startq{$1}};
        if (defined $s) { $se = $s; $dd = dur($e - $s) if defined $e }
      }
      push @ev, { ts=>$ts, epoch=>$e, event=>$name, detail=>$det, dur=>$dd, start_epoch=>$se };
    }
    close $a;
  }
  my $total = (defined $first && defined $last) ? dur($last - $first) : '';
  return (\@ev, $total, $first, $last);
}

sub parse_audit {
  my ($d) = @_;
  my ($ev, $total) = pair_events($d);   # дашборд потребляет тот же чистый спариватель
  my @rows = map { [ $_->{ts}, $_->{event}, $_->{detail}, $_->{dur} ] } @$ev;
  return (\@rows, $total);
}

1;
