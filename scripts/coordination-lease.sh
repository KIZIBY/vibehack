#!/usr/bin/env bash
# coordination-lease.sh — take/release/list лизов координации параллельных сессий.
#
# Lease = tracked-файл coordination/leases/<slug>.lease (key:value; формат — coordination/README.md).
# Идентификатор сессии — имя worktree-ветки (git branch --show-current); поля host НЕТ (I-1).
# Семантика best-effort: git не даёт распределённый лок — lease виден другим только после
# push+fetch; перед take — fetch + уведомление сессий (конвенция docs/pipeline-rules.md).
# Guards: пути только repo-relative (абсолютный → отказ, I-1); ≤32 paths; файл ≤2048 байт
# (при превышении файл не оставляется); slug — только [A-Za-z0-9._-] (становится именем файла).
# Идемпотентность (I-2): повторный take своих же параметров → no-op exit 0; take чужого
# действующего → отказ с именем владельца; просроченный чужой → перезапись; release
# несуществующего → exit 0. События lease:take|release — best-effort в ops-journal (I-8),
# paths в detail не пишутся (I-1).
#
# Usage:
#   bash scripts/coordination-lease.sh take <slug> <scope: spec-dir|file|subsystem> <ttl_hours> <path>...
#   bash scripts/coordination-lease.sh release <slug>
#   bash scripts/coordination-lease.sh list
#   bash scripts/coordination-lease.sh check-paths --ref <git-ref> <path>...
#     публикационный lease-чек: пути против ЧУЖИХ действующих лизов из <git-ref>
#     (лизы читаются git show из ref, НЕ из локального дерева); свободно → пусто + exit 0;
#     конфликт → stdout-строки "<lease-файл> <session> <путь>" + exit 1; сбой чека → exit 2
#     (вызывающий сам решает fail-open, I-8). Глоб-семантика — та же, что в pre-commit хуке
#     (* не сквозь /, ** сквозь, ? один не-/ символ, остальное литерал, trailing / = префикс).
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "coordination-lease: FATAL: не внутри git-репозитория" >&2; exit 2; }
LEASES="$ROOT/coordination/leases"
CMD="${1:?usage: coordination-lease.sh <take|release|list> [slug scope ttl_hours path...]}"

die()  { echo "coordination-lease: FATAL: $*" >&2; exit 2; }
note() { echo "coordination-lease: $*"; }

sanitize() { # единая очистка значений перед записью (паттерн sanitize() pipeline-state.sh):
  # '|' ломает markdown-таблицы читателей, \n/\r инжектят поддельные key:value-строки
  local s="${1-}"
  s="${s//|/∕}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '%s' "$s"
}

session_id() { # имя worktree-ветки = id сессии; detached/unborn без имени → lease без владельца бессмыслен
  local b
  b="$(git branch --show-current 2>/dev/null || true)"
  [ -n "$b" ] || die "нет текущей ветки (detached HEAD?) — lease требует имени worktree-ветки: git checkout -b <ветка>"
  sanitize "$b"
}

lease_field() { # $1 файл, $2 ключ → первое значение (пусто, если ключа нет)
  sed -n "s/^$2: //p" "$1" | head -1
}

lease_expired() { # $1 файл → exit 0 = просрочен/битый (не действует), 1 = действует.
  # TTL-арифметика в perl (BSD/GNU date несовместимы по -d/-j); битый created/ttl = не lease
  # («битый ≠ действующий») — трактуется как просроченный.
  local created ttl
  created="$(lease_field "$1" created)"; ttl="$(lease_field "$1" ttl_hours)"
  case "$ttl" in ''|*[!0-9]*) return 0;; esac
  perl -e '
    use Time::Local;
    my ($c, $t) = @ARGV;
    if ($c =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my ($Y, $Mo, $D, $H, $Mi, $S) = ($1, $2, $3, $4, $5, $6);
      exit(time() > timegm($S, $Mi, $H, $D, $Mo - 1, $Y) + $t * 3600 ? 0 : 1);
    }
    exit 0;
  ' "$created" "$ttl"
}

lease_left() { # $1 файл → человекочитаемый остаток TTL: 'Nч MMм' | 'истёк' | 'битый'
  local created ttl
  created="$(lease_field "$1" created)"; ttl="$(lease_field "$1" ttl_hours)"
  case "$ttl" in ''|*[!0-9]*) echo "битый"; return 0;; esac
  perl -e '
    use Time::Local;
    my ($c, $t) = @ARGV;
    if ($c =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my ($Y, $Mo, $D, $H, $Mi, $S) = ($1, $2, $3, $4, $5, $6);
      my $left = timegm($S, $Mi, $H, $D, $Mo - 1, $Y) + $t * 3600 - time();
      if ($left <= 0) { print "истёк" } else { printf "%dч %02dм", int($left / 3600), int(($left % 3600) / 60) }
    } else { print "битый" }
  ' "$created" "$ttl"
}

