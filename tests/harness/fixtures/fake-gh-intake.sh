#!/bin/sh
# Двойник gh для intake-тестов — кладётся в PATH под именем `gh`.
# Режимы через ENV:
#   FAKE_GH_DOWN=1      — любой вызов падает; stderr НАМЕРЕННО несёт fake-токен
#                         (adversarial: redact-путь intake.sh обязан не пропустить его в исход)
#   FAKE_GH_VISIBILITY  — PRIVATE (дефолт) | PUBLIC — ответ `repo view --json visibility`
#   FAKE_GH_DEDUP_HIT=1 — `issue list` возвращает существующий OPEN #77
#   FAKE_GH_DEDUP_CLOSED=1 — exact CLOSED #77 игнорируется; после create list также несёт OPEN #101
#   FAKE_GH_DEDUP_AMBIGUOUS=1 — два exact match (fail-closed dedup)
#   FAKE_GH_VIEW_RC     — exit-код `issue view` (verify-read), дефолт 0
#   FAKE_GH_VIEW_MISMATCH=1 — view возвращает неверный authored title
#   FAKE_GH_VIEW_CLOSED=1 — view возвращает state=CLOSED (race после OPEN list/reconcile)
#   FAKE_GH_NEW_NUMBER  — номер создаваемого issue (дефолт 101); задан пустым → URL без номера
#   FAKE_GH_DIR         — каталог артефактов вызова (gh-body.txt/gh-title.txt/gh-create-called)
# Настоящих секретов нет: FAKEGHTOKENSECRET* — маркер для grep-ассерта.
FAKE_TOKEN="FAKEGHTOKENSECRET1234567890ABCDEFGH"
[ -z "${FAKE_GH_ENV_STATE_FILE:-}" ] || {
  if [ -n "${OPENAI_API_KEY:-}${ANTHROPIC_API_KEY:-}${SSH_AUTH_SOCK:-}${XDG_CONFIG_HOME:-}" ] \
    || [ -z "${HOME:-}" ] || [ "${HOME:-}" = "${FAKE_GH_STATION_HOME:-__never__}" ] \
    || [ -e "${HOME:-/nonexistent}/station-secret" ]; then printf 'open\n'; else printf 'closed\n'; fi \
    >> "$FAKE_GH_ENV_STATE_FILE"
}
[ -z "${FAKE_GH_HOST_STATE_FILE:-}" ] || {
  if [ "${GH_HOST+x}" = x ]; then printf 'set\n' >> "$FAKE_GH_HOST_STATE_FILE"; else printf 'unset\n' >> "$FAKE_GH_HOST_STATE_FILE"; fi
}
[ -z "${FAKE_GH_GIT_STATE_FILE:-}" ] || {
  discovered=blocked
  git rev-parse --show-toplevel >/dev/null 2>&1 && discovered=open
  printf '%s|%s|%s\n' "${GIT_DIR-unset}" "${GIT_WORK_TREE-unset}" "$discovered" \
    >> "$FAKE_GH_GIT_STATE_FILE"
}
if [ "${FAKE_GH_REQUIRE_HOST_UNSET:-0}" = 1 ] && [ "${GH_HOST+x}" = x ]; then
  echo "ambient host reached gh child" >&2
  exit 97
fi
[ -z "${FAKE_GH_MARKER:-}" ] || printf 'called\n' >> "$FAKE_GH_MARKER"
[ -z "${FAKE_GH_DIR:-}" ] || printf '%s\n' "$*" >> "$FAKE_GH_DIR/gh-calls.txt"
if [ "${FAKE_GH_REQUIRE_HOST_QUALIFIED:-0}" = 1 ]; then
  case "$1 ${2:-}" in
    "repo view") case "${3:-}" in github.com/*/*) :;; *) exit 96;; esac;;
    "issue "*) prev=""; qualified=0; for a in "$@"; do
        [ "$prev" = "--repo" ] && case "$a" in github.com/*/*) qualified=1;; esac; prev="$a"; done
      [ "$qualified" -eq 1 ] || exit 96;;
  esac
fi

if [ "${FAKE_GH_DOWN:-0}" = "1" ]; then
  echo "gh: network error: Authorization: Bearer $FAKE_TOKEN" >&2
  exit 1
fi

case "$1 ${2:-}" in
  "repo view")
    if [ "${FAKE_GH_VISIBILITY_INVALID:-0}" = "1" ]; then
      printf '{"visibility":"PRIVATE","unexpected":true}\n'
    else
      repo="${3:-${FAKE_GH_REPO:-o/r}}"; repo="${repo#github.com/}"
      prev=""
      for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
      printf '{"nameWithOwner":"%s","visibility":"%s"}\n' "$repo" "${FAKE_GH_VISIBILITY:-PRIVATE}"
    fi
    exit 0;;
  "issue list")
    reconcile_mode="${FAKE_GH_RECONCILE_MODE:-}"
    [ "${FAKE_GH_RECONCILE_FAIL:-0}" != "1" ] || reconcile_mode=unavailable
    if [ -n "$reconcile_mode" ]; then
      d="${FAKE_GH_DIR:-.}"; count=0
      [ ! -f "$d/gh-list-total-count.txt" ] || count="$(cat "$d/gh-list-total-count.txt")"
      count=$((count + 1)); printf '%s\n' "$count" > "$d/gh-list-total-count.txt"
      if [ "$count" -ge 3 ]; then
        case "$reconcile_mode" in
          unavailable) echo "reconcile failed: token=$FAKE_TOKEN" >&2; exit 1;;
          invalid) printf 'not-json\n'; exit 0;;
          capped) perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode([map {{number=>$_+1,title=>"unrelated $_",state=>"OPEN"}} 0..999]),"\n"'; exit 0;;
          ambiguous|mismatch)
            FAKE_TITLE_FILE="$d/gh-title.txt" FAKE_RECONCILE_MODE="$reconcile_mode" perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
              open my $fh,"<:raw",$ENV{FAKE_TITLE_FILE} or exit 2; local $/; my $raw=<$fh>//q{};
              $raw=~s/\r?\n\z//; my $title=decode("UTF-8",$raw,FB_CROAK);
              my @n=$ENV{FAKE_RECONCILE_MODE} eq q{ambiguous} ? (101,102) : (102);
              print JSON::PP->new->utf8->canonical->encode([map {{number=>$_,title=>$title,state=>"OPEN"}} @n]),"\n";
            '
            exit $?;;
        esac
      fi
    fi
    if [ -n "${FAKE_GH_LIST_MARKER:-}" ]; then : > "$FAKE_GH_LIST_MARKER"; fi
    if [ -n "${FAKE_GH_LIST_PAUSE:-}" ]; then
      pause_record="${FAKE_GH_DIR:-.}/gh-pause-used"
      if [ "${FAKE_GH_LIST_PAUSE_ONCE:-0}" != 1 ] || [ ! -e "$pause_record" ]; then
        : > "$pause_record"; sleep "$FAKE_GH_LIST_PAUSE"
      fi
    fi
    if [ "${FAKE_GH_LATE_HIT:-0}" = "1" ]; then
      d="${FAKE_GH_DIR:-.}"; count=0; [ ! -f "$d/gh-list-count.txt" ] || count="$(cat "$d/gh-list-count.txt")"
      count=$((count + 1)); printf '%s\n' "$count" > "$d/gh-list-count.txt"
      if [ "$count" -ge 2 ]; then
        printf '[{"number":77,"title":"[Owner] late existing ticket","state":"OPEN"}]\n'; exit 0
      fi
    fi
    if [ "${FAKE_GH_CAPPED:-0}" = "1" ]; then
      perl -MJSON::PP -e 'print JSON::PP->new->canonical->encode([map {{number=>$_+1,title=>"unrelated $_",state=>"OPEN"}} 0..999]),"\n"'
      exit 0
    fi
    if [ "${FAKE_GH_DEDUP_AMBIGUOUS:-0}" = "1" ]; then
      printf '[{"number":77,"title":"[Owner] существующий тикет","state":"OPEN"},{"number":78,"title":"[Owner] существующий тикет","state":"OPEN"}]\n'
    elif [ "${FAKE_GH_DEDUP_HIT:-0}" = "1" ]; then
      printf '[{"number":77,"title":"[Owner] существующий тикет","state":"OPEN"}]\n'
    elif [ "${FAKE_GH_DEDUP_CLOSED:-0}" = "1" ]; then
      if [ -f "${FAKE_GH_DIR:-.}/gh-create-called" ]; then
        d="${FAKE_GH_DIR:-.}"
        FAKE_TITLE_FILE="$d/gh-title.txt" FAKE_NUMBER_FILE="$d/gh-number.txt" perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
          open my $fh,"<:raw",$ENV{FAKE_TITLE_FILE} or exit 2; local $/; my $raw=<$fh>//q{};
          $raw=~s/\r?\n\z//; my $title=decode("UTF-8",$raw,FB_CROAK); my $number=101;
          if (open my $nf,"<",$ENV{FAKE_NUMBER_FILE}) { my $n=<$nf>//q{}; $number=$1 if $n=~/\A([1-9][0-9]*)/ }
          print JSON::PP->new->utf8->canonical->encode([
            {number=>77,title=>$title,state=>"CLOSED"},
            {number=>0+$number,title=>$title,state=>"OPEN"}
          ]),"\n";
        '
      else
        printf '[{"number":77,"title":"[Owner] closed exact ticket","state":"CLOSED"}]\n'
      fi
    elif [ "${FAKE_GH_LIST_INVALID:-0}" = "1" ]; then
      printf 'not-json\n'
    elif [ -f "${FAKE_GH_DIR:-.}/gh-title.txt" ]; then
      d="${FAKE_GH_DIR:-.}"
      FAKE_TITLE_FILE="$d/gh-title.txt" FAKE_NUMBER_FILE="$d/gh-number.txt" perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
        open my $fh,"<:raw",$ENV{FAKE_TITLE_FILE} or exit 2; local $/; my $raw=<$fh>//q{};
        $raw =~ s/\r?\n\z//; my $title=decode("UTF-8",$raw,FB_CROAK); my $number=101;
        if (open my $nf,"<",$ENV{FAKE_NUMBER_FILE}) { my $n=<$nf>//q{}; $number=$1 if $n=~/\A([1-9][0-9]*)/ }
        print JSON::PP->new->utf8->canonical->encode([{number=>0+$number,title=>$title,state=>"OPEN"}]),"\n";
      '
    else
      printf '[]\n'
    fi
    exit 0;;
  "issue create")
    d="${FAKE_GH_DIR:-.}"
    cat > "$d/gh-body.txt"
    prev=""
    for a in "$@"; do
      [ "$prev" = "--title" ] && printf '%s\n' "$a" > "$d/gh-title.txt"
      prev="$a"
    done
    : > "$d/gh-create-called"
    [ -z "${FAKE_GH_CHMOD_AUDIT:-}" ] || chmod 0400 "$FAKE_GH_CHMOD_AUDIT"
    if [ -n "${FAKE_GH_NEW_NUMBER+x}" ] && [ -z "$FAKE_GH_NEW_NUMBER" ]; then
      echo "https://github.com/o/r/issues/"
      exit 0
    fi
    number="${FAKE_GH_NEW_NUMBER:-101}"
    printf '%s\n' "$number" > "$d/gh-number.txt"
    repo="${FAKE_GH_REPO:-o/r}"; prev=""
    for a in "$@"; do [ "$prev" = "--repo" ] && repo="$a"; prev="$a"; done
    repo="${repo#github.com/}"
    echo "https://github.com/$repo/issues/$number"
    exit 0;;
  "issue view")
    if [ "${FAKE_GH_VIEW_RC:-0}" != "0" ]; then
      echo "view failed: token=$FAKE_TOKEN" >&2
      exit "${FAKE_GH_VIEW_RC}"
    fi
    d="${FAKE_GH_DIR:-.}"
    number="${3:-0}"
    title_file="$d/gh-title.txt"
    if [ "${FAKE_GH_VIEW_MISMATCH:-0}" = "1" ]; then
      printf '%s\n' '[Owner] wrong semantic title' > "$d/gh-view-title.txt"
      title_file="$d/gh-view-title.txt"
    elif [ "$number" = "77" ] || [ "$number" = "78" ]; then
      if [ "${FAKE_GH_LATE_HIT:-0}" = 1 ]; then
        printf '%s\n' '[Owner] late existing ticket' > "$d/gh-view-title.txt"
      else
        printf '%s\n' '[Owner] существующий тикет' > "$d/gh-view-title.txt"
      fi
      title_file="$d/gh-view-title.txt"
    elif [ ! -f "$title_file" ]; then
      printf '%s\n' '[Owner] существующий тикет' > "$d/gh-view-title.txt"
      title_file="$d/gh-view-title.txt"
    fi
    body_file="$d/gh-body.txt"
    if [ "$number" = "77" ] || [ "$number" = "78" ]; then
      printf '%s' "${FAKE_GH_EXISTING_BODY:-}" > "$d/gh-view-body.txt"
      body_file="$d/gh-view-body.txt"
    fi
    if [ "${FAKE_GH_VIEW_BODY_MISMATCH:-0}" = "1" ]; then
      printf '%s' '[Owner] wrong semantic body' > "$d/gh-view-body.txt"
      body_file="$d/gh-view-body.txt"
    fi
    [ -f "$body_file" ] || : > "$body_file"
    FAKE_NUMBER="$number" FAKE_TITLE_FILE="$title_file" FAKE_BODY_FILE="$body_file" \
      FAKE_GH_VIEW_STATE="$( [ "${FAKE_GH_VIEW_CLOSED:-0}" = 1 ] && printf CLOSED || printf OPEN )" \
      perl -MJSON::PP -MEncode=decode,FB_CROAK -e '
      open my $fh,"<:raw",$ENV{FAKE_TITLE_FILE} or exit 2; local $/; my $raw=<$fh> // q{};
      $raw =~ s/\r?\n\z//; my $title=decode("UTF-8",$raw,FB_CROAK);
      open my $bf,"<:raw",$ENV{FAKE_BODY_FILE} or exit 2; my $body_raw=<$bf>//q{};
      my $body=decode("UTF-8",$body_raw,FB_CROAK);
      my $state=$ENV{FAKE_GH_VIEW_STATE}//"OPEN";
      print JSON::PP->new->utf8->canonical->encode({number=>0+$ENV{FAKE_NUMBER},title=>$title,body=>$body,state=>$state}),"\n";
    '
    if [ -n "${FAKE_GH_SWAP_SPEC_DIR:-}" ]; then
      mv "$FAKE_GH_SWAP_SPEC_DIR" "$FAKE_GH_SWAP_SPEC_DIR.real" || exit 9
      ln -s "$FAKE_GH_SWAP_TARGET" "$FAKE_GH_SWAP_SPEC_DIR" || exit 9
    fi
    exit 0;;
esac
exit 0