lease_expires_epoch() { # $1 файл → epoch истечения (created+ttl) целым; пусто, если created/ttl битые.
  # ТА ЖЕ Time::Local-семантика, что lease_expired/lease_left (не вторая копия TTL-арифметики):
  # created+ttl_hours → absolute expiry epoch для JSON-поля expires_epoch (list --json).
  local created ttl
  created="$(lease_field "$1" created)"; ttl="$(lease_field "$1" ttl_hours)"
  case "$ttl" in ''|*[!0-9]*) return 0;; esac
  perl -e '
    use Time::Local;
    my ($c, $t) = @ARGV;
    if ($c =~ /^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})Z$/) {
      my ($Y, $Mo, $D, $H, $Mi, $S) = ($1, $2, $3, $4, $5, $6);
      print timegm($S, $Mi, $H, $D, $Mo - 1, $Y) + $t * 3600;
    }
  ' "$created" "$ttl"
}

ops_event() { # $1 event, $2 detail — телеметрия best-effort (I-8); paths в detail НЕ попадают (I-1)
  bash "$ROOT/scripts/ops-log.sh" "$1" "$2" >/dev/null 2>&1 || true
}

case "$CMD" in
  take)
    SLUG="${2:?slug required (имя lease-файла)}"
    SCOPE="${3:?scope required (spec-dir|file|subsystem)}"
    TTL="${4:?ttl_hours required (целое)}"
    shift 4
    [ $# -ge 1 ] || die "нужен хотя бы один path (repo-relative литерал или bash-глоб)"
    case "$SLUG" in ''|*[!A-Za-z0-9._-]*) die "slug '$SLUG' — только [A-Za-z0-9._-] (slug = имя файла в coordination/leases/)";; esac
    case "$SCOPE" in spec-dir|file|subsystem) ;; *) die "scope '$SCOPE' — ожидаю spec-dir|file|subsystem";; esac
    case "$TTL" in ''|*[!0-9]*) die "ttl_hours '$TTL' — ожидаю целое число часов";; esac
    [ $# -le 32 ] || die "paths: $# > 32 — лимит-guard; возьми scope=subsystem с глобом вместо перечисления"
    for p in "$@"; do
      case "$p" in /*) die "path '$p' абсолютный — в tracked lease только repo-relative пути (периметр I-1)";; esac
    done
    SESSION="$(session_id)"
    NL=$'\n'
    body="session: $SESSION${NL}scope: $SCOPE"
    for p in "$@"; do body="${body}${NL}path: $(sanitize "$p")"; done
    body="${body}${NL}created: $(date -u +%FT%TZ)${NL}ttl_hours: $TTL"
    F="$LEASES/$SLUG.lease"
    if [ -f "$F" ]; then
      owner="$(lease_field "$F" session)"
      if [ "$owner" = "$SESSION" ]; then
        if [ "$(grep -v '^created: ' "$F")" = "$(printf '%s\n' "$body" | grep -v '^created: ')" ]; then
          note "no-op: lease '$SLUG' уже взят этой сессией ($SESSION) с теми же параметрами (I-2)"
          exit 0
        fi
        note "lease '$SLUG' уже свой — обновляю параметры (без дубля)"
      elif lease_expired "$F"; then
        note "lease '$SLUG' сессии '$owner' просрочен/битый (created+ttl < now) — перезаписываю, старый стёрт"
      else
        die "lease '$SLUG' занят сессией '$owner' до истечения TTL ($(lease_left "$F")) — файл coordination/leases/$SLUG.lease; договорись с владельцем (конвенция docs/pipeline-rules.md) или дождись истечения"
      fi
    fi
    mkdir -p "$LEASES"
    tmp="$LEASES/.$SLUG.tmp.$$"
    printf '%s\n' "$body" > "$tmp"
    bytes="$(wc -c < "$tmp" | tr -d ' ')"
    if [ "$bytes" -gt 2048 ]; then
      rm -f "$tmp"
      die "lease-файл $bytes байт > 2048 — лимит-guard: сократи paths (глоб вместо перечисления); файл не записан"
    fi
    mv "$tmp" "$F"
    note "take: coordination/leases/$SLUG.lease (session=$SESSION scope=$SCOPE ttl=${TTL}h paths=$#)"
    note "  lease виден другим сессиям только после commit+push (best-effort, README)"
    ops_event "lease:take" "$SLUG scope=$SCOPE ttl=${TTL}h"
    ;;

  release)
    SLUG="${2:?slug required}"
    case "$SLUG" in ''|*[!A-Za-z0-9._-]*) die "slug '$SLUG' — только [A-Za-z0-9._-]";; esac
    F="$LEASES/$SLUG.lease"
    if [ ! -f "$F" ]; then
      note "release: lease '$SLUG' не существует — no-op (идемпотентно, I-2)"
      exit 0
    fi
    SESSION="$(session_id)"
    owner="$(lease_field "$F" session)"
    if [ "$owner" != "$SESSION" ] && ! lease_expired "$F"; then
      die "lease '$SLUG' принадлежит сессии '$owner' и не просрочен ($(lease_left "$F")) — чужой действующий lease не снимается (I-2); файл coordination/leases/$SLUG.lease"
    fi
    [ "$owner" != "$SESSION" ] && note "lease '$SLUG' сессии '$owner' просрочен/битый — снимаю (уборка легитимна)" || true
    rm -f "$F"
    note "release: coordination/leases/$SLUG.lease снят"
    ops_event "lease:release" "$SLUG"
    ;;

  list)
    # Аддитивный `list --json`: машиночитаемый JSON-массив активных лизов
    # для внешних сборщиков/дашбордов. Флаг детектируется ДО любой печати — БЕЗ флага ветка ниже
    # остаётся байт-в-байт прежней (регресс-инвариант I-6). Переиспользует lease_field/
    # lease_expired/lease_left/lease_expires_epoch — вторая копия TTL-арифметики не заводится.
    if [ "${2:-}" = "--json" ]; then
      # каталога нет → пустой массив (сборщик получит [], не ошибку — graceful, I-8)
      if [ ! -d "$LEASES" ]; then printf '[]\n'; exit 0; fi
      # собираем поля bash-парсером (единый на файл), JSON кодируем через JSON::PP (корректное
      # экранирование кавычек/спецсимволов в session/slug/scope).
      # tmp — ВНЕ $LEASES (tracked-каталог): сборщик read-only, ноль записи в проектный ROOT (I-2).
      jtmp="$(mktemp "${TMPDIR:-/tmp}/lease-json.XXXXXX")" || die "list --json: mktemp не удался"
      trap 'rm -f "$jtmp"' EXIT
      for f in "$LEASES"/*.lease; do
        [ -f "$f" ] || continue
        slug="$(basename "$f" .lease)"
        session="$(lease_field "$f" session)"
        scope="$(lease_field "$f" scope)"
        created="$(lease_field "$f" created)"
        ttl="$(lease_field "$f" ttl_hours)"
        expepoch="$(lease_expires_epoch "$f")"
        if lease_expired "$f"; then expired=1; else expired=0; fi
        # TAB-разделённые поля во временный файл; perl соберёт валидный JSON (значения не через argv —
        # чтобы кавычки/юникод/спецсимволы session/slug дошли до кодировщика без потерь).
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
          "$slug" "$session" "$scope" "$created" "$ttl" "$expepoch" "$expired" >> "$jtmp"
      done
      perl -MJSON::PP -e '
        use strict; use warnings;
        binmode STDOUT, ":raw";                 # ->utf8 отдаёт октеты — STDOUT :raw (как deck-lib-cli)
        my @out;
        open(my $fh, "<:encoding(UTF-8)", $ARGV[0]) or do { print "[]\n"; exit 0 };
        while (my $l = <$fh>) {
          chomp $l;
          next unless length $l;
          my ($slug, $session, $scope, $created, $ttl, $expepoch, $expired) = split /\t/, $l, 7;
          my %o = (
            slug    => defined $slug    ? $slug    : "",
            session => defined $session ? $session : "",
            scope   => defined $scope   ? $scope   : "",
            created => defined $created ? $created : "",
          );
          # ttl_hours/expires_epoch — числа, если валидны; иначе null (битый created/ttl)
          $o{ttl_hours}     = (defined $ttl && $ttl =~ /^[0-9]+$/) ? $ttl + 0 : undef;
          $o{expires_epoch} = (defined $expepoch && $expepoch =~ /^-?[0-9]+$/) ? $expepoch + 0 : undef;
          $o{expired}       = ($expired // "1") eq "0" ? JSON::PP::false : JSON::PP::true;
          push @out, \%o;
        }
        print JSON::PP->new->canonical->utf8->encode(\@out);
        print "\n";
      ' "$jtmp"
      exit 0
    fi
    [ -d "$LEASES" ] || { note "каталога coordination/leases/ нет — лизов нет"; exit 0; }
    found=0
    for f in "$LEASES"/*.lease; do
      [ -f "$f" ] || continue
      if [ "$found" -eq 0 ]; then printf '%-28s %-36s %-10s %s\n' "slug" "session" "scope" "истекает-через"; fi
      found=1
      printf '%-28s %-36s %-10s %s\n' \
        "$(basename "$f" .lease)" \
        "$(lease_field "$f" session)" \
        "$(lease_field "$f" scope)" \
        "$(lease_left "$f")"
    done
    [ "$found" -eq 0 ] && note "активных лизов нет (coordination/leases/ пуст)" || true
    ;;

  check-paths)
    # Пути публикации против чужих действующих лизов из <git-ref>.
    # Переиспользует lease_field/lease_expired (парсер и TTL-логика — одни на файл, не копия);
    # битый/аномальный lease → WARN в stderr + fail-open per-file (зеркало хука).
    [ "${2:-}" = "--ref" ] || die "check-paths: usage: check-paths --ref <git-ref> <path>..."
    REF="${3:?git-ref required (напр. origin/main или sha)}"
    shift 3
    [ $# -ge 1 ] || exit 0
    git -C "$ROOT" rev-parse --verify --quiet "$REF^{commit}" >/dev/null || die "check-paths: ref '$REF' не резолвится в коммит"
    ME="$(git branch --show-current 2>/dev/null || true)"
    if [ -z "$ME" ]; then
      echo "coordination-lease: WARN check-paths: нет имени ветки (detached HEAD?) — fail-open, проверка пропущена (зеркало pre-commit хука)" >&2
      exit 0
    fi
    LFILES="$(git -C "$ROOT" ls-tree -r --name-only "$REF" -- coordination/leases 2>/dev/null | grep '\.lease$' || true)"
    [ -n "$LFILES" ] || exit 0   # каталога/лизов в ref нет → свободно (graceful)
    TMPD="$(mktemp -d "${TMPDIR:-/tmp}/lease-check.XXXXXX")"
    trap 'rm -rf "$TMPD"' EXIT
    : > "$TMPD/active"
    while IFS= read -r lf; do
      [ -n "$lf" ] || continue
      if ! git -C "$ROOT" show "$REF:$lf" > "$TMPD/cur" 2>/dev/null; then
        echo "coordination-lease: WARN check-paths: $lf не читается из $REF — исключён (fail-open per-file)" >&2
        continue
      fi
      if [ "$(wc -c < "$TMPD/cur" | tr -d ' ')" -gt 2048 ]; then
        echo "coordination-lease: WARN check-paths: $lf >2048 байт — исключён (лимит-guard)" >&2
        continue
      fi
      OWNER="$(lease_field "$TMPD/cur" session)"
      if [ -z "$OWNER" ] || ! grep -q '^path: ' "$TMPD/cur"; then
        echo "coordination-lease: WARN check-paths: $lf битый (нет session/path) — исключён (fail-open per-file)" >&2
        continue
      fi
      if [ "$(grep -c '^path: ' "$TMPD/cur" | tr -d ' ')" -gt 32 ]; then
        echo "coordination-lease: WARN check-paths: $lf paths>32 — исключён (лимит-guard)" >&2
        continue
      fi
      if [ "$OWNER" = "$ME" ]; then continue; fi        # свой lease — пропуск
      if lease_expired "$TMPD/cur"; then continue; fi   # просрочен/битый TTL ≠ действующий
      while IFS= read -r g; do
        [ -n "$g" ] || continue
        printf '%s\t%s\t%s\n' "$lf" "$OWNER" "$g" >> "$TMPD/active"
      done < <(sed -n 's/^path: //p' "$TMPD/cur")
    done <<< "$LFILES"
    [ -s "$TMPD/active" ] || exit 0
    # один perl на все (lease-глоб × путь): конверсия глоба идентична pre-commit хуку (
    # анти-ReDoS: метасимволы только * ? **, остальное quotemeta; trailing / = префикс поддерева)
    perl -e '
      my ($af, @paths) = @ARGV;
      open(my $fh, "<", $af) or exit 2;
      my @L;
      while (my $l = <$fh>) {
        chomp $l;
        my ($lf, $own, $g) = split /\t/, $l, 3;
        next unless defined $g && length $g;
        my $re = "";
        for my $tok (split /(\*\*|\*|\?)/, $g) {
          next unless length $tok;
          if    ($tok eq "**") { $re .= ".*" }
          elsif ($tok eq "*")  { $re .= "[^/]*" }
          elsif ($tok eq "?")  { $re .= "[^/]" }
          else                 { $re .= quotemeta($tok) }
        }
        push @L, [$lf, $own, ($g =~ m{/$}) ? qr/^$re/ : qr/^$re$/];
      }
      my $rc = 0;
      for my $p (@paths) {
        for my $A (@L) {
          if ($p =~ $A->[2]) { print "$A->[0] $A->[1] $p\n"; $rc = 1; last }
        }
      }
      exit $rc;
    ' "$TMPD/active" "$@"
    ;;

  *)
    die "неизвестная команда '$CMD' — ожидаю take|release|list|check-paths (Usage в шапке скрипта)"
    ;;
esac
