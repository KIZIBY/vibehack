#!/usr/bin/env bash
# pipeline-state.sh — state-машина 4-этапного /pipeline (автономия P1: resume + детерминированные гейты).
#
# Per-SPEC_DIR файлы:
#   state.md — чекбоксы этапов + статусы гейтов (источник истины для resume);
#   audit.md — append-only журнал событий пайплайна (кто/когда/что решил).
#
# Зачем скрипт, а не промпт: гейты в тексте команд модель может «проскочить».
# `check` (и `stage-start` внутри) возвращает exit != 0 — stage-3 механически не стартует
# без user-approval=approved и `MUST-FLAG: 0`, даже если этап-промпт забыл про гейт.
# Severity NEEDS-INFO плоская строка не кодирует, поэтому V2 fail-safe требует общий
# NEEDS-INFO: 0 вместе с MUST-FLAG: 0 перед approval.
#
# Usage:
#   bash scripts/pipeline-state.sh init        <SPEC_DIR> "<описание>" [scope] [ticket]   # scope: feature|bugfix|enterprise (по умолчанию feature); nontrivial bugfix проходит полный V4 contract
#   bash scripts/pipeline-state.sh link-ticket <SPEC_DIR> <ticket>   # explicit relink; сериализован per SPEC
#   bash scripts/pipeline-state.sh link-ticket-cas <SPEC_DIR> <expected> <ticket> # intake compare-and-set
#   bash scripts/pipeline-state.sh stage-start <SPEC_DIR> <stage>   # [ ]→[-]; [-]=resume no-op; любой не-resume start сбрасывает stale current/downstream snapshot
#   bash scripts/pipeline-state.sh stage-done  <SPEC_DIR> <stage> [green|yellow|red] ["причина"]   # первичный done только из [-]; повторный [x] — frozen confidence-refresh; validation error не меняет state/audit
#   bash scripts/pipeline-state.sh ack         <SPEC_DIR> <stage> [кто]   # владелец снимает non-green confidence-гейт; повторный ack = no-op (I-2)
#   bash scripts/pipeline-state.sh gate        <SPEC_DIR> "MUST-FLAG: 0 · SHOULD-FLAG: 2 · NEEDS-INFO: 0"   # exact grammar, только в stage-2 [-]
#   bash scripts/pipeline-state.sh review-start   <SPEC_DIR> <architecture|critical-code|performance> <attempt64> <actor>
#   bash scripts/pipeline-state.sh review-finish  <SPEC_DIR> <role> <attempt64> <artifact-rel.md>
#   bash scripts/pipeline-state.sh review-blocked <SPEC_DIR> <role> <attempt64> <unavailable|lost|invalid-output>
#   bash scripts/pipeline-state.sh performance-run <SPEC_DIR> <attempt64>
#   bash scripts/pipeline-state.sh evidence-bind  <SPEC_DIR>
#   bash scripts/pipeline-state.sh design-bind    <SPEC_DIR>   # привязывает проверенный SDD+независимое review к Design-Root
#   bash scripts/pipeline-state.sh implementation-start <SPEC_DIR> <base-GitOid> <attempt64> <actor>
#   bash scripts/pipeline-state.sh implementation-content-root <SPEC_DIR> <base-GitOid> <implementation-attempt64>
#   bash scripts/pipeline-state.sh tdd-run <SPEC_DIR> <base-GitOid> <implementation-attempt64> <run64> <primary-TestId> <red|green|adjacent> <executed-TestId> <actor> -- <argv...>
#   bash scripts/pipeline-state.sh implementation-bind <SPEC_DIR> <base-GitOid> <attempt64>
#   bash scripts/pipeline-state.sh sdd-append      <SPEC_DIR> <revision> <change> <reason>   # только Stage 2
#   bash scripts/pipeline-state.sh delivery-append <SPEC_DIR> <revision> <result> <evidence> # только Stage 3
#   bash scripts/pipeline-state.sh approve     <SPEC_DIR> <approved|revise|abort> [кто]   # approved в V4 привязан к Design-Root
#   bash scripts/pipeline-state.sh units-set   <SPEC_DIR> "unit-a,unit-b,unit-c"   # юниты из plan.md (§Units of Work)
#   bash scripts/pipeline-state.sh unit-done   <SPEC_DIR> <unit>   # ТОЛЬКО после своего прогона convergence-check юнита
#   bash scripts/pipeline-state.sh verdict     <SPEC_DIR> <PASS|FAIL> [детали]   # только в stage-4 [-]; PASS требует nonblank evidence
#   bash scripts/pipeline-state.sh event       <SPEC_DIR> "<event>" ["detail"]   # trace-событие в audit.md; authority lifecycle names зарезервированы state-командами
#   bash scripts/pipeline-state.sh validate-state <SPEC_DIR>          # read-only shape validation for frozen runtime callers
#   bash scripts/pipeline-state.sh quality-head <SPEC_DIR>          # фиксирует committed candidate H перед final quality checks
#   bash scripts/pipeline-state.sh bind-head   <SPEC_DIR>           # CAS-привязка доказанного H→B в per-worktree ref
#   bash scripts/pipeline-state.sh check       <SPEC_DIR> <stage|publish>   # publish: section-valid 4×done + gate0/needs0 + approval + Units + PASS + confidence S4
#   bash scripts/pipeline-state.sh status      <SPEC_DIR>           # state + next (для resume)
# Конвенция имён event (близка к GenAI-трейсингу, читает pipeline-dashboard.sh):
#   agent:<имя>:start и agent:<имя>:done — спавн/финиш субагента (≈ invoke_agent); detail = задача/summary
#   tool:<имя>                           — значимый tool-вызов (≈ execute_tool); произвольные имена допустимы
#   usage:agent:<имя> · usage:stage-N    — фактический расход токенов; detail — плоские
#       пары: tokens=<int> [in=<int> out=<int>] [model=<id>] source=<subagent-report|hook|cli>.
#       КОНТРАКТ ЧЕСТНОСТИ (I-13): событие пишется ТОЛЬКО из реальных данных среды (отчёт
#       Agent-инструмента, hook, CLI-отчёт); оценка модели «по ощущениям» запрещена; расход самого
#       оркестратора не пишется, пока среда его не отдаёт. Без tokens=<int> И непустого source=
#       событие не засчитывается парсером dora-metrics.sh (исполняемый guard I-17).
#   intervention:manual                  — opt-in декларация ручной правки владельца мимо гейта
#       счётчик-аннотация к intervention rate, в формулу НЕ входит.
#   confidence:<stage> · confidence-ack:<stage>  — fail-safe сигнал уверенности стадии;
#       detail: level=<green|yellow|red> reason=<...> (для ack — by=<кто>). non-green блокирует
#       следующий check до ack владельца; green НИКОГДА не разблокирует; «—» = не задекларирован.
#   ВНИМАНИЕ: detail usage:*/intervention:manual/confidence:* попадает в ПУБЛИЧНЫЙ git-журнал
#       audit.md — без путей раннера, PII и названий приватных фич (I-1).
#   символ '|' и переводы строк в ЛЮБОМ значении заменяются при записи (sanitize) — целостность
#       таблицы audit.md И защита state.md от \n-инъекции строк-гейтов.
#   <stage> ::= stage-1-creative | stage-2-audit | stage-3-dev | stage-4-quality
# Units опциональны для feature/bugfix и обязательны для enterprise; задаются в stage-2, закрываются
# в stage-3; stage-4 не стартует, пока каждый объявленный юнит не отмечен unit-done.
set -euo pipefail

# `cd` is an authority primitive throughout this file.  An inherited CDPATH can redirect a
# relative `cd scripts` before the runtime has pinned its script/worktree roots, and can also emit
# attacker-controlled stdout into command substitutions.  Remove it before the first `cd`.
unset CDPATH 2>/dev/null || true

die()  { echo "pipeline-state: FATAL: $*" >&2; exit 2; }
note() { echo "pipeline-state: $*"; }

# Strict state/publish authority cannot inherit repository/config/object selectors from the
# invoking runtime. Keep bounded transport credentials untouched, but remove every Git namespace
# override before the first repository probe; local repository config remains available.
clear_git_authority_env() {
  local i=0
  while [ "$i" -lt 1024 ]; do
    unset "GIT_CONFIG_KEY_$i" "GIT_CONFIG_VALUE_$i" 2>/dev/null || true
    i=$((i + 1))
  done
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_IMPLICIT_WORK_TREE \
    GIT_CONFIG GIT_CONFIG_COUNT GIT_CONFIG_PARAMETERS GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM \
    GIT_CONFIG_NOSYSTEM GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
    GIT_QUARANTINE_PATH GIT_REPLACE_REF_BASE GIT_NAMESPACE GIT_SHALLOW_FILE GIT_GRAFT_FILE \
    GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM GIT_PREFIX GIT_INTERNAL_SUPER_PREFIX \
    GIT_ATTR_SOURCE GIT_EXEC_PATH GIT_TRACE GIT_TRACE_SETUP GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS \
    GIT_TRACE_PERFORMANCE GIT_TRACE_SHALLOW GIT_TRACE_CURL GIT_TRACE_REDACT GIT_TRACE2 \
    GIT_TRACE2_EVENT GIT_TRACE2_PERF 2>/dev/null || true
  # Private writer-to-helper capability.  A caller must never be able to select the
  # repository namespace consumed by an authority helper.
  unset HARNESS_INTERNAL_GIT_CONTEXT_V1 2>/dev/null || true
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0
  unset PERL5OPT PERL5LIB PERLLIB PERL_USE_UNSAFE_INC 2>/dev/null || true
}
clear_git_authority_env
# Reader selectors are private call-site capabilities, never caller-controlled policy.
unset PIPELINE_STATE_OUTPUT PIPELINE_STATE_TRUSTED_STDIN 2>/dev/null || true

PIPELINE_INVOCATION_CWD="$(pwd -P)" \
  || die "invocation cwd authority unavailable"
SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd -P)" \
  || die "script-owned root authority unavailable"
OUTER_REGISTERED_ROOT=""
OUTER_REGISTERED_GITDIR=""
OUTER_REGISTERED_COMMON=""
OUTER_REGISTERED_WORKTREE_ID=""
OUTER_REGISTERED_GITDIR_ID=""
OUTER_REGISTERED_COMMON_ID=""

discovered_registered_root() { # <probe> -> physical registered worktree root
  local raw
  raw="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$1" rev-parse --show-toplevel 2>/dev/null
  )" || return 1
  cd "$raw" 2>/dev/null && pwd -P
}

exact_registered_root() { # <candidate-root> -> same physical root, never a nested descendant repo
  local candidate discovered
  candidate="$(cd "$1" 2>/dev/null && pwd -P)" || return 1
  discovered="$(discovered_registered_root "$candidate")" || return 1
  [ "$candidate" = "$discovered" ] || return 1
  printf '%s\n' "$candidate"
}

path_is_within() { # <path> <root>; both physical or lexical absolute values
  case "$1" in "$2"|"$2"/*) return 0 ;; *) return 1 ;; esac
}

outer_canonical_spec_rel() {
  LC_ALL=C perl -e 'exit(($ARGV[0] // q{}) =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/ ? 0 : 1)' "$1"
}

set_outer_registered_root() { # one registered root -> pinned per-worktree gitdir/common-dir tuple
  local root="$1" gitdir_raw gitdir common_raw common
  gitdir_raw="$(git -C "$root" rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  gitdir="$(cd "$gitdir_raw" 2>/dev/null && pwd -P)" || return 1
  common_raw="$(git -C "$root" rev-parse --git-common-dir 2>/dev/null)" || return 1
  case "$common_raw" in
    /*) common="$(cd "$common_raw" 2>/dev/null && pwd -P)" ;;
    *) common="$(cd "$root/$common_raw" 2>/dev/null && pwd -P)" ;;
  esac || return 1
  OUTER_REGISTERED_ROOT="$root"
  OUTER_REGISTERED_GITDIR="$gitdir"
  OUTER_REGISTERED_COMMON="$common"
}

pin_outer_registered_worktree() { # <SPEC_DIR>; ignore any .git at/below SPEC_DIR
  local selector="${1:-}" script_candidate script_root=""
  local spec_parent explicit_candidate="" explicit_root="" chosen=""
  script_candidate="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd -P)" || return 2
  script_root="$(exact_registered_root "$script_candidate" 2>/dev/null || true)"

  # Canonical `specs/leaf` is repository-root relative even when invoked below that root.  When
  # this executable is external to the target fixture/project, Git discovery supplies that
  # enclosing registered root.  Prefixed sibling/absolute selectors remain self-locating from
  # their fixed `[prefix/]specs/leaf` geometry.
  spec_parent="$(dirname "$selector")"
  if outer_canonical_spec_rel "$selector" 2>/dev/null; then
    explicit_root="$(discovered_registered_root "$PIPELINE_INVOCATION_CWD" 2>/dev/null || true)"
  elif [ "$(basename "$spec_parent")" = specs ]; then
    case "$selector" in
      /*) explicit_candidate="$(dirname "$spec_parent")" ;;
      *) explicit_candidate="$PIPELINE_INVOCATION_CWD/$(dirname "$spec_parent")" ;;
    esac
    explicit_root="$(exact_registered_root "$explicit_candidate" 2>/dev/null || true)"
  fi

  case "$selector" in
    /*)
      # Absolute compatibility selectors bind Git authority only through fixed /root/specs/leaf
      # geometry.  An arbitrary absolute/non-Git location deliberately remains path-locked.
      chosen="$explicit_root"
      ;;
    *)
      if outer_canonical_spec_rel "$selector" 2>/dev/null \
          && [ -n "$script_root" ] \
          && path_is_within "$PIPELINE_INVOCATION_CWD" "$script_root"; then
        # The tracked script is the outer anchor when cwd itself was captured by an untracked repo.
        chosen="$script_root"
      else
        chosen="$explicit_root"
      fi
      ;;
  esac

  if [ -n "$chosen" ]; then
    set_outer_registered_root "$chosen" || return 2
  fi
}

pin_outer_registered_worktree "${2:-}" \
  || die "outer registered worktree authority invalid"

outer_registered_tuple_ids_valid() {
  [ -n "$OUTER_REGISTERED_ROOT" ] \
    && [ -n "$OUTER_REGISTERED_GITDIR" ] \
    && [ -n "$OUTER_REGISTERED_COMMON" ] \
    && [ -n "$OUTER_REGISTERED_WORKTREE_ID" ] \
    && [ -n "$OUTER_REGISTERED_GITDIR_ID" ] \
    && [ -n "$OUTER_REGISTERED_COMMON_ID" ] \
    || return 1
  PINNED_WORKTREE="$OUTER_REGISTERED_ROOT" PINNED_GITDIR="$OUTER_REGISTERED_GITDIR" \
    PINNED_COMMON="$OUTER_REGISTERED_COMMON" \
    PINNED_WORKTREE_ID="$OUTER_REGISTERED_WORKTREE_ID" \
    PINNED_GITDIR_ID="$OUTER_REGISTERED_GITDIR_ID" \
    PINNED_COMMON_ID="$OUTER_REGISTERED_COMMON_ID" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK -e '
      use strict; use warnings;
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      my @tuple=(
        [$ENV{PINNED_WORKTREE},$ENV{PINNED_WORKTREE_ID}],
        [$ENV{PINNED_GITDIR},$ENV{PINNED_GITDIR_ID}],
        [$ENV{PINNED_COMMON},$ENV{PINNED_COMMON_ID}],
      );
      for my $entry (@tuple) {
        my ($path,$want)=@$entry;
        exit 1 unless defined($path) && length($path) && defined($want)
          && $want=~/\A[0-9]+:[0-9]+\z/;
        my @named=lstat($path);
        exit 1 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
        sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
        my @opened=stat($dir);
        exit 1 unless @opened && did(@opened) eq did(@named) && did(@opened) eq $want;
        close($dir) or exit 1;
      }
    ' >/dev/null 2>&1
}

revalidate_outer_registered_authority() { # frozen IDs plus current Git root/gitdir/common relation
  local root_now gitdir_raw gitdir_now common_raw common_now
  outer_registered_tuple_ids_valid || return 1
  root_now="$(discovered_registered_root "$OUTER_REGISTERED_ROOT")" || return 1
  [ "$root_now" = "$OUTER_REGISTERED_ROOT" ] || return 1
  gitdir_raw="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$OUTER_REGISTERED_ROOT" rev-parse --absolute-git-dir 2>/dev/null
  )" || return 1
  gitdir_now="$(cd "$gitdir_raw" 2>/dev/null && pwd -P)" || return 1
  [ "$gitdir_now" = "$OUTER_REGISTERED_GITDIR" ] || return 1
  common_raw="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$OUTER_REGISTERED_ROOT" rev-parse --git-common-dir 2>/dev/null
  )" || return 1
  case "$common_raw" in
    /*) common_now="$(cd "$common_raw" 2>/dev/null && pwd -P)" ;;
    *) common_now="$(cd "$OUTER_REGISTERED_ROOT/$common_raw" 2>/dev/null && pwd -P)" ;;
  esac || return 1
  [ "$common_now" = "$OUTER_REGISTERED_COMMON" ] || return 1
  # Close the discovery window: every named tuple member must still be the descriptor-frozen inode
  # after Git has resolved their relationship.
  outer_registered_tuple_ids_valid
}

pin_outer_registered_ids() { # freeze dev:ino of worktree/common/gitdir once, before any consumer
  [ -n "$OUTER_REGISTERED_GITDIR" ] || return 0
  local ids
  ids="$(
    PINNED_WORKTREE="$OUTER_REGISTERED_ROOT" PINNED_COMMON="$OUTER_REGISTERED_COMMON" \
      PINNED_GITDIR="$OUTER_REGISTERED_GITDIR" \
      perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK -e '
        use strict; use warnings;
        sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
        my @out;
        for my $path (@ENV{qw(PINNED_WORKTREE PINNED_COMMON PINNED_GITDIR)}) {
          exit 1 unless defined($path) && length($path);
          my @named=lstat($path);
          exit 1 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
          sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1;
          my @opened=stat($dir);
          exit 1 unless @opened && did(@opened) eq did(@named);
          close($dir) or exit 1;
          push @out, did(@opened);
        }
        print join(q{ }, @out), qq{\n};
      ' 2>/dev/null
  )" || return 1
  set -- $ids
  [ "$#" -eq 3 ] || return 1
  OUTER_REGISTERED_WORKTREE_ID="$1"
  OUTER_REGISTERED_COMMON_ID="$2"
  OUTER_REGISTERED_GITDIR_ID="$3"
  # Close the discovery window: Git must still resolve the same tuple onto the frozen inodes.
  revalidate_outer_registered_authority
}

pin_outer_registered_ids || die "outer registered worktree identity invalid"

# Deterministic post-pin ABA hook: the worktree/common/gitdir identities are frozen, but no
# pathname consumer has run yet. Production callers never set this variable.
if [ "${HARNESS_PIPELINE_OUTER_AUTH_TEST_PAUSE:-0}" = 1 ]; then
  unset HARNESS_PIPELINE_OUTER_AUTH_TEST_PAUSE
  { printf 'pid=%s\n' "$$" >&9; } 2>/dev/null \
    || die "outer authority test gate недоступен"
  kill -STOP "$$" 2>/dev/null || die "outer authority test pause не установлен"
fi

SELF="$SCRIPT_DIR/$(basename "$0")"
PRIVATE_TMP_HELPER="$SCRIPT_DIR/private-temp-dir.pl"
STATE_READER="$SCRIPT_DIR/lib/pipeline-state-reader-v4.pl"
RECEIPT_VERIFY="$SCRIPT_DIR/receipt-v1.pl"
ARCH_VERIFY="$SCRIPT_DIR/architecture-sdd-verify.pl"
IMPLEMENTATION_VERIFY="$SCRIPT_DIR/implementation-tdd-verify.pl"
TDD_RECEIPT="$SCRIPT_DIR/tdd-receipt-v1.pl"
CHANGELOG_APPEND="$SCRIPT_DIR/changelog-append-v1.pl"
EVIDENCE_VERIFY="$SCRIPT_DIR/evidence-v1-verify.pl"
PERFORMANCE_PROCESS="$SCRIPT_DIR/performance-process-v1.pl"

READER_CONTRACT="$(perl "$STATE_READER" --contract 2>/dev/null)" \
  || die "shared V4 state reader contract недоступен"
[ "$READER_CONTRACT" = 'pipeline-state-reader-v4/1' ] \
  || die "shared V4 state reader contract несовместим"

ARGC=$#
[ "$ARGC" -ge 2 ] || die "usage: pipeline-state.sh <init|migrate-v4|migrate-contract|link-ticket|link-ticket-cas|stage-start|stage-done|ack|gate|review-start|review-finish|review-blocked|performance-run|evidence-bind|design-bind|implementation-start|implementation-content-root|tdd-run|implementation-bind|sdd-append|delivery-append|approve|units-set|unit-done|verdict|event|validate-state|quality-head|bind-head|publish-base|check|status> <SPEC_DIR> [...]"
CMD="$1"; DIR="$2"; INPUT_DIR="$2"
STATE="$DIR/state.md"; AUDIT="$DIR/audit.md"; STATE_TMP=""; STATE_TMP_ID=""; STATE_TMP_RECORD=""
STATE_SNAPSHOT_LEAF=""; STATE_SNAPSHOT_RECORD=""; STATE_BASE_RECORD=""
VERIFY_TMP=""; VERIFY_TMP_ID=""; GIT_ROOT=""; SPEC_REL=""; STRICT_CHECKPOINT_HEAD=""
MUTATION_LOCK_BASE=""; MUTATION_LOCK_BASE_ID=""; MUTATION_LOCK_ROOT=""
MUTATION_LOCK_ROOT_ID=""; MUTATION_LOCK_NAME=""; MUTATION_LOCK_ID=""
MUTATION_LOCK_OWNER_ID=""; MUTATION_LOCK_NONCE=""; MUTATION_LOCK_PID=""
MUTATION_LOCK_STARTED=""; MUTATION_LOCK_BIRTH=""
MUTATION_RECOVERY_LOCK_ID=""; MUTATION_RECOVERY_OWNER_ID=""; MUTATION_RECOVERY_NONCE=""
MUTATION_RECOVERY_PID=""; MUTATION_RECOVERY_STARTED=""; MUTATION_RECOVERY_BIRTH=""
MUTATION_SPEC_PATH=""; MUTATION_SPEC_ID=""; MUTATION_WAL_NAME=""
STATE_TX_READY=0; AUDIT_ROWS=""; AUDIT_BASE_EXPECTED=""
PRESERVE_MUTATION_LOCK=0
TS="$(date -u +%FT%TZ)"
STAGES="stage-1-creative stage-2-audit stage-3-dev stage-4-quality"

arity() { # <min total argv> <max total argv> <usage-tail>
  local min="$1" max="$2" usage="$3"
  [ "$ARGC" -ge "$min" ] && [ "$ARGC" -le "$max" ] \
    || die "$CMD: ожидаю $usage (получено аргументов: $ARGC)"
}
need_state() { [ -f "$STATE" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""; }
valid_stage() { case " $STAGES " in *" $1 "*) return 0;; *) return 1;; esac; }

generic_event_field_safe() { # generic telemetry must never spell an authority wire token
  # Authority verifiers deliberately reject these tokens anywhere in an append-only row.  Match
  # them as substrings here too: an innocent-looking prefix/suffix or detail must not be able to
  # create a durable row that every later Design/Implementation/Evidence parser rejects.
  case "${1-}" in
    *receipt-invalidate*|*migration:v4*|*design-bind*|*evidence-bind*|*implementation-*|\
    *tdd-run-*|*performance-run-*|*review-*|*sdd-append*|*delivery-append*|\
    *stage-4-quality:start*|*stage-4-quality:done*|*stage-4-quality:invalidated*|\
    *quality-head*|*quality-verdict*|*confidence:stage-4-quality*|\
    *confidence-ack:stage-4-quality*) return 1 ;;
  esac
  return 0
}

sanitize() { # единая очистка ЛЮБОГО значения перед записью в state.md/audit.md.
  # '|' ломает markdown-таблицу audit.md; \n/\r инжектят новые строки — вектор обхода гейта:
  # напр. approve BY со встроенным $'\n- user-approval: approved' подделал бы строку state.md
  # (эксплуатируемый вектор обхода гейта). Все callers set_gate
  # (gate RES, approve BY, verdict DET), init FEATURE и set_conf проходят через sanitize.
  local s="${1-}"
  s="${s//|/∕}"; s="${s//$'\n'/ }"; s="${s//$'\r'/ }"
  printf '%s' "$s"
}

audit_row() { # $1 event, $2 detail — оба санитизируются (одна строка с '|'/\n ломает таблицу и парсер)
  local ev det
  [ -n "${MUTATION_LOCK_NAME:-}" ] || die "$CMD: audit mutation без unified lock"
  ev="$(sanitize "$1")"; det="$(sanitize "${2:--}")"
  AUDIT_ROWS="${AUDIT_ROWS}| $TS | $ev | $det |
"
}

receipt_generation() { # [current|next]; descriptor-pinned audit-derived monotonic generation
  local mode="${1:-current}"
  case "$mode" in current|next) ;; *) return 2 ;; esac
  MODE="$mode" perl - "$AUDIT" <<'PERL'
use strict; use warnings; use utf8;
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG S_ISLNK);
sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
my $f=shift; my @named=lstat($f); exit 2 unless @named && !S_ISLNK($named[2])
  && S_ISREG($named[2]) && $named[3]==1;
sysopen(my $fh,$f,O_RDONLY|O_NOFOLLOW) or exit 2; my @opened=stat($fh);
exit 2 unless @opened && did(@opened) eq did(@named) && $opened[3]==1;
my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 2 unless defined($n);
  last unless $n; $raw.=$buf; exit 2 if length($raw)>16777216 }
my $text; eval { $text=decode(q{UTF-8},$raw,FB_CROAK|LEAVE_SRC); 1 } or exit 2;
my $generation=0;
for my $line (split /\n/,$text) {
  next unless $line =~ /^\| [^|]+ \| receipt-invalidate \| ([^|]+) \|$/;
  my $detail=$1;
  $detail =~ /^generation=([1-9][0-9]*);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)$/
    or exit 2;
  my $next=$1; exit 2 if length($next)>10 || $next>2147483647
    || $generation>=2147483647 || $next!=$generation+1; $generation=$next;
}
my @after=stat($fh); my @again=lstat($f); close($fh) or exit 2;
exit 2 unless @after && @again && !S_ISLNK($again[2]) && S_ISREG($again[2])
  && did(@after) eq did(@opened) && did(@again) eq did(@opened) && $after[7]==length($raw);
my $mode=$ENV{MODE}//q{};
if ($mode eq q{current}) { print $generation }
elsif ($mode eq q{next}) { exit 2 if $generation>=2147483647; print $generation+1 }
else { exit 2 }
PERL
}

implementation_artifacts_batch() { # <init|verify|finalize|created|abort> [records-or-nonce]
  local mode="$1" payload="${2:-}"
  case "$mode" in init|verify|finalize|created|abort) ;; *) return 2 ;; esac
  [ -n "${MUTATION_SPEC_PATH:-}" ] && [ -n "${MUTATION_SPEC_ID:-}" ] \
    || die "$CMD: implementation artifact batch без unified SPEC authority"
  IMPL_BATCH_MODE="$mode" IMPL_SPEC="$MUTATION_SPEC_PATH" IMPL_SPEC_ID="$MUTATION_SPEC_ID" \
    IMPL_TEMPLATE="$SCRIPT_DIR/templates/architecture-evidence-v1" IMPL_PAYLOAD="$payload" \
    IMPL_FAIL_AFTER="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_FAIL_AFTER:-}" \
    IMPL_PAUSE_BEFORE="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_PAUSE_BEFORE:-}" \
    IMPL_PAUSE_CLEANUP="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_PAUSE_CLEANUP:-}" \
    IMPL_PAUSE_STAGE="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_PAUSE_STAGE:-}" \
    IMPL_FAIL_STAGE="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_FAIL_STAGE:-}" \
    IMPL_CREATED_PHASE="${IMPL_CREATED_PHASE:-}" \
    IMPL_TEST_CAP="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_CAPABILITY:-}" \
    IMPL_TEST_FD="${HARNESS_PIPELINE_IMPLEMENTATION_INIT_TEST_FD:-}" \
    perl -MDigest::SHA=sha256_hex -MErrno=EEXIST,ENOENT -MIO::Handle \
      -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG - <<'PERL'
use strict; use warnings;
my ($mode,$spec,$spec_id,$template,$payload,$fail_after,$pause_before,$pause_cleanup,$pause_stage,
    $fail_stage,$created_phase,$test_cap,$test_fd)=
  @ENV{qw(IMPL_BATCH_MODE IMPL_SPEC IMPL_SPEC_ID IMPL_TEMPLATE IMPL_PAYLOAD IMPL_FAIL_AFTER
    IMPL_PAUSE_BEFORE IMPL_PAUSE_CLEANUP IMPL_PAUSE_STAGE IMPL_FAIL_STAGE IMPL_CREATED_PHASE
    IMPL_TEST_CAP IMPL_TEST_FD)};
my $limit=16_777_216;
my @map=(
  [q{delivery-trace.tsv},q{delivery-trace-tdd-v1.tsv}],
  [q{implementation-map.tsv},q{implementation-map-v1.tsv}],
  [q{test-manifest-v2.tsv},q{test-manifest-v2.tsv}],
  [q{delivery-changelog.tsv},q{delivery-changelog.tsv}],
);
sub bad { die "implementation artifact batch rejected\n" }
sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
my $test_enabled=0;
if (defined($test_cap) && $test_cap=~/\A[0-9a-f]{64}\z/
    && defined($test_fd) && $test_fd=~/\A(?:[3-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\z/) {
  # Duplicate, never alias/consume, the caller's explicit capability FD. Every helper invocation
  # seeks its own duplicate back to zero because inherited descriptors share one open-file offset.
  if (open(my $cap_fh,q{<&}.$test_fd)) {
    my @before=stat($cap_fh); my $raw=q{};
    if (@before && S_ISREG($before[2]) && $before[3]==1 && $before[4]==$<
        && ($before[2]&0777)==0600 && $before[7]>0 && $before[7]<=256
        && defined(sysseek($cap_fh,0,0))) {
      while (1) { my $n=sysread($cap_fh,my $buf,256); last unless defined($n) && $n;
        $raw.=$buf; last if length($raw)>256 }
      my @after=stat($cap_fh);
      $test_enabled=1 if @after && did(@after) eq did(@before) && S_ISREG($after[2])
        && $after[3]==1 && $after[4]==$< && ($after[2]&0777)==0600
        && $after[7]==$before[7] && length($raw)==$before[7]
        && $raw eq "implementation-init-test-v1:$test_cap\n";
    }
    close($cap_fh);
  }
}
unless ($test_enabled) {
  $fail_after=q{}; $pause_before=q{}; $pause_cleanup=q{}; $pause_stage=q{}; $fail_stage=q{};
}
sub open_dir {
  my ($path,$want)=@_; sysopen(my $fh,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or bad();
  my @s=stat($fh); bad() unless @s && S_ISDIR($s[2]) && (!defined($want) || did(@s) eq $want);
  return ($fh,did(@s));
}
sub read_file {
  my ($dir,$name,$missing,$mode_want,$links)=@_; chdir($dir) or bad(); my @n=lstat($name);
  return undef if !@n && $missing && $!{ENOENT};
  bad() unless @n && !S_ISLNK($n[2]) && S_ISREG($n[2]) && $n[4]==$<
    && (!$links || $n[3]>=$links->[0] && $n[3]<=$links->[1]);
  sysopen(my $fh,$name,O_RDONLY|O_NOFOLLOW) or bad(); my @o=stat($fh);
  bad() unless @o && did(@o) eq did(@n) && (!defined($mode_want) || ($o[2]&0777)==$mode_want);
  my $raw=q{}; while (1) { my $nread=sysread($fh,my $buf,65536); bad() unless defined($nread);
    last unless $nread; $raw.=$buf; bad() if length($raw)>$limit }
  my @a=stat($fh); close($fh) or bad(); my @again=lstat($name);
  bad() unless @a && @again && !S_ISLNK($again[2]) && S_ISREG($a[2]) && S_ISREG($again[2])
    && did(@a) eq did(@o) && did(@again) eq did(@o)
    && $a[4]==$< && $again[4]==$< && $a[7]==length($raw) && $again[7]==length($raw)
    && (!defined($mode_want) || (($a[2]&0777)==$mode_want && ($again[2]&0777)==$mode_want))
    && (!$links || ($a[3]>=$links->[0] && $a[3]<=$links->[1]
      && $again[3]>=$links->[0] && $again[3]<=$links->[1]));
  return { raw=>$raw,id=>did(@o),hash=>sha256_hex($raw),len=>length($raw),mode=>($o[2]&0777) };
}
sub write_new {
  my ($dir,$name,$raw,$mode)=@_; chdir($dir) or bad();
  sysopen(my $fh,$name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or bad();
  my $off=0; while ($off<length($raw)) { my $n=syswrite($fh,$raw,length($raw)-$off,$off);
    bad() unless defined($n) && $n; $off+=$n }
  chmod($mode,$fh)==1 or bad(); $fh->sync or bad(); my @s=stat($fh); close($fh) or bad();
  return did(@s);
}
sub unlink_exact {
  my ($dir,$name,$id)=@_; chdir($dir) or bad(); my @s=lstat($name);
  return 1 if !@s && $!{ENOENT};
  bad() unless @s && !S_ISLNK($s[2]) && S_ISREG($s[2]) && did(@s) eq $id;
  unlink($name) or bad(); $dir->sync or bad(); return 1;
}
sub random_nonce {
  sysopen(my $fh,q{/dev/urandom},O_RDONLY|O_NOFOLLOW) or bad(); my $raw=q{};
  while (length($raw)<32) { my $n=sysread($fh,my $b,32-length($raw)); bad() unless defined($n) && $n; $raw.=$b }
  close($fh) or bad(); return unpack(q{H*},$raw);
}
sub manifest_raw {
  my ($nonce,$rows)=@_; my $raw="implementation-init-v1\t$nonce\n";
  for my $r (@$rows) { $raw.=join("\t",@$r)."\n" } return $raw;
}
sub replace_manifest {
  my ($txn,$raw)=@_; my $leaf=q{manifest.next}; write_new($txn,$leaf,$raw,0600);
  chdir($txn) or bad(); rename($leaf,q{manifest}) or bad(); $txn->sync or bad();
}
sub parse_manifest {
  my ($raw,$nonce)=@_; my @line=split /\n/,$raw,-1; bad() unless pop(@line) eq q{}
    && shift(@line) eq "implementation-init-v1\t$nonce" && @line==@map;
  my @rows;
  for my $i (0..$#map) {
    my @f=split /\t/,$line[$i],-1; bad() unless @f==10;
    bad() unless $f[0] eq $map[$i][0] && $f[1] eq ".implementation-init.$nonce.$i.tmp"
      && $f[2]=~/\A[0-9a-f]{64}\z/ && $f[3]=~/\A[0-9]+\z/
      && ($f[4] eq q{pending} || $f[4]=~/\A[0-9]+:[0-9]+\z/)
      && ($f[5] eq q{M} || $f[5] eq q{E});
    if ($f[5] eq q{M}) { bad() unless join(q{},@f[6..9]) eq q{----} }
    else { bad() unless $f[6]=~/\A[0-9]+:[0-9]+\z/ && $f[7]=~/\A[0-9a-f]{64}\z/
      && $f[8]=~/\A[0-9]+\z/ && $f[9] eq q{0644} }
    push @rows,\@f;
  }
  return \@rows;
}
sub marker {
  my ($txn,$name)=@_; my $v=read_file($txn,$name,1,0600,[1,1]); return 0 unless $v;
  bad() unless $v->{raw} eq q{}; return 1;
}
sub remove_metadata {
  my ($txn,$leaf,$kind,$expected)=@_; my $v=read_file($txn,$leaf,1,0600,[1,1]); return 1 unless $v;
  bad() if $kind eq q{marker} && $v->{raw} ne q{};
  bad() if $kind eq q{manifest} && defined($expected)
    && ($v->{id} ne $expected->{id} || $v->{hash} ne $expected->{hash} || $v->{len}!=$expected->{len});
  unlink_exact($txn,$leaf,$v->{id}); return 1;
}
sub cleanup_txn {
  my ($spec_fh,$name,$nonce,$action)=@_; chdir($spec_fh) or bad();
  my @n=lstat($name); return [] if !@n && $!{ENOENT};
  bad() unless @n && !S_ISLNK($n[2]) && S_ISDIR($n[2]) && $n[4]==$< && ($n[2]&0777)==0700;
  sysopen(my $txn,$name,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or bad(); my @o=stat($txn);
  bad() unless @o && did(@o) eq did(@n);
  my $manifest=read_file($txn,q{manifest},1,0600,[1,1]);
  if (!$manifest) {
    chdir($txn) or bad(); opendir(my $dh,q{.}) or bad();
    my @e=grep { $_ ne q{.} && $_ ne q{..} } readdir($dh); closedir($dh) or bad();
    my %allowed=map {$_=>1} qw(manifest.next PREPARED COMMITTED); bad() if grep {!$allowed{$_}} @e;
    remove_metadata($txn,q{manifest.next},q{opaque},undef);
    remove_metadata($txn,q{PREPARED},q{marker},undef);
    remove_metadata($txn,q{COMMITTED},q{marker},undef);
    chdir($spec_fh) or bad(); rmdir($name) or bad(); $spec_fh->sync or bad(); return [];
  }
  my $rows=parse_manifest($manifest->{raw},$nonce); my $committed=marker($txn,q{COMMITTED});
  bad() if $committed && !marker($txn,q{PREPARED}); my ($race,@created)=(0);
  for my $r (@$rows) {
    my ($target,$temp,$hash,$len,$temp_id,$oldkind,$oldid,$oldhash,$oldlen,$oldmode)=@$r;
    my $tv;
    if ($temp_id eq q{pending}) {
      # Publication cannot begin before every temp inode is recorded and PREPARED is durable.
      # A killed/failed write may therefore leave a partial 0600 file; the nonce-bound name inside
      # our owned txn is sufficient to remove it, but it can never authorize target deletion.
      chdir($spec_fh) or bad(); my @p=lstat($temp);
      if (@p) {
        bad() if S_ISLNK($p[2]) || !S_ISREG($p[2]) || $p[4]!=$< || $p[3]!=1
          || (($p[2]&0777)!=0600 && ($p[2]&0777)!=0644);
        sysopen(my $pf,$temp,O_RDONLY|O_NOFOLLOW) or bad(); my @po=stat($pf); close($pf) or bad();
        bad() unless @po && did(@po) eq did(@p); unlink_exact($spec_fh,$temp,did(@po));
      } elsif (!$!{ENOENT}) { bad() }
    } else {
      $tv=read_file($spec_fh,$temp,1,0644,[1,2]);
      if ($tv) { bad() unless $tv->{hash} eq $hash && $tv->{len}==$len
        && $tv->{id} eq $temp_id; $temp_id=$tv->{id} }
    }
    my $dst=read_file($spec_fh,$target,1,0644,[1,2]);
    if ($oldkind eq q{M}) {
      if ($dst && $temp_id ne q{pending} && $dst->{id} eq $temp_id) {
        bad() unless $dst->{hash} eq $hash && $dst->{len}==$len;
        if ($committed && $action ne q{abort}) { push @created,join("\t",q{created},$target,$dst->{id},$hash,$len) }
        else { unlink_exact($spec_fh,$target,$dst->{id}) }
      } elsif ($dst) { $race=1 }
      elsif ($committed) { $race=1 }
    } else {
      $race=1 unless $dst && $dst->{id} eq $oldid && $dst->{hash} eq $oldhash
        && $dst->{len}==$oldlen && sprintf(q{%04o},$dst->{mode}) eq $oldmode;
    }
    unlink_exact($spec_fh,$temp,$tv->{id}) if $tv;
  }
  bad() if $race && $action ne q{abort};
  return \@created if $committed && $action eq q{keep};
  if ($committed && $action eq q{finalize} && $pause_cleanup eq q{before-metadata}) {
    open(my $gate,q{>&=9}) or bad(); my $msg=q{pid=}.$$ . "\n";
    syswrite($gate,$msg,length($msg))==length($msg) or bad(); close($gate) or bad();
    kill(q{STOP},$$)==1 or bad();
  }
  chdir($txn) or bad(); opendir(my $dh,q{.}) or bad();
  my @e=grep { $_ ne q{.} && $_ ne q{..} } readdir($dh); closedir($dh) or bad();
  my %ok=map {$_=>1} qw(manifest manifest.next PREPARED COMMITTED); bad() if grep {!$ok{$_}} @e;
  # Deterministic recoverable GC: manifest disappears only after targets were validated/rolled back;
  # COMMITTED is the final metadata unlink. A kill at any boundary is classified on retry without
  # ever treating a committed target as an uncommitted one.
  remove_metadata($txn,q{manifest.next},q{opaque},undef);
  remove_metadata($txn,q{manifest},q{manifest},$manifest);
  remove_metadata($txn,q{PREPARED},q{marker},undef);
  remove_metadata($txn,q{COMMITTED},q{marker},undef);
  chdir($spec_fh) or bad(); rmdir($name) or bad(); $spec_fh->sync or bad(); bad() if $race; return \@created;
}

sub parse_payload {
  my ($raw)=@_; bad() unless defined($raw) && length($raw) && $raw!~/[\r\x00]/ && $raw!~/\n\z/;
  # Bash command substitution intentionally strips producer trailing LFs; the payload remains an
  # exact non-empty line sequence and must not acquire an ambiguous blank record.
  my @line=split /\n/,$raw,-1; bad() unless @line>=1;
  my $head=shift @line; $head=~/\Atransaction\t(-|[0-9a-f]{64})\z/ or bad(); my $nonce=$1;
  my (%seen,@record);
  for my $line (@line) {
    $line=~/\Acreated\t([^\t]+)\t([0-9]+:[0-9]+)\t([0-9a-f]{64})\t([0-9]+)\z/ or bad();
    my ($leaf,$id,$hash,$len)=($1,$2,$3,$4); bad() if $seen{$leaf}++;
    bad() unless grep { $_->[0] eq $leaf } @map; push @record,join("\t",q{created},$leaf,$id,$hash,$len);
  }
  bad() if $nonce eq q{-} && @record; return ($nonce,\@record);
}
bad() unless defined($mode) && grep { $_ eq $mode } qw(init verify finalize created abort);
bad() unless defined($fail_after) && ($fail_after eq q{} || $fail_after=~/\A[1-4]\z/);
bad() unless defined($pause_before) && ($pause_before eq q{} || grep { $_->[0] eq $pause_before } @map);
bad() unless defined($pause_cleanup) && ($pause_cleanup eq q{} || $pause_cleanup eq q{before-metadata});
bad() unless defined($pause_stage) && ($pause_stage eq q{} || grep { $_ eq $pause_stage }
  qw(before-git-add after-selection-before-index-cas-add after-post-live-before-first-index-check
    after-first-index-exact-before-later-check));
bad() unless defined($fail_stage) && ($fail_stage eq q{} || $fail_stage eq q{after-index-cas-add});
bad() unless defined($created_phase) && ($created_phase eq q{} || grep { $_ eq $created_phase }
  qw(pre selection-ready after-index-cas-add post post-live after-first-index));
my ($spec_fh)=open_dir($spec,$spec_id);
chdir($spec_fh) or bad(); opendir(my $scan,q{.}) or bad();
my @txn=sort grep { /\A\.implementation-init\.([0-9a-f]{64})\.txn\z/ } readdir($scan); closedir($scan) or bad();
if ($mode eq q{created}) {
  my ($nonce,$record)=parse_payload($payload); exit 0 if $nonce eq q{-};
  bad() unless @txn==1 && $txn[0] eq ".implementation-init.$nonce.txn";
  my $actual=cleanup_txn($spec_fh,$txn[0],$nonce,q{keep});
  bad() unless join("\n",@$actual) eq join("\n",@$record);
  my %pause_phase=(
    q{before-git-add}=>q{pre},
    q{after-selection-before-index-cas-add}=>q{selection-ready},
    q{after-post-live-before-first-index-check}=>q{post-live},
    q{after-first-index-exact-before-later-check}=>q{after-first-index},
  );
  if (length($pause_stage) && ($pause_phase{$pause_stage}//q{}) eq $created_phase) {
    open(my $gate,q{>&=9}) or bad(); my $msg=q{pid=}.$$ . "\n";
    syswrite($gate,$msg,length($msg))==length($msg) or bad(); close($gate) or bad();
    kill(q{STOP},$$)==1 or bad();
  }
  exit 1 if length($fail_stage) && $fail_stage eq $created_phase;
  exit 0;
}
if ($mode eq q{finalize} || $mode eq q{abort}) {
  bad() unless defined($payload) && $payload=~/\A(?:-|[0-9a-f]{64})\z/; exit 0 if $payload eq q{-};
  my $name=".implementation-init.$payload.txn"; bad() unless @txn==1 && $txn[0] eq $name;
  cleanup_txn($spec_fh,$name,$payload,$mode); exit 0;
}
if ($mode eq q{verify}) { bad() if @txn }
else {
  my ($found_nonce,$found_record);
  for my $name (@txn) {
    $name=~/\A\.implementation-init\.([0-9a-f]{64})\.txn\z/ or bad(); my $nonce=$1;
    my $record=cleanup_txn($spec_fh,$name,$nonce,q{keep});
    if (@$record) { bad() if defined($found_nonce); ($found_nonce,$found_record)=($nonce,$record) }
  }
  if (defined($found_nonce)) {
    print "transaction\t$found_nonce\n",join("\n",@$found_record),"\n"; exit 0;
  }
}
my ($template_fh)=open_dir($template,undef);
my (@source,@dest,@missing);
for my $i (0..$#map) {
  $source[$i]=read_file($template_fh,$map[$i][1],0,0644,[1,1]);
  bad() if $source[$i]{raw}=~/\x00/;
  $dest[$i]=read_file($spec_fh,$map[$i][0],1,0644,[1,1]); push @missing,$i unless $dest[$i];
}
if ($mode eq q{verify}) { bad() if @missing; exit 0 }
if (!@missing) { print "transaction\t-\n"; exit 0 }
my $nonce=random_nonce(); my $txn_name=".implementation-init.$nonce.txn";
chdir($spec_fh) or bad(); mkdir($txn_name,0700) or bad(); $spec_fh->sync or bad();
my ($txn)=open_dir($txn_name,undef); my @rows;
for my $i (0..$#map) {
  my $old=$dest[$i]; push @rows,[ $map[$i][0], ".implementation-init.$nonce.$i.tmp",
    $source[$i]{hash},$source[$i]{len},q{pending}, $old?q{E}:q{M},
    $old?$old->{id}:q{-},$old?$old->{hash}:q{-},$old?$old->{len}:q{-},$old?sprintf(q{%04o},$old->{mode}):q{-} ];
}
my $ok=eval {
  replace_manifest($txn,manifest_raw($nonce,\@rows));
  for my $i (0..$#rows) {
    my $id=write_new($spec_fh,$rows[$i][1],$source[$i]{raw},0644); $rows[$i][4]=$id;
    replace_manifest($txn,manifest_raw($nonce,\@rows));
  }
  write_new($txn,q{PREPARED},q{},0600); $txn->sync or bad(); my $published=0;
  for my $i (@missing) {
    if ($pause_before eq $map[$i][0]) {
      open(my $gate,q{>&=9}) or bad(); my $msg=q{pid=}.$$ . "\n";
      syswrite($gate,$msg,length($msg))==length($msg) or bad(); close($gate) or bad(); kill(q{STOP},$$)==1 or bad();
    }
    chdir($spec_fh) or bad(); link($rows[$i][1],$rows[$i][0]) or bad(); $spec_fh->sync or bad();
    my $v=read_file($spec_fh,$rows[$i][0],0,0644,[2,2]); bad() unless $v->{id} eq $rows[$i][4]
      && $v->{hash} eq $rows[$i][2] && $v->{len}==$rows[$i][3];
    $published++; bad() if length($fail_after) && $published==$fail_after;
  }
  write_new($txn,q{COMMITTED},q{},0600); $txn->sync or bad(); $spec_fh->sync or bad(); 1;
};
if (!$ok) { eval { cleanup_txn($spec_fh,$txn_name,$nonce,q{abort}) }; exit 1 }
my $created=cleanup_txn($spec_fh,$txn_name,$nonce,q{keep});
print "transaction\t$nonce\n",join("\n",@$created),"\n";
PERL
}

implementation_init_token() {
  printf '%s\n' "$1" | perl -e '
    use strict; use warnings; my @l=<STDIN>; chomp @l;
    @l && $l[0]=~/\Atransaction\t(-|[0-9a-f]{64})\z/ or exit 1;
    print $1;
  '
}

implementation_index_exact() { # <repo-relative-path> <sha256> <length>
  local path="$1" hash="$2" len="$3" oid
  oid="$(git ls-files --stage -- "$path" | EXPECT_PATH="$path" perl -e '
    use strict; use warnings; local $/; my $v=<STDIN>//q{};
    $v=~/\A100644 ([0-9a-f]{40}|[0-9a-f]{64}) 0\t\Q$ENV{EXPECT_PATH}\E\n\z/ or exit 1; print $1;
  ')" || return 1
  git cat-file blob "$oid" \
    | EXPECT_HASH="$hash" EXPECT_LEN="$len" perl -MDigest::SHA=sha256_hex -e '
      use strict; use warnings; local $/; my $v=<STDIN>//q{};
      exit(length($v)==$ENV{EXPECT_LEN} && sha256_hex($v) eq $ENV{EXPECT_HASH} ? 0 : 1);
    '
}

implementation_object_exact() { # <Git blob OID> <sha256> <length>
  local oid="$1" hash="$2" len="$3"
  printf '%s' "$oid" | LC_ALL=C grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$' || return 1
  git cat-file blob "$oid" \
    | EXPECT_HASH="$hash" EXPECT_LEN="$len" perl -MDigest::SHA=sha256_hex -e '
      use strict; use warnings; local $/; my $v=<STDIN>//q{};
      exit(length($v)==$ENV{EXPECT_LEN} && sha256_hex($v) eq $ENV{EXPECT_HASH} ? 0 : 1);
    '
}

implementation_index_add_records() { # <initializer records> <new repo paths...>
  local created="$1" path leaf source meta hash len extra oid records="" tab
  shift
  tab="$(printf '\t')"
  for path in "$@"; do
    case "$path" in "$SPEC_REL"/*) leaf="${path#"$SPEC_REL"/}" ;; *) return 1 ;; esac
    case "$leaf" in
      delivery-trace.tsv) source=delivery-trace-tdd-v1.tsv ;;
      implementation-map.tsv) source=implementation-map-v1.tsv ;;
      test-manifest-v2.tsv) source=test-manifest-v2.tsv ;;
      delivery-changelog.tsv) source=delivery-changelog.tsv ;;
      *) return 1 ;;
    esac
    meta="$(printf '%s\n' "$created" | EXPECT_LEAF="$leaf" perl -e '
      use strict; use warnings; my $want=$ENV{EXPECT_LEAF}//q{}; my @match;
      while (<STDIN>) { chomp; my @v=split /\t/,$_,-1; next unless @v==5 && $v[0] eq q{created} && $v[1] eq $want;
        push @match,join(q{|},$v[3],$v[4]) }
      exit 1 unless @match==1; print $match[0];
    ')" || return 1
    OLDIFS="$IFS"; IFS='|' read -r hash len extra <<EOF
$meta
EOF
    IFS="$OLDIFS"
    [ -n "$hash" ] && [ -n "$len" ] && [ -z "${extra:-}" ] || return 1
    oid="$(git hash-object -w --path="$path" -- \
      "$SCRIPT_DIR/templates/architecture-evidence-v1/$source")" || return 1
    implementation_object_exact "$oid" "$hash" "$len" || return 1
    records="${records}${path}${tab}100644${tab}${oid}
"
  done
  [ -n "$records" ] || return 1
  printf '%s' "$records"
}

implementation_index_cas_add() { # <path TAB mode TAB expected-oid records>; atomic add-if-absent set
  local records="$1" index_raw index_dir index_leaf index_path repo git_dir
  [ -n "$records" ] || return 1
  index_raw="$(git rev-parse --git-path index 2>/dev/null)" || return 1
  case "$index_raw" in
    /*) index_path="$index_raw" ;;
    *) index_path="$(pwd -P)/$index_raw" ;;
  esac
  index_leaf="${index_path##*/}"; index_dir="${index_path%/*}"
  [ "$index_leaf" = index ] || return 1
  index_dir="$(cd "$index_dir" 2>/dev/null && pwd -P)" || return 1
  index_path="$index_dir/$index_leaf"
  repo="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  repo="$(cd "$repo" 2>/dev/null && pwd -P)" || return 1
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  git_dir="$(cd "$git_dir" 2>/dev/null && pwd -P)" || return 1
  [ "$git_dir" = "$index_dir" ] || return 1
  INDEX_DIR="$index_dir" INDEX_PATH="$index_path" REPO_ROOT="$repo" EFFECTIVE_GIT_DIR="$git_dir" RECORDS="$records" \
    perl -MErrno=EEXIST,ENOENT -MIO::Handle \
      -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG,FD_CLOEXEC,F_SETFD -e '
      use strict; use warnings;
      my ($dir_path,$index_path,$root,$git_dir,$records)=
        @ENV{qw(INDEX_DIR INDEX_PATH REPO_ROOT EFFECTIVE_GIT_DIR RECORDS)};
      my $limit=268_435_456; my ($dir,$lock,$index,$temp_name,$lock_id); my $committed=0;
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      sub bad { die "index CAS rejected\n" }
      sub read_fh {
        my ($fh)=@_; defined(sysseek($fh,0,0)) or bad(); my $raw=q{};
        while (1) { my $n=sysread($fh,my $buf,65536); defined($n) or bad(); last unless $n;
          $raw.=$buf; length($raw)<=$limit or bad() }
        return $raw;
      }
      sub write_fh {
        my ($fh,$raw)=@_; my $off=0;
        while ($off<length($raw)) { my $n=syswrite($fh,$raw,length($raw)-$off,$off);
          defined($n) && $n>0 or bad(); $off+=$n }
      }
      sub random_hex {
        sysopen(my $fh,q{/dev/urandom},O_RDONLY|O_NOFOLLOW) or bad(); my $raw=q{};
        while (length($raw)<32) { my $n=sysread($fh,my $buf,32-length($raw));
          defined($n) && $n>0 or bad(); $raw.=$buf }
        close($fh) or bad(); return unpack(q{H*},$raw);
      }
      my (%want,@path);
      for my $line (split /\n/,$records,-1) {
        next unless length($line); my ($path,$mode,$oid,$extra)=split /\t/,$line,-1;
        bad() if defined($extra) || !defined($oid) || $mode ne q{100644}
          || $path!~m{\Aspecs/[0-9]{3}-[a-z0-9][a-z0-9-]*/(?:delivery-trace\.tsv|implementation-map\.tsv|test-manifest-v2\.tsv|delivery-changelog\.tsv)\z}
          || $oid!~m{\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z} || $want{$path}++;
        $want{$path}=join(q{ },$mode,$oid,q{0}); push @path,$path;
      }
      bad() unless @path>=1 && @path<=4;
      sysopen($dir,$dir_path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or bad(); my @ds=stat($dir);
      bad() unless @ds && S_ISDIR($ds[2]); chdir($dir) or bad();
      sysopen($lock,q{index.lock},O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or bad();
      fcntl($lock,F_SETFD,FD_CLOEXEC) or bad(); my @ls=stat($lock); $lock_id=did(@ls);
      my @named=lstat(q{index});
      bad() unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2])
        && $named[3]==1 && $named[4]==$<;
      my $index_mode=$named[2]&0777;
      sysopen($index,q{index},O_RDONLY|O_NOFOLLOW) or bad(); my @opened=stat($index);
      bad() unless @opened && did(@opened) eq did(@named);
      my $index_raw=read_fh($index);
      $temp_name=q{.harness-index-cas-}.random_hex();
      sysopen(my $temp,$temp_name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or bad();
      write_fh($temp,$index_raw); chmod($index_mode,$temp)==1 or bad();
      $temp->sync or bad(); close($temp) or bad();
      my $temp_path=$dir_path.q{/}.$temp_name;
      local %ENV=(PATH=>q{/usr/bin:/bin:/usr/sbin:/sbin},LC_ALL=>q{C},LANG=>q{C},TZ=>q{UTC},
        HOME=>q{/},TMPDIR=>q{/tmp},GIT_INDEX_FILE=>$temp_path,GIT_CONFIG_NOSYSTEM=>q{1},
        GIT_CONFIG_GLOBAL=>q{/dev/null},GIT_CONFIG_SYSTEM=>q{/dev/null},
        GIT_NO_REPLACE_OBJECTS=>q{1},GIT_OPTIONAL_LOCKS=>q{0},
        GIT_DIR=>$git_dir,GIT_WORK_TREE=>$root);
      sub git_capture {
        open(my $fh,q{-|},q{git},q{-C},$root,@_) or bad(); binmode($fh,q{:raw});
        my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); defined($n) or bad();
          last unless $n; $raw.=$buf; length($raw)<=$limit or bad() }
        close($fh) or bad(); return $raw;
      }
      my $selected=git_capture(q{ls-files},q{--stage},q{-z},q{--},@path);
      my %seen;
      for my $row (split /\0/,$selected,-1) {
        next unless length($row); $row=~/\A([^\t]+)\t([^\0]+)\z/ or bad();
        my ($meta,$path)=($1,$2); bad() unless exists($want{$path}) && !$seen{$path}++
          && $meta eq $want{$path};
      }
      bad() if length($selected);
      my $all_before=git_capture(q{ls-files},q{--stage},q{-z});
      my @cache;
      for my $path (@path) { my ($mode,$oid,$stage)=split / /,$want{$path},-1;
        bad() unless $stage eq q{0}; push @cache,q{--cacheinfo},$mode.q{,}.$oid.q{,}.$path }
      system(q{git},q{-C},$root,q{update-index},q{--add},@cache)==0 or bad();
      my $selected_after=git_capture(q{ls-files},q{--stage},q{-z},q{--},@path);
      my %after;
      for my $row (split /\0/,$selected_after,-1) {
        next unless length($row); $row=~/\A([^\t]+)\t([^\0]+)\z/ or bad();
        my ($meta,$path)=($1,$2); bad() unless exists($want{$path}) && !$after{$path}++
          && $meta eq $want{$path};
      }
      bad() unless keys(%after)==@path;
      my $all_after=git_capture(q{ls-files},q{--stage},q{-z});
      my @other;
      for my $raw ($all_before,$all_after) {
        my $without=q{};
        for my $row (split /\0/,$raw,-1) {
          next unless length($row); $row=~/\A[^\t]+\t([^\0]+)\z/ or bad();
          $without.=$row."\0" unless exists($want{$1});
        }
        push @other,$without;
      }
      bad() unless $other[0] eq $other[1];
      my @tn=lstat($temp_name); bad() unless @tn && !S_ISLNK($tn[2]) && S_ISREG($tn[2])
        && $tn[3]==1 && $tn[4]==$<;
      sysopen(my $final,$temp_name,O_RDONLY|O_NOFOLLOW) or bad(); my @fo=stat($final);
      bad() unless @fo && did(@fo) eq did(@tn); my $final_raw=read_fh($final); close($final) or bad();
      my @again=lstat(q{index}); bad() unless @again && !S_ISLNK($again[2])
        && did(@again) eq did(@opened) && read_fh($index) eq $index_raw; close($index) or bad();
      write_fh($lock,$final_raw); chmod($index_mode,$lock)==1 or bad(); $lock->sync or bad();
      my @lock_named=lstat(q{index.lock}); my @lock_open=stat($lock);
      bad() unless @lock_named && @lock_open && !S_ISLNK($lock_named[2])
        && S_ISREG($lock_named[2]) && $lock_named[3]==1 && $lock_named[4]==$<
        && did(@lock_named) eq $lock_id && did(@lock_open) eq $lock_id;
      close($lock) or bad(); undef $lock;
      unlink($temp_name) or bad(); undef $temp_name;
      rename(q{index.lock},q{index}) or bad(); $committed=1; $dir->sync or bad();
      close($dir) or bad(); undef $dir; exit 0;
      END {
        return if $committed;
        if (defined($temp_name)) { chdir($dir) if defined($dir); my @s=lstat($temp_name);
          unlink($temp_name) if @s && !S_ISLNK($s[2]) && S_ISREG($s[2]) && $s[3]==1 && $s[4]==$< }
        if (defined($lock_id)) { chdir($dir) if defined($dir); my @s=lstat(q{index.lock});
          unlink(q{index.lock}) if @s && !S_ISLNK($s[2]) && S_ISREG($s[2]) && did(@s) eq $lock_id }
      }
    '
}

stage_implementation_start_paths() { # exact initializer output; stages only proven-created leaves
  local created="$1" tab kind leaf id hash len extra path checked
  IMPLEMENTATION_INIT_ADDED=""
  IMPLEMENTATION_INIT_INDEX_RECORDS=""
  tab="$(printf '\t')"; IMPL_CREATED_PHASE=pre implementation_artifacts_batch created "$created" || return 1
  set --
  while IFS="$tab" read -r kind leaf id hash len extra; do
    [ "$kind" = created ] || continue
    [ -z "${extra:-}" ] || return 1
    path="$SPEC_REL/$leaf"
    if git ls-files --error-unmatch -- "$path" >/dev/null 2>&1; then
      implementation_index_exact "$path" "$hash" "$len" || return 1
    else
      set -- "$@" "$path"
    fi
  done <<EOF
$created
EOF
  if [ "$#" -ne 0 ]; then
    IMPLEMENTATION_INIT_ADDED="$(printf '%s\n' "$@")"
    IMPLEMENTATION_INIT_INDEX_RECORDS="$(implementation_index_add_records "$created" "$@")" \
      || return 1
    IMPL_CREATED_PHASE=selection-ready implementation_artifacts_batch created "$created" || return 1
    implementation_index_cas_add "$IMPLEMENTATION_INIT_INDEX_RECORDS" || return 1
    IMPL_CREATED_PHASE=after-index-cas-add implementation_artifacts_batch created "$created" || return 1
  fi
  IMPL_CREATED_PHASE=post implementation_artifacts_batch created "$created" || return 1
  IMPL_CREATED_PHASE=post-live implementation_artifacts_batch created "$created" || return 1
  checked=0
  while IFS="$tab" read -r kind leaf id hash len extra; do
    [ "$kind" = created ] || continue
    implementation_index_exact "$SPEC_REL/$leaf" "$hash" "$len" || return 1
    checked=$((checked + 1))
    if [ "$checked" -eq 1 ]; then
      IMPL_CREATED_PHASE=after-first-index implementation_artifacts_batch created "$created" || return 1
    fi
  done <<EOF
$created
EOF
}

preserve_implementation_start_paths() { # post-publication failure is preservation-only
  # POSIX has no conditional unlink-by-content. Any cleanup after publication can race an in-place
  # editor or a foreign index writer, so leave the complete committed transaction, live inodes and
  # current index untouched. A retry reconciles the transaction; manual recovery never loses bytes.
  implementation_init_token "$1" >/dev/null || return 1
}

invalidation_scopes() {
  case "$1" in
    stage-1-creative|stage-2-audit) printf 'architecture,implementation,quality,evidence' ;;
    stage-3-dev) printf 'implementation,quality,evidence' ;;
    stage-4-quality) printf 'quality,evidence' ;;
    *) return 2 ;;
  esac
}

state_tmp_cleanup_exact() {
  local leaf
  [ -n "${STATE_TMP:-}" ] && [ -n "${STATE_TMP_ID:-}" ] \
    && [ -n "${MUTATION_SPEC_PATH:-}" ] && [ -n "${MUTATION_SPEC_ID:-}" ] || return 1
  leaf="${STATE_TMP##*/}"
  SPEC_PATH="$MUTATION_SPEC_PATH" SPEC_ID="$MUTATION_SPEC_ID" LEAF="$leaf" \
    WANT_ID="$STATE_TMP_ID" RECORD="${STATE_TMP_RECORD:-}" perl -MDigest::SHA=sha256_hex \
      -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
        use strict; use warnings;
        sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
        my ($path,$spec_id,$leaf,$want_id,$record)=@ENV{qw(SPEC_PATH SPEC_ID LEAF WANT_ID RECORD)};
        exit 1 unless defined($leaf) && $leaf=~/\A\.state\.md\.[A-Za-z0-9]+\z/
          && defined($want_id) && $want_id=~/\A[0-9]+:[0-9]+\z/ && defined($record);
        my ($want_hash,$want_len,$want_mode);
        if (length($record)) {
          exit 1 unless $record=~/\A(?:v4-current|v3|v2|legacy)\|\Q$want_id\E\|([0-9a-f]{64})\|([0-9]+)\|(0[0-7]{3})\z/;
          ($want_hash,$want_len,$want_mode)=($1,$2,oct($3));
        }
        sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @ds=stat($dir);
        exit 1 unless @ds && S_ISDIR($ds[2]) && did(@ds) eq $spec_id; chdir($dir) or exit 1;
        opendir(my $dh,q{.}) or exit 1; my @match;
        while (defined(my $name=readdir($dh))) { next if $name eq q{.} || $name eq q{..};
          my @s=lstat($name); next unless @s && !S_ISLNK($s[2]) && S_ISREG($s[2]);
          push @match,$name if did(@s) eq $want_id;
        }
        closedir($dh) or exit 1; exit 1 unless @match==1;
        my $name=$match[0]; my $visible=($name eq $leaf);
        my @named=lstat($name); exit 1 unless @named && !S_ISLNK($named[2])
          && S_ISREG($named[2]) && $named[3]==1 && $named[4]==$< && did(@named) eq $want_id;
        sysopen(my $fh,$name,O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($fh);
        exit 1 unless @opened && did(@opened) eq $want_id;
        my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 1 unless defined($n);
          last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
        my @after=stat($fh); close($fh) or exit 1; my @again=lstat($name);
        exit 1 unless @after && @again && !S_ISLNK($again[2]) && did(@after) eq $want_id
          && did(@again) eq $want_id;
        if (length($record)) { exit 1 unless ($after[2]&0777)==$want_mode
          && length($raw)==$want_len && sha256_hex($raw) eq $want_hash }
        unlink($name) or exit 1;
        exit($visible ? 0 : 2);
      ' >/dev/null 2>&1
}

cleanup_state_tmp() {
  local cleanup_rc=0
  if [ -n "${STATE_TMP:-}" ]; then
    state_tmp_cleanup_exact || cleanup_rc=1
  fi
  if [ -n "${VERIFY_TMP:-}" ] && [ -n "${VERIFY_TMP_ID:-}" ]; then
    perl "$PRIVATE_TMP_HELPER" cleanup "$VERIFY_TMP" "$VERIFY_TMP_ID" >/dev/null 2>&1 \
      || cleanup_rc=1
  elif [ -n "${VERIFY_TMP:-}" ]; then
    cleanup_rc=1
  fi
  if [ "${PRESERVE_MUTATION_LOCK:-0}" -eq 0 ] \
      && [ -n "${MUTATION_LOCK_BASE:-}" ] && [ -n "${MUTATION_LOCK_BASE_ID:-}" ] \
      && [ -n "${MUTATION_LOCK_ROOT:-}" ] && [ -n "${MUTATION_LOCK_ROOT_ID:-}" ] \
      && [ -n "${MUTATION_LOCK_NAME:-}" ] && [ -n "${MUTATION_LOCK_ID:-}" ] \
      && [ -n "${MUTATION_LOCK_OWNER_ID:-}" ] && [ -n "${MUTATION_LOCK_NONCE:-}" ]; then
    LOCK_BASE="$MUTATION_LOCK_BASE" BASE_ID="$MUTATION_LOCK_BASE_ID" \
      LOCK_ROOT="$MUTATION_LOCK_ROOT" ROOT_ID="$MUTATION_LOCK_ROOT_ID" \
      LOCK_NAME="$MUTATION_LOCK_NAME" LOCK_ID="$MUTATION_LOCK_ID" \
      OWNER_ID="$MUTATION_LOCK_OWNER_ID" LOCK_NONCE="$MUTATION_LOCK_NONCE" \
      LOCK_PID="$MUTATION_LOCK_PID" LOCK_STARTED="$MUTATION_LOCK_STARTED" \
      LOCK_BIRTH="$MUTATION_LOCK_BIRTH" \
      perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
        use strict; use warnings; my ($base,$base_id,$root,$root_id,$path,$want,$owant,$nonce,$pid,$started,$birth)=
          @ENV{qw(LOCK_BASE BASE_ID LOCK_ROOT ROOT_ID LOCK_NAME LOCK_ID OWNER_ID LOCK_NONCE LOCK_PID LOCK_STARTED LOCK_BIRTH)};
        sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
        sysopen(my $base_fh,$base,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @b=stat($base_fh);
        exit 1 unless @b && S_ISDIR($b[2]) && did(@b) eq $base_id; chdir($base_fh) or exit 1;
        my @rn=lstat($root); exit 1 unless @rn && !S_ISLNK($rn[2]) && S_ISDIR($rn[2])
          && did(@rn) eq $root_id;
        sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @ro=stat($root_fh);
        exit 1 unless @ro && did(@ro) eq $root_id; chdir($root_fh) or exit 1;
        my @named=lstat($path); exit 1 unless @named && !S_ISLNK($named[2])
          && S_ISDIR($named[2]) && did(@named) eq $want;
        sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
        exit 1 unless @opened && did(@opened) eq $want; chdir($dir) or exit 1;
        sysopen(my $owner,q{owner},O_RDONLY|O_NOFOLLOW) or exit 1; my @o=stat($owner); my @on=lstat(q{owner});
        exit 1 unless @o && @on && S_ISREG($o[2]) && $o[3]==1 && did(@o) eq $owant
          && did(@on) eq $owant; local $/; my $raw=<$owner>//q{}; close $owner or exit 1;
        my $expected="pid=$pid\nstarted=$started\nbirth=$birth\nnonce=$nonce\n";
        exit 1 unless $raw eq $expected;
        unlink(q{owner}) or exit 1; opendir(my $dh,q{.}) or exit 1;
        my @extra=grep { $_ ne q{.} && $_ ne q{..} } readdir($dh); closedir($dh) or exit 1;
        exit 1 if @extra; chdir($root_fh) or exit 1; @named=lstat($path);
        exit 1 unless @named && !S_ISLNK($named[2]) && did(@named) eq $want; rmdir($path) or exit 1;
      ' >/dev/null 2>&1 || cleanup_rc=1
  elif [ "${PRESERVE_MUTATION_LOCK:-0}" -eq 0 ] && [ -n "${MUTATION_LOCK_NAME:-}" ]; then
    cleanup_rc=1
  fi
  STATE_TMP=""
  STATE_TMP_ID=""
  STATE_TMP_RECORD=""
  STATE_SNAPSHOT_LEAF=""
  STATE_SNAPSHOT_RECORD=""
  STATE_BASE_RECORD=""
  VERIFY_TMP=""
  VERIFY_TMP_ID=""
  MUTATION_LOCK_BASE=""
  MUTATION_LOCK_BASE_ID=""
  MUTATION_LOCK_ROOT=""
  MUTATION_LOCK_ROOT_ID=""
  MUTATION_LOCK_NAME=""
  MUTATION_LOCK_ID=""
  MUTATION_LOCK_OWNER_ID=""
  MUTATION_LOCK_NONCE=""
  MUTATION_LOCK_PID=""
  MUTATION_LOCK_STARTED=""
  MUTATION_LOCK_BIRTH=""
  MUTATION_RECOVERY_LOCK_ID=""
  MUTATION_RECOVERY_OWNER_ID=""
  MUTATION_RECOVERY_NONCE=""
  MUTATION_RECOVERY_PID=""
  MUTATION_RECOVERY_STARTED=""
  MUTATION_RECOVERY_BIRTH=""
  MUTATION_SPEC_PATH=""
  MUTATION_SPEC_ID=""
  MUTATION_WAL_NAME=""
  STATE_TX_READY=0
  AUDIT_ROWS=""
  PRESERVE_MUTATION_LOCK=0
  return "$cleanup_rc"
}
pipeline_exit() {
  local rc=$?
  trap - EXIT
  if [ "$rc" -eq 0 ] && { [ "${STATE_TX_READY:-0}" -ne 0 ] || [ -n "${AUDIT_ROWS:-}" ]; }; then
    echo "pipeline-state: FATAL: незавершённая state/audit transaction" >&2
    rc=1
  fi
  cleanup_state_tmp || { [ "$rc" -ne 0 ] || rc=1; }
  exit "$rc"
}
signal_exit() { # cleanup alone must not let an interrupted transition continue
  local code="$1"
  cleanup_state_tmp || true
  exit "$code"
}
trap pipeline_exit EXIT
trap 'signal_exit 129' HUP
trap 'signal_exit 130' INT
trap 'signal_exit 143' TERM

validate_state_shape() { # <state-file> -> v4-current|v3|v2|legacy; malformed -> exit 2
  local f="${1:-$STATE}"
  [ -r "$STATE_READER" ] || die "shared V4 state reader недоступен: $STATE_READER"
  perl "$STATE_READER" "$f" 3<&0
}

validate_state_bytes() { # trusted bytes already captured once by the caller; stdin -> profile
  PIPELINE_STATE_TRUSTED_STDIN=1 PIPELINE_STATE_OUTPUT=profile validate_state_shape -
}

require_current_authority() { # every state-authorizing command except explicit migrate-v4
  local profile
  profile="$(validate_state_shape "$STATE")" || return $?
  case "$profile" in
    v4-current) return 0 ;;
    legacy|v2|v3)
      die "$CMD: migration-required: State $profile inspect-only; выполни migrate-v4" ;;
    *) die "$CMD: contract-migration-required: Delivery-Contract не current" ;;
  esac
}

state_tmp_create() {
  local leaf
  [ -n "${MUTATION_LOCK_NAME:-}" ] || die "$CMD: state temp без unified lock"
  [ -z "${STATE_TMP:-}" ] || die "внутренняя ошибка: state temp уже существует"
  STATE_TMP_RECORD=""; STATE_SNAPSHOT_LEAF=""; STATE_SNAPSHOT_RECORD=""
  STATE_TMP="$(umask 077; mktemp "$DIR/.state.md.XXXXXX")" \
    || die "$CMD: state temp не создан"
  leaf="${STATE_TMP##*/}"
  STATE_TMP_ID="$(SPEC_PATH="$MUTATION_SPEC_PATH" SPEC_ID="$MUTATION_SPEC_ID" LEAF="$leaf" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      my ($path,$spec_id,$leaf)=@ENV{qw(SPEC_PATH SPEC_ID LEAF)};
      exit 1 unless defined($leaf) && $leaf=~/\A\.state\.md\.[A-Za-z0-9]+\z/;
      sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @d=stat($dir);
      exit 1 unless @d && S_ISDIR($d[2]) && did(@d) eq $spec_id; chdir($dir) or exit 1;
      my @n=lstat($leaf); exit 1 unless @n && !S_ISLNK($n[2]) && S_ISREG($n[2])
        && $n[3]==1 && $n[4]==$< && ($n[2]&0777)==0600;
      sysopen(my $fh,$leaf,O_RDONLY|O_NOFOLLOW) or exit 1; my @o=stat($fh); my @a=lstat($leaf);
      exit 1 unless @o && @a && did(@o) eq did(@n) && did(@a) eq did(@n) && $o[7]==0;
      print did(@o);
    ' 2>/dev/null)" || die "$CMD: state temp creation identity не подтверждён"
}

state_tmp_initialize() { # template bytes on stdin -> first trusted record, same creation inode
  local bare full tail
  [ -n "$STATE_TMP" ] && [ -n "$STATE_TMP_ID" ] && [ -z "$STATE_TMP_RECORD" ] \
    || die "$CMD: state temp initialize без creation authority"
  bare="$(STATE_PATH="$STATE_TMP" WANT_ID="$STATE_TMP_ID" perl -MDigest::SHA=sha256_hex \
    -MIO::Handle -MFcntl=:DEFAULT,O_RDWR,O_NOFOLLOW,S_ISLNK,S_ISREG -e '
      use strict; use warnings; sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      my ($path,$want)=@ENV{qw(STATE_PATH WANT_ID)}; my $raw=q{};
      while (1) { my $n=sysread(STDIN,my $buf,65536); exit 1 unless defined($n);
        last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 }
      exit 1 if $raw=~/\x00/;
      my @n=lstat($path); exit 1 unless @n && !S_ISLNK($n[2]) && S_ISREG($n[2])
        && $n[3]==1 && did(@n) eq $want;
      sysopen(my $fh,$path,O_RDWR|O_NOFOLLOW) or exit 1; my @o=stat($fh);
      exit 1 unless @o && did(@o) eq $want && $o[7]==0 && ($o[2]&0777)==0600;
      chmod(0644,$fh)==1 or exit 1; my $off=0;
      while ($off<length($raw)) { my $w=syswrite($fh,$raw,length($raw)-$off,$off);
        exit 1 unless defined($w)&&$w; $off+=$w }
      $fh->sync or exit 1; sysseek($fh,0,0)>=0 or exit 1; my $again=q{};
      while (1) { my $r=sysread($fh,my $buf,65536); exit 1 unless defined($r);
        last unless $r; $again.=$buf; exit 1 if length($again)>16777216 }
      my @a=stat($fh); close($fh) or exit 1; my @p=lstat($path);
      exit 1 unless $again eq $raw && @a && @p && !S_ISLNK($p[2])
        && did(@a) eq $want && did(@p) eq $want && ($a[2]&0777)==0644;
      print join(q{|},$want,sha256_hex($raw),length($raw),q{0644});
    ' 2>/dev/null)" || die "$CMD: state template write не подтверждён"
  full="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE_TMP")" \
    || die "$CMD: initialized state shape невалиден"
  tail="${full#*|}"; [ "$tail" = "$bare" ] \
    || die "$CMD: initialized state identity/digest mismatch"
  STATE_TMP_RECORD="$full"
}

state_temp_transform() { # op [args...]; descriptor-CAS on the previous exact record
  local op="$1" bare full tail
  shift
  [ -n "$STATE_TMP" ] && [ -n "$STATE_TMP_ID" ] && [ -n "$STATE_TMP_RECORD" ] \
    || die "$CMD: state transform без prior authority"
  bare="$(perl -MDigest::SHA=sha256_hex -MIO::Handle \
    -MFcntl=:DEFAULT,O_RDWR,O_NOFOLLOW,S_ISLNK,S_ISREG \
    - "$STATE_TMP" "$STATE_TMP_RECORD" "$op" "$@" <<'PERL'
use strict; use warnings;
sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
sub read_all { my ($fh)=@_; my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536);
  exit 1 unless defined($n); last unless $n; $raw.=$buf; exit 1 if length($raw)>16777216 } return $raw }
my ($path,$record,$op,@arg)=@ARGV;
exit 1 unless defined($record)
  && $record=~/\A(?:v4-current|v3|v2|legacy)\|([0-9]+:[0-9]+)\|([0-9a-f]{64})\|([0-9]+)\|(0[0-7]{3})\z/;
my ($want,$want_hash,$want_len,$want_mode)=($1,$2,$3,oct($4));
my @n=lstat($path); exit 1 unless @n && !S_ISLNK($n[2]) && S_ISREG($n[2])
  && $n[3]==1 && did(@n) eq $want && ($n[2]&0777)==$want_mode;
sysopen(my $fh,$path,O_RDWR|O_NOFOLLOW) or exit 1; my @o=stat($fh);
exit 1 unless @o && did(@o) eq $want; my $raw=read_all($fh);
exit 1 unless length($raw)==$want_len && sha256_hex($raw) eq $want_hash;
sysseek($fh,0,0)>=0 or exit 1; my $confirm=read_all($fh); my @before=stat($fh); @n=lstat($path);
exit 1 unless $confirm eq $raw && @before && @n && !S_ISLNK($n[2])
  && did(@before) eq $want && did(@n) eq $want;
my $count=0; my $dash=pack(q{C*},0xe2,0x80,0x94);
if ($op eq q{mark-stage}) {
  exit 1 unless @arg==2 && $arg[0]=~/\Astage-[a-z0-9-]+\z/ && $arg[1]=~/\A[ x-]\z/;
  my ($s,$v)=@arg; $count=($raw=~s/^- \[[ x-]\] \Q$s\E$/- [$v] $s/mg); exit 1 unless $count==1;
} elsif ($op eq q{set-gate}) {
  exit 1 unless @arg==2 && $arg[0]=~/\A(?:constitution-gate|user-approval|quality-verdict)\z/;
  my ($k,$v)=@arg; $count=($raw=~s/^- \Q$k\E:.*$/- $k: $v/mg); exit 1 unless $count==1;
} elsif ($op eq q{set-conf}) {
  exit 1 unless @arg==2 && $arg[0]=~/\Astage-[a-z0-9-]+\z/; my ($s,$v)=@arg;
  if ($raw!~/^## Confidence$/m) {
    my $block="\n## Confidence\n\n".join("\n",map { "- confidence-$_: $dash" }
      qw(stage-1-creative stage-2-audit stage-3-dev stage-4-quality));
    $count=($raw=~s/^(- quality-verdict:.*)$/$1$block/m); exit 1 unless $count==1;
  }
  $count=($raw=~s/^- confidence-\Q$s\E: .*$/- confidence-$s: $v/mg); exit 1 unless $count==1;
} elsif ($op eq q{upd-ts}) {
  exit 1 unless @arg==1; my $v=$arg[0]; $count=($raw=~s/^- Updated:.*$/- Updated: $v/mg); exit 1 unless $count==1;
} elsif ($op eq q{set-quality}) {
  exit 1 unless @arg==1; my $v=$arg[0]; $count=($raw=~s/^- Quality-HEAD:.*$/- Quality-HEAD: $v/mg); exit 1 unless $count==1;
} elsif ($op eq q{set-root}) {
  exit 1 unless @arg==2 && $arg[0]=~/\A(?:Design-Root|Implementation-Root|Evidence-Root)\z/;
  my ($k,$v)=@arg; $count=($raw=~s/^- \Q$k\E:.*$/- $k: $v/mg); exit 1 unless $count==1;
} elsif ($op eq q{migrate-v4}) {
  exit 1 unless @arg==2 && $arg[0]=~/\A(?:feature|bugfix|enterprise)\z/;
  my ($scope,$ts)=@arg;
  if ($raw=~/^- State-Version:/m) {
    $count=($raw=~s/^- State-Version: (?:2|3)$/- State-Version: 4/mg); exit 1 unless $count==1;
  } else {
    # Every readable V1 profile has one header SPEC_DIR anchor, while its prose/title layout was
    # never canonical.  Insert relative to that authority anchor instead of assuming "title + blank
    # line", otherwise an inspectable historical state could have no forward migration path.
    $count=($raw=~s/^(- SPEC_DIR:.*)$/- State-Version: 4\n$1/mg); exit 1 unless $count==1;
  }
  $count=($raw=~s/^- State-Version: 4$/- State-Version: 4\n- Delivery-Contract: architecture-evidence-v1/mg);
  exit 1 unless $count==1;
  if ($raw!~/^- Scope:/m) {
    $count=($raw=~s/^(- SPEC_DIR:.*)$/$1\n- Scope: $scope/mg); exit 1 unless $count==1;
  }
  if ($raw!~/^- Ticket:/m) {
    $count=($raw=~s/^(- Scope:.*)$/$1\n- Ticket: $dash/mg); exit 1 unless $count==1;
  }
  $raw=~s/^- Quality-HEAD:.*\n//mg;
  my $roots="- Design-Root: $dash\n- Implementation-Root: $dash\n- Evidence-Root: $dash\n- Quality-HEAD: $dash";
  $count=($raw=~s/^(- Updated:.*)$/$1\n$roots/mg); exit 1 unless $count==1;
  for my $s (qw(stage-2-audit stage-3-dev stage-4-quality)) {
    $count=($raw=~s/^- \[[ x-]\] \Q$s\E$/- [ ] $s/mg); exit 1 unless $count==1;
  }
  for my $g (qw(constitution-gate user-approval quality-verdict)) {
    $count=($raw=~s/^- \Q$g\E:.*$/- $g: $dash/mg); exit 1 unless $count==1;
  }
  if ($raw!~/^## Confidence$/m) {
    my $block="\n## Confidence\n\n".join("\n",map { "- confidence-$_: $dash" }
      qw(stage-1-creative stage-2-audit stage-3-dev stage-4-quality));
    $count=($raw=~s/^(- quality-verdict:.*)$/$1$block/m); exit 1 unless $count==1;
  }
  for my $s (qw(stage-2-audit stage-3-dev stage-4-quality)) {
    $count=($raw=~s/^- confidence-\Q$s\E:.*$/- confidence-$s: $dash/mg); exit 1 unless $count==1;
  }
  $raw=~s/^- \[[ x-]\] (unit:.*)$/- [ ] $1/mg;
  $count=($raw=~s/^- Updated:.*$/- Updated: $ts/mg); exit 1 unless $count==1;
} elsif ($op eq q{reset-units}) {
  exit 1 unless @arg==0; $raw=~s/^- \[[ x-]\] (unit:.*)$/- [ ] $1/mg;
} elsif ($op eq q{units-set}) {
  exit 1 unless @arg==1; my @u=split(/,/,$arg[0],-1); exit 1 unless @u;
  for (@u) { exit 1 unless /\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/ }
  $raw=~s/\n## Units\n.*\z/\n/s;
  $raw.="\n## Units\n\n".join(q{},map { "- [ ] unit:$_\n" } @u);
} elsif ($op eq q{unit-done}) {
  exit 1 unless @arg==1 && $arg[0]=~/\A[A-Za-z0-9][A-Za-z0-9._-]{0,63}\z/; my $u=$arg[0];
  $count=($raw=~s/^- \[[ x-]\] unit:\Q$u\E$/- [x] unit:$u/mg); exit 1 unless $count==1;
} elsif ($op eq q{link-ticket}) {
  exit 1 unless @arg==1; my $v=$arg[0];
  if ($raw=~/^- Ticket:/m) { $count=($raw=~s/^- Ticket:.*$/- Ticket: $v/mg); exit 1 unless $count==1 }
  elsif ($raw=~s/^(- Scope: .*)$/$1\n- Ticket: $v/m) { }
  elsif ($raw=~s/^(- SPEC_DIR: .*)$/$1\n- Ticket: $v/m) { }
  else { exit 1 }
} elsif ($op eq q{confidence-ack}) {
  exit 1 unless @arg==2 && $arg[0]=~/\Astage-[a-z0-9-]+\z/; my ($s,$suffix)=@arg;
  $count=($raw=~s/^(- confidence-\Q$s\E: .*)$/$1$suffix/mg); exit 1 unless $count==1;
} else { exit 1 }
exit 1 if $raw=~/\x00/ || length($raw)>16777216;
truncate($fh,0) or exit 1; sysseek($fh,0,0)>=0 or exit 1; my $off=0;
while ($off<length($raw)) { my $w=syswrite($fh,$raw,length($raw)-$off,$off);
  exit 1 unless defined($w)&&$w; $off+=$w }
$fh->sync or exit 1; sysseek($fh,0,0)>=0 or exit 1; my $again=read_all($fh);
my @a=stat($fh); close($fh) or exit 1; my @p=lstat($path);
exit 1 unless $again eq $raw && @a && @p && !S_ISLNK($p[2])
  && did(@a) eq $want && did(@p) eq $want && ($a[2]&0777)==$want_mode;
print join(q{|},$want,sha256_hex($raw),length($raw),sprintf(q{%04o},$want_mode));
PERL
  )" || die "$CMD: descriptor state transform '$op' failed"
  full="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE_TMP")" \
    || die "$CMD: state shape invalid after '$op'"
  tail="${full#*|}"; [ "$tail" = "$bare" ] \
    || die "$CMD: state record mismatch after '$op'"
  STATE_TMP_RECORD="$full"
}

state_tx_begin() {
  local live_before live_after temp_record live_tail temp_tail
  [ -n "${MUTATION_LOCK_NAME:-}" ] || die "$CMD: state transaction без unified lock"
  live_before="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE")" \
    || die "$CMD: source state authority невалидна"
  state_tmp_create
  if [ "${HARNESS_PIPELINE_STATE_PRECOPY_TEST_PAUSE:-0}" = 1 ]; then
    { printf 'pid=%s\n' "$$" >&9; } 2>/dev/null || die "$CMD: state pre-copy test gate недоступен"
    kill -STOP "$$" 2>/dev/null || die "$CMD: state pre-copy test pause не установлен"
  fi
  # The destination is never reopened by cp(1): state_tmp_initialize opens the recorded creation
  # inode O_NOFOLLOW and consumes bytes emitted only after a descriptor-stable source validation.
  state_tmp_initialize < <(PIPELINE_STATE_OUTPUT=raw validate_state_shape "$STATE")
  if [ "${HARNESS_PIPELINE_STATE_COPY_TEST_PAUSE:-0}" = 1 ]; then
    { printf 'pid=%s\n' "$$" >&9; } 2>/dev/null || die "$CMD: state copy test gate недоступен"
    kill -STOP "$$" 2>/dev/null || die "$CMD: state copy test pause не установлен"
  fi
  temp_record="$STATE_TMP_RECORD"
  live_after="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE")" \
    || die "$CMD: source state authority изменилась"
  [ "$live_before" = "$live_after" ] || die "$CMD: source state изменилась при copy"
  case "$temp_record" in *"|$STATE_TMP_ID|"*) ;; *) die "$CMD: state temp creation inode replaced";; esac
  live_tail="${live_before#*|}"; live_tail="${live_tail#*|}"
  temp_tail="${temp_record#*|}"; temp_tail="${temp_tail#*|}"
  [ "$live_tail" = "$temp_tail" ] || die "$CMD: state temp bytes не равны source state"
  STATE_TMP_RECORD="$temp_record"
  STATE_BASE_RECORD="$live_before"
}
state_tx_commit() {
  local before after snapshot src_tail snap_tail
  [ -n "${MUTATION_LOCK_NAME:-}" ] || die "$CMD: state commit без unified lock"
  make_verify_tmp
  verify_tmp_guard || die "$CMD: private state snapshot root identity changed"
  before="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE_TMP")" \
    || die "$CMD: state temp validation/identity failed"
  [ "$before" = "$STATE_TMP_RECORD" ] \
    || die "$CMD: state temp changed outside descriptor transform chain"
  STATE_SNAPSHOT_LEAF="state-tx"
  snapshot="$(PIPELINE_STATE_OUTPUT=raw validate_state_shape "$STATE_TMP" \
    | perl "$PRIVATE_TMP_HELPER" write "$VERIFY_TMP" "$VERIFY_TMP_ID" "$STATE_SNAPSHOT_LEAF" 2>/dev/null)" \
    || die "$CMD: validated state snapshot sealing failed"
  after="$(PIPELINE_STATE_OUTPUT=record validate_state_shape "$STATE_TMP")" \
    || die "$CMD: state temp post-snapshot identity failed"
  [ "$before" = "$after" ] || die "$CMD: state temp identity/bytes changed during sealing"
  src_tail="${before#*|}"; src_tail="${src_tail#*|}"; src_tail="${src_tail%|*}"
  snap_tail="${snapshot#*|}"
  [ "$src_tail" = "$snap_tail" ] \
    || die "$CMD: sealed state digest/length не совпадает validated source"
  STATE_TMP_RECORD="$before"
  STATE_SNAPSHOT_RECORD="$snapshot"
  state_tmp_cleanup_exact \
    || die "$CMD: state source cleanup/identity failed before durable commit"
  STATE_TMP=""; STATE_TMP_ID=""
  STATE_TX_READY=1
  if [ "${HARNESS_PIPELINE_STATE_SNAPSHOT_TEST_PAUSE:-0}" = 1 ]; then
    { printf 'pid=%s\n' "$$" >&9; } 2>/dev/null \
      || die "$CMD: state snapshot test gate недоступен"
    kill -STOP "$$" 2>/dev/null || die "$CMD: state snapshot test pause не установлен"
  fi
}

mutation_lock_acquire() {
  local dir_abs dir_id repo_root base base_expected_id="" material root lock_name parsed rc=0
  [ -z "$MUTATION_LOCK_NAME" ] || die "$CMD: mutation lock уже удерживается"
  if [ -n "$OUTER_REGISTERED_ROOT" ]; then
    revalidate_outer_registered_authority \
      || die "$CMD: frozen outer Git authority changed"
  fi
  dir_abs="$(cd "$DIR" 2>/dev/null && pwd -P)" \
    || die "$CMD: SPEC_DIR недоступен для mutation lock"
  dir_id="$(SPEC_PATH="$dir_abs" perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR -e '
    sysopen(my $fh,$ENV{SPEC_PATH},O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @s=stat($fh);
    exit 1 unless @s && S_ISDIR($s[2]); print $s[0],q{:},$s[1];
  ' 2>/dev/null)" || die "$CMD: SPEC_DIR inode не подтверждён для mutation lock"
  if [ -n "$OUTER_REGISTERED_ROOT" ]; then
    revalidate_outer_registered_authority \
      || die "$CMD: frozen outer Git authority changed"
    repo_root="$OUTER_REGISTERED_ROOT"
    case "$dir_abs" in
      "$repo_root") material="git:$repo_root:." ;;
      "$repo_root"/*) material="git:$repo_root:${dir_abs#$repo_root/}" ;;
      *) die "$CMD: SPEC_DIR вне canonical Git root" ;;
    esac
    base="$OUTER_REGISTERED_COMMON"
    base_expected_id="$OUTER_REGISTERED_COMMON_ID"
  else
    base="$(cd "$(dirname "$dir_abs")" 2>/dev/null && pwd -P)" \
      || die "$CMD: parent SPEC_DIR недоступен для mutation lock"
    material="path:$dir_abs"
  fi
  root="agent-harness-pipeline-locks"
  lock_name="$(printf '%s\0%s' 'pipeline-state-pair-v1' "$material" \
    | perl -MDigest::SHA=sha256_hex -0777 -ne 'print sha256_hex($_)')" \
    || die "$CMD: mutation lock key не вычислен"
  lock_name="$lock_name.lock"
  parsed="$(LOCK_BASE="$base" LOCK_BASE_EXPECTED_ID="$base_expected_id" \
    LOCK_ROOT="$root" LOCK_NAME="$lock_name" OWNER_PID="$$" \
    perl -MDigest::SHA=sha256_hex -MErrno=EEXIST,ENOENT,ESRCH \
    -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
      use strict; use warnings;
      my ($base,$base_expected,$root,$path,$pid)=
        @ENV{qw(LOCK_BASE LOCK_BASE_EXPECTED_ID LOCK_ROOT LOCK_NAME OWNER_PID)};
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      # Kernel birth identity v2: Linux binds boot UUID + /proc stat field 22; Darwin binds the
      # microsecond proc_bsdinfo start timeval.  The serialized owner field remains one SHA-256.
      sub birth {
        my ($who)=@_; return q{} unless $who=~/\A[1-9][0-9]*\z/;
        my $identity;
        if ($^O eq q{linux}) {
          open(my $boot_fh,q{<},q{/proc/sys/kernel/random/boot_id}) or return q{};
          my $boot=<$boot_fh>//q{}; close($boot_fh) or return q{}; chomp($boot);
          return q{} unless $boot=~/\A[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\z/;
          open(my $stat_fh,q{<},qq{/proc/$who/stat}) or return q{};
          local $/; my $stat=<$stat_fh>//q{}; close($stat_fh) or return q{};
          return q{} unless $stat=~/\A\Q$who\E \((.*)\) ([A-Za-z]) (.*)\n?\z/s;
          my @field=split /\s+/, $3;
          return q{} unless @field>=19 && $field[18]=~/\A[0-9]+\z/;
          $identity=join(q{|},q{linux-proc-stat-v1},$boot,$who,$field[18]);
        } elsif ($^O eq q{darwin}) {
          # proc_pidinfo(PROC_PIDTBSDINFO) maps to proc_info syscall 336, call 2, flavor 3.
          my $buf=chr(0) x 136;
          my $size=syscall(336,2,0+$who,3,0,$buf,length($buf));
          return q{} unless defined($size) && $size==136;
          my $embedded=unpack(q{V},substr($buf,12,4));
          my ($sec,$usec)=unpack(q{Q<Q<},substr($buf,120,16));
          return q{} unless $embedded==$who && $sec>0 && $usec<1_000_000;
          $identity=join(q{|},q{darwin-proc-bsdinfo-v1},$who,$sec,$usec);
        } else {
          return q{};
        }
        return sha256_hex($identity);
      }
      sub legacy_birth {
        my ($who)=@_; return q{} unless $who=~/\A[1-9][0-9]*\z/;
        local $ENV{LC_ALL}=q{C}; local $ENV{LANG}=q{C}; local $ENV{TZ}=q{UTC};
        open(my $ps,q{-|},q{/bin/ps},q{-o},q{lstart=},q{-p},$who) or return q{};
        local $/; my $raw=<$ps>//q{}; close($ps) or return q{};
        $raw=~s/^\s+|\s+$//g; $raw=~s/\s+/ /g;
        return length($raw) ? sha256_hex($raw) : q{};
      }
      sysopen(my $base_fh,$base,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @b=stat($base_fh);
      exit 1 unless @b && S_ISDIR($b[2]) && defined($base_expected)
        && (!length($base_expected) || ($base_expected=~/\A[0-9]+:[0-9]+\z/
          && did(@b) eq $base_expected));
      chdir($base_fh) or exit 1;
      if (!mkdir($root,0700)) { exit 1 unless $!{EEXIST} }
      my @rn=lstat($root); exit 1 unless @rn && !S_ISLNK($rn[2]) && S_ISDIR($rn[2])
        && $rn[4]==$< && ($rn[2]&0777)==0700;
      sysopen(my $root_fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @ro=stat($root_fh);
      exit 1 unless @ro && did(@ro) eq did(@rn); chdir($root_fh) or exit 1;
      sub quarantine {
        my ($expected)=@_; my $q=$path.q{.stale.}.$pid.q{.}.int(rand(1000000000));
        chdir($root_fh) or exit 1; rename($path,$q) or return 0; my @named=lstat($q);
        exit 1 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]) && did(@named) eq $expected;
        sysopen(my $dir,$q,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
        exit 1 unless @opened && did(@opened) eq $expected; chdir($dir) or exit 1;
        my @owner=lstat(q{owner});
        if (@owner) {
          exit 1 if S_ISLNK($owner[2]) || !S_ISREG($owner[2]) || $owner[3]!=1;
          sysopen(my $fh,q{owner},O_RDONLY|O_NOFOLLOW) or exit 1; my @o=stat($fh);
          exit 1 unless @o && did(@o) eq did(@owner); close $fh or exit 1; unlink(q{owner}) or exit 1;
        } elsif (!$!{ENOENT}) { exit 1 }
        opendir(my $dh,q{.}) or exit 1; my @extra=grep { $_ ne q{.} && $_ ne q{..} } readdir($dh);
        closedir($dh) or exit 1; exit 1 if @extra; chdir($root_fh) or exit 1;
        rmdir($q) or exit 1; return 1;
      }
      my $made=0; my @recovery=(q{-}) x 6;
      for (1..5) {
        if (mkdir($path,0700)) { $made=1; last }
        exit 1 unless $!{EEXIST}; my @old=lstat($path);
        exit 1 unless @old && !S_ISLNK($old[2]) && S_ISDIR($old[2])
          && $old[4]==$< && ($old[2]&0777)==0700;
        sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
        exit 1 unless @opened && did(@opened) eq did(@old); chdir($dir) or exit 1;
        my ($active,$stale)=(0,0);
        my ($old_owner_id,$old_nonce,$old_pid,$old_started,$old_birth)=(q{-}) x 5;
        if (sysopen(my $fh,q{owner},O_RDONLY|O_NOFOLLOW)) {
          my @o=stat($fh); my @n=lstat(q{owner}); local $/; my $raw=<$fh>//q{}; close $fh or exit 1;
          exit 1 unless @o && @n && S_ISREG($o[2]) && $o[3]==1 && ($o[2]&0777)==0600
            && did(@o) eq did(@n);
          if ($raw=~/\Apid=([1-9][0-9]*)\nstarted=([1-9][0-9]*)\nbirth=([0-9a-f]{64}|unavailable)\nnonce=([0-9a-f]{64})\n\z/) {
            my ($opid,$started,$obirth,$ononce)=($1,$2,$3,$4);
            ($old_owner_id,$old_nonce,$old_pid,$old_started,$old_birth)=
              (did(@o),$ononce,$opid,$started,$obirth);
            if (kill(0,$opid)) {
              my $now=birth($opid); my $legacy=legacy_birth($opid);
              if ($obirth eq q{unavailable}) { $active=1 }
              elsif ((length($now) && $now eq $obirth)
                  || (length($legacy) && $legacy eq $obirth)) { $active=1 }
              elsif (length($now) && length($legacy)) { $stale=1 }
              else { $active=1 } # live PID with no comparable kernel view is never reclaimed
            } elsif ($!{ESRCH}) { $stale=1 } else { $active=1 }
          } else { $active=1 if time-$old[9]<30; $stale=1 unless $active }
        } elsif ($!{ENOENT}) { $active=1 if time-$old[9]<30; $stale=1 unless $active }
        else { exit 1 }
        chdir($root_fh) or exit 1; my @again=lstat($path);
        exit 1 unless @again && !S_ISLNK($again[2]) && did(@again) eq did(@old);
        @recovery=(did(@old),$old_owner_id,$old_nonce,$old_pid,$old_started,$old_birth)
          if $stale && $old_nonce ne q{-};
        exit 75 if $active; exit 1 unless $stale && quarantine(did(@old));
      }
      exit 1 unless $made; chdir($root_fh) or exit 1; my @named=lstat($path);
      exit 1 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2])
        && $named[4]==$< && ($named[2]&0777)==0700;
      sysopen(my $dir,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($dir);
      exit 1 unless @opened && did(@opened) eq did(@named); chdir($dir) or exit 1;
      sysopen(my $ur,q{/dev/urandom},O_RDONLY) or exit 1; my $random=q{};
      sysread($ur,$random,32)==32 or exit 1; close $ur or exit 1;
      my $started=time; my $obirth=birth($pid); $obirth=q{unavailable} unless length($obirth);
      my $nonce=sha256_hex($random.q{:}.$pid.q{:}.$started.q{:}.rand());
      sysopen(my $out,q{owner},O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or exit 1;
      my $raw="pid=$pid\nstarted=$started\nbirth=$obirth\nnonce=$nonce\n"; my $off=0;
      while ($off<length($raw)) { my $n=syswrite($out,$raw,length($raw)-$off,$off);
        exit 1 unless defined($n) && $n; $off+=$n }
      my @owner=stat($out); close $out or exit 1; my @on=lstat(q{owner});
      exit 1 unless @owner && @on && S_ISREG($owner[2]) && $owner[3]==1
        && ($owner[2]&0777)==0600 && did(@owner) eq did(@on);
      print join(q{|},did(@b),did(@ro),did(@opened),did(@owner),$nonce,$pid,$started,$obirth,@recovery);
    ' 2>/dev/null)" || rc=$?
  case "$rc" in
    0)
      MUTATION_LOCK_BASE="$base"; MUTATION_LOCK_BASE_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_ROOT="$root"; MUTATION_LOCK_ROOT_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_NAME="$lock_name"; MUTATION_LOCK_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_OWNER_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_NONCE="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_PID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_STARTED="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_LOCK_BIRTH="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_RECOVERY_LOCK_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_RECOVERY_OWNER_ID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_RECOVERY_NONCE="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_RECOVERY_PID="${parsed%%|*}"; parsed="${parsed#*|}"
      MUTATION_RECOVERY_STARTED="${parsed%%|*}"; MUTATION_RECOVERY_BIRTH="${parsed#*|}"
      case "$MUTATION_RECOVERY_LOCK_ID" in -) MUTATION_RECOVERY_LOCK_ID=""; MUTATION_RECOVERY_OWNER_ID=""; MUTATION_RECOVERY_NONCE=""; MUTATION_RECOVERY_PID=""; MUTATION_RECOVERY_STARTED=""; MUTATION_RECOVERY_BIRTH="";; esac
      MUTATION_SPEC_PATH="$dir_abs"; MUTATION_SPEC_ID="$dir_id"
      MUTATION_WAL_NAME="${lock_name%.lock}.txn";;
    75) die "$CMD: SPEC transition занят другой транзакцией";;
    *) die "$CMD: mutation lock identity/recovery не подтверждён";;
  esac
}

expected_spec_authority() { # root-id specs-id dir-id state-id from a descriptor-pinned caller
  local root
  [ "$#" -eq 4 ] || return 1
  [ -n "$OUTER_REGISTERED_ROOT" ] || return 1
  revalidate_outer_registered_authority || return 1
  root="$OUTER_REGISTERED_ROOT"
  ROOT="$root" REL="$INPUT_DIR" FROZEN_ROOT_ID="$OUTER_REGISTERED_WORKTREE_ID" \
    ROOT_ID="$1" SPECS_ID="$2" DIR_ID="$3" STATE_ID="$4" \
    perl -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG -e '
      use strict; use warnings;
      sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
      my ($root,$rel)=@ENV{qw(ROOT REL)}; my @want=@ENV{qw(ROOT_ID SPECS_ID DIR_ID STATE_ID)};
      exit 1 unless defined($rel) && $rel=~/\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/;
      exit 1 if grep { !defined($_) || $_!~/\A[0-9]+:[0-9]+\z/ } @want;
      exit 1 unless defined($ENV{FROZEN_ROOT_ID}) && $ENV{FROZEN_ROOT_ID}=~/\A[0-9]+:[0-9]+\z/
        && $want[0] eq $ENV{FROZEN_ROOT_ID};
      my @part=split m{/},$rel; exit 1 unless @part==2 && $part[0] eq q{specs};
      sysopen(my $fh,$root,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @s=stat($fh);
      exit 1 unless @s && S_ISDIR($s[2]) && did(@s) eq $want[0]; chdir($fh) or exit 1;
      my @hold=($fh); my $index=1;
      for my $leaf (@part) {
        my @named=lstat($leaf); exit 1 unless @named && !S_ISLNK($named[2]) && S_ISDIR($named[2]);
        sysopen(my $next,$leaf,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or exit 1; my @opened=stat($next);
        exit 1 unless @opened && did(@opened) eq did(@named) && did(@opened) eq $want[$index++];
        push @hold,$next; chdir($next) or exit 1;
      }
      my @named=lstat(q{state.md}); exit 1 unless @named && !S_ISLNK($named[2])
        && S_ISREG($named[2]) && $named[3]==1;
      sysopen(my $state,q{state.md},O_RDONLY|O_NOFOLLOW) or exit 1; my @opened=stat($state);
      exit 1 unless @opened && did(@opened) eq did(@named) && did(@opened) eq $want[3];
    ' >/dev/null 2>&1
}

pair_tx_engine() { # recover|commit; state-first install, append-only audit is the completion edge
  local mode="$1" state_leaf="${2:-}" state_ready="${3:-0}"
  PAIR_MODE="$mode" PAIR_AUDIT_ROWS="$AUDIT_ROWS" \
    PAIR_AUDIT_BASE_EXPECTED="$AUDIT_BASE_EXPECTED" \
    PAIR_LOCK_BASE="$MUTATION_LOCK_BASE" PAIR_BASE_ID="$MUTATION_LOCK_BASE_ID" \
    PAIR_LOCK_ROOT="$MUTATION_LOCK_ROOT" PAIR_ROOT_ID="$MUTATION_LOCK_ROOT_ID" \
    PAIR_LOCK_ID="$MUTATION_LOCK_ID" PAIR_OWNER_ID="$MUTATION_LOCK_OWNER_ID" \
    PAIR_LOCK_NONCE="$MUTATION_LOCK_NONCE" PAIR_LOCK_PID="$MUTATION_LOCK_PID" \
    PAIR_LOCK_STARTED="$MUTATION_LOCK_STARTED" PAIR_LOCK_BIRTH="$MUTATION_LOCK_BIRTH" \
    PAIR_RECOVERY_LOCK_ID="$MUTATION_RECOVERY_LOCK_ID" \
    PAIR_RECOVERY_OWNER_ID="$MUTATION_RECOVERY_OWNER_ID" \
    PAIR_RECOVERY_NONCE="$MUTATION_RECOVERY_NONCE" PAIR_RECOVERY_PID="$MUTATION_RECOVERY_PID" \
    PAIR_RECOVERY_STARTED="$MUTATION_RECOVERY_STARTED" PAIR_RECOVERY_BIRTH="$MUTATION_RECOVERY_BIRTH" \
    PAIR_WAL="$MUTATION_WAL_NAME" PAIR_SPEC="$MUTATION_SPEC_PATH" \
    PAIR_SPEC_ID="$MUTATION_SPEC_ID" PAIR_STATE_LEAF="$state_leaf" \
    PAIR_STATE_ROOT="$VERIFY_TMP" PAIR_STATE_ROOT_ID="$VERIFY_TMP_ID" \
    PAIR_STATE_RECORD="$STATE_SNAPSHOT_RECORD" PAIR_STATE_SOURCE_RECORD="$STATE_TMP_RECORD" \
    PAIR_STATE_BASE_RECORD="$STATE_BASE_RECORD" \
    PAIR_PRIVATE_HELPER="$PRIVATE_TMP_HELPER" \
    PAIR_STATE_READY="$state_ready" PAIR_TEST_PAUSE="${HARNESS_PIPELINE_PAIR_TEST_PAUSE:-}" \
    perl -MDigest::SHA=sha256_hex \
      -MErrno=ENOENT,EEXIST -MIO::Handle \
      -MFcntl=:DEFAULT,O_DIRECTORY,O_NOFOLLOW,S_ISDIR,S_ISLNK,S_ISREG - <<'PERL'
use strict; use warnings;
my ($mode,$rows,$audit_base_expected,$base,$base_id,$root,$root_id,$lock_id,$owner_id,$lock_nonce,$lock_pid,
    $lock_started,$lock_birth,$recovery_lock_id,$recovery_owner_id,$recovery_nonce,$recovery_pid,
    $recovery_started,$recovery_birth,$wal,$spec,$spec_id,$state_leaf,$state_ready,
    $state_root,$state_root_id,$state_record,$state_source_record,$state_base_record,$private_helper)=
  @ENV{qw(PAIR_MODE PAIR_AUDIT_ROWS PAIR_AUDIT_BASE_EXPECTED PAIR_LOCK_BASE PAIR_BASE_ID PAIR_LOCK_ROOT PAIR_ROOT_ID
    PAIR_LOCK_ID PAIR_OWNER_ID PAIR_LOCK_NONCE PAIR_LOCK_PID PAIR_LOCK_STARTED PAIR_LOCK_BIRTH
    PAIR_RECOVERY_LOCK_ID PAIR_RECOVERY_OWNER_ID PAIR_RECOVERY_NONCE PAIR_RECOVERY_PID
    PAIR_RECOVERY_STARTED PAIR_RECOVERY_BIRTH PAIR_WAL PAIR_SPEC PAIR_SPEC_ID PAIR_STATE_LEAF PAIR_STATE_READY PAIR_STATE_ROOT
    PAIR_STATE_ROOT_ID PAIR_STATE_RECORD PAIR_STATE_SOURCE_RECORD PAIR_STATE_BASE_RECORD
    PAIR_PRIVATE_HELPER)};
my $limit=16777216;
my $test_pause=$ENV{PAIR_TEST_PAUSE}//q{};
my ($root_fh,$spec_fh);
my $header="# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $legacy_header="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
sub bad { exit 1 }
sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
sub digest { return sha256_hex($_[0]) }
sub write_all { my ($fh,$raw)=@_; my $off=0; while ($off<length($raw)) {
  my $n=syswrite($fh,$raw,length($raw)-$off,$off); bad() unless defined($n) && $n; $off+=$n } }
sub sync_fh { my ($fh)=@_; $fh->sync or bad() }
sub open_dir_exact {
  my ($path,$want)=@_; sysopen(my $fh,$path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or bad();
  my @s=stat($fh); bad() unless @s && S_ISDIR($s[2]) && did(@s) eq $want; return $fh;
}
sub read_at {
  my ($dir,$name,$missing,$wal_file)=@_; chdir($dir) or bad(); my @n=lstat($name);
  if (!@n) { return { exists=>0 } if $missing && $!{ENOENT}; bad() }
  bad() if S_ISLNK($n[2]) || !S_ISREG($n[2]) || $n[3]!=1;
  bad() if $wal_file && ($n[4]!=$< || ($n[2]&0777)!=0600);
  sysopen(my $fh,$name,O_RDONLY|O_NOFOLLOW) or bad(); my @o=stat($fh);
  bad() unless @o && did(@o) eq did(@n) && $o[3]==1;
  my $raw=q{}; while (1) { my $nread=sysread($fh,my $buf,65536); bad() unless defined $nread;
    last unless $nread; $raw.=$buf; bad() if length($raw)>$limit }
  my @after=stat($fh); close $fh or bad(); my @again=lstat($name);
  bad() unless @after && @again && !S_ISLNK($again[2]) && did(@after) eq did(@o)
    && did(@again) eq did(@o) && $after[7]==length($raw);
  return { exists=>1,raw=>$raw,mode=>($o[2]&0777),hash=>digest($raw),id=>did(@o),len=>length($raw) };
}
sub write_at {
  my ($dir,$name,$raw,$mode)=@_; bad() if length($raw)>$limit || $raw=~/\x00/;
  chdir($dir) or bad(); my @old=lstat($name); bad() if @old || !$!{ENOENT};
  sysopen(my $fh,$name,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW,0600) or bad();
  write_all($fh,$raw); chmod($mode,$fh)==1 or bad(); sync_fh($fh); my @o=stat($fh);
  close $fh or bad(); my @n=lstat($name); bad() unless @o && @n && !S_ISLNK($n[2])
    && S_ISREG($n[2]) && $n[3]==1 && did(@o) eq did(@n) && ($n[2]&0777)==$mode;
}
sub audit_valid {
  my ($raw)=@_; my $prefix=index($raw,$header)==0 ? $header
    : index($raw,$legacy_header)==0 ? $legacy_header : return 0;
  my $body=substr($raw,length($prefix));
  while (length($body)) {
    return 0 unless $body=~s/\A\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| [^|\r\n]+ \| [^|\r\n]+ \|\n//;
  }
  return 1;
}
sub marker {
  my ($dir,$name)=@_; my $v=read_at($dir,$name,1,1); return 0 unless $v->{exists};
  bad() unless $v->{raw} eq q{}; return 1;
}
sub live_mark {
  my ($spec_fh,$name)=@_; my $v=read_at($spec_fh,$name,1,0);
  return $v->{exists} ? $v->{hash} : q{missing};
}
sub read_sealed_state {
  bad() unless defined($state_leaf) && $state_leaf=~/\A[a-zA-Z0-9][a-zA-Z0-9._-]{0,127}\z/
    && defined($state_root) && length($state_root) && defined($state_root_id)
    && $state_root_id=~/\A[0-9]+:[0-9]+\|[0-9]+:[0-9]+\z/
    && defined($state_record) && defined($state_source_record)
    && defined($private_helper) && length($private_helper);
  $state_record=~/\A[0-9]+:[0-9]+\|([0-9a-f]{64})\|([0-9]+)\z/ or bad();
  my ($snap_hash,$snap_len)=($1,$2);
  $state_source_record=~/\A(?:v4-current|v3|v2|legacy)\|([0-9]+:[0-9]+)\|([0-9a-f]{64})\|([0-9]+)\|(0[0-7]{3})\z/ or bad();
  my ($source_id,$source_hash,$source_len,$source_mode)=($1,$2,$3,oct($4));
  bad() unless $snap_hash eq $source_hash && $snap_len==$source_len && $source_mode==0644;
  open(my $fh,q{-|},$^X,$private_helper,q{read},$state_root,$state_root_id,
    $state_leaf,$state_record) or bad();
  my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); bad() unless defined($n);
    last unless $n; $raw.=$buf; bad() if length($raw)>$limit }
  close($fh) or bad();
  bad() unless length($raw)==$source_len && digest($raw) eq $source_hash;
  system($^X,$private_helper,q{cleanup},$state_root,$state_root_id)==0 or bad();
  return { exists=>1,raw=>$raw,mode=>$source_mode,hash=>$source_hash,id=>q{sealed},len=>$source_len };
}
sub parse_manifest {
  my ($raw)=@_; my @line=split /\n/,$raw,-1; bad() unless pop(@line) eq q{};
  my @key=qw(version spec_id lock_id owner_id lock_nonce lock_pid lock_started lock_birth
    state_old state_new audit_old audit_new
    state_old_mode audit_old_mode state_mode audit_mode);
  bad() unless @line==@key; my %m;
  for my $i (0..$#key) { $line[$i]=~/\A\Q$key[$i]\E=(.*)\z/ or bad(); $m{$key[$i]}=$1 }
  bad() unless $m{version} eq q{3} && $m{spec_id}=~/\A[0-9]+:[0-9]+\z/
    && $m{lock_id}=~/\A[0-9]+:[0-9]+\z/ && $m{owner_id}=~/\A[0-9]+:[0-9]+\z/
    && $m{lock_nonce}=~/\A[0-9a-f]{64}\z/ && $m{lock_pid}=~/\A[1-9][0-9]*\z/
    && $m{lock_started}=~/\A[1-9][0-9]*\z/
    && $m{lock_birth}=~/\A(?:[0-9a-f]{64}|unavailable)\z/;
  for my $k (qw(state_old audit_old)) { bad() unless $m{$k} eq q{missing} || $m{$k}=~/\A[0-9a-f]{64}\z/ }
  for my $k (qw(state_new audit_new)) { bad() unless $m{$k}=~/\A[0-9a-f]{64}\z/ }
  for my $k (qw(state_mode audit_mode)) { bad() unless $m{$k}=~/\A0[0-7]{3}\z/ }
  for my $k (qw(state_old_mode audit_old_mode)) {
    bad() unless $m{$k} eq q{missing} || $m{$k}=~/\A0[0-7]{3}\z/;
  }
  bad() unless (($m{state_old} eq q{missing}) == ($m{state_old_mode} eq q{missing}))
    && (($m{audit_old} eq q{missing}) == ($m{audit_old_mode} eq q{missing}));
  return \%m;
}
sub wal_open {
  chdir($root_fh) or bad(); my @n=lstat($wal); return undef if !@n && $!{ENOENT};
  bad() unless @n && !S_ISLNK($n[2]) && S_ISDIR($n[2]) && $n[4]==$< && ($n[2]&0777)==0700;
  sysopen(my $fh,$wal,O_RDONLY|O_DIRECTORY|O_NOFOLLOW) or bad(); my @o=stat($fh);
  bad() unless @o && did(@o) eq did(@n); return $fh;
}
sub wal_remove {
  my ($wf)=@_; chdir($wf) or bad(); opendir(my $dh,q{.}) or bad();
  my @entry=grep { $_ ne q{.} && $_ ne q{..} } readdir($dh); closedir($dh) or bad();
  my %ok=map {$_=>1} qw(state.old audit.old state.next audit.next manifest PREPARED COMMIT);
  bad() if grep {!$ok{$_}} @entry;
  for my $name (@entry) { my $v=read_at($wf,$name,0,1); chdir($wf) or bad(); unlink($name) or bad() }
  chdir($root_fh) or bad(); rmdir($wal) or bad(); sync_fh($root_fh);
}
sub install_target {
  my ($name,$payload,$mode,$old_hash,$new_hash)=@_;
  my $current=live_mark($spec_fh,$name); return if $current eq $new_hash;
  bad() unless $current eq $old_hash;
  (my $tag=$wal)=~s/\.txn\z//; my $tmp=q{.}.$name.q{.}.$tag.q{.next};
  my $existing=read_at($spec_fh,$tmp,1,0);
  if ($existing->{exists}) { bad() unless $existing->{hash} eq $new_hash && $existing->{mode}==$mode }
  else { write_at($spec_fh,$tmp,$payload,$mode) }
  chdir($spec_fh) or bad(); rename($tmp,$name) or bad(); sync_fh($spec_fh);
  bad() unless live_mark($spec_fh,$name) eq $new_hash;
}
sub restore_old_state {
  my ($old,$old_hash,$old_mode,$new_hash)=@_;
  bad() unless live_mark($spec_fh,q{state.md}) eq $new_hash;
  if ($old_hash eq q{missing}) {
    my $v=read_at($spec_fh,q{state.md},0,0); bad() unless $v->{hash} eq $new_hash;
    chdir($spec_fh) or bad(); my @n=lstat(q{state.md}); bad() unless @n && did(@n) eq $v->{id};
    unlink(q{state.md}) or bad(); sync_fh($spec_fh);
    bad() unless live_mark($spec_fh,q{state.md}) eq q{missing}; return;
  }
  bad() unless defined($old) && $old->{exists} && $old->{hash} eq $old_hash
    && defined($old_mode) && $old_mode=~/\A0[0-7]{3}\z/;
  (my $tag=$wal)=~s/\.txn\z//; my $tmp=q{.state.md.}.$tag.q{.rollback};
  my $existing=read_at($spec_fh,$tmp,1,0);
  if ($existing->{exists}) { bad() unless $existing->{hash} eq $old_hash && $existing->{mode}==oct($old_mode) }
  else { write_at($spec_fh,$tmp,$old->{raw},oct($old_mode)) }
  bad() unless live_mark($spec_fh,q{state.md}) eq $new_hash;
  chdir($spec_fh) or bad(); rename($tmp,q{state.md}) or bad(); sync_fh($spec_fh);
  bad() unless live_mark($spec_fh,q{state.md}) eq $old_hash;
}
bad() unless defined($mode) && ($mode eq q{recover} || $mode eq q{commit});
bad() unless defined($state_ready) && ($state_ready eq q{0} || $state_ready eq q{1});
bad() unless defined($audit_base_expected)
  && ($audit_base_expected eq q{} || $audit_base_expected=~/\A[0-9a-f]{64}\z/);
bad() unless defined($wal) && $wal=~/\A[0-9a-f]{64}\.txn\z/;
my $base_fh=open_dir_exact($base,$base_id); chdir($base_fh) or bad();
my @rn=lstat($root); bad() unless @rn && !S_ISLNK($rn[2]) && S_ISDIR($rn[2]) && did(@rn) eq $root_id;
$root_fh=open_dir_exact($root,$root_id);
$spec_fh=open_dir_exact($spec,$spec_id);

if (my $wf=wal_open()) {
  my $prepared=marker($wf,q{PREPARED}); my $committed=marker($wf,q{COMMIT});
  if (!$prepared) { bad() if $committed; wal_remove($wf) }
  else {
    my $manifest=read_at($wf,q{manifest},0,1); my $state_next=read_at($wf,q{state.next},0,1);
    my $audit_next=read_at($wf,q{audit.next},0,1); my $m=parse_manifest($manifest->{raw});
    my $state_old=read_at($wf,q{state.old},1,1); my $audit_old=read_at($wf,q{audit.old},1,1);
    bad() unless $m->{spec_id} eq $spec_id && $state_next->{hash} eq $m->{state_new}
      && $audit_next->{hash} eq $m->{audit_new};
    bad() unless ($m->{state_old} eq q{missing} ? !$state_old->{exists}
        : $state_old->{exists} && $state_old->{hash} eq $m->{state_old})
      && ($m->{audit_old} eq q{missing} ? !$audit_old->{exists}
        : $audit_old->{exists} && $audit_old->{hash} eq $m->{audit_old});
    bad() unless audit_valid($audit_next->{raw});
    bad() unless !$audit_old->{exists} || audit_valid($audit_old->{raw});
    my $audit_base=$audit_old->{exists} ? $audit_old->{raw} : $header;
    bad() unless length($audit_next->{raw})>length($audit_base)
      && substr($audit_next->{raw},0,length($audit_base)) eq $audit_base;
    my $ls=live_mark($spec_fh,q{state.md}); my $la=live_mark($spec_fh,q{audit.md});
    bad() unless ($ls eq $m->{state_old} || $ls eq $m->{state_new})
      && ($la eq $m->{audit_old} || $la eq $m->{audit_new});
    if (!$committed) { bad() unless $ls eq $m->{state_old} && $la eq $m->{audit_old}; wal_remove($wf) }
    else {
      if ($ls eq $m->{state_old} && $la eq $m->{audit_old}) {
        # COMMIT without any applied live byte is safely retryable and grants nothing. Removing it
        # prevents a pre-created deterministic WAL (even with a fabricated stale lock) from minting
        # state/audit authority solely from files under the private lock root.
        wal_remove($wf);
      } elsif ($ls eq $m->{state_new} && $la eq $m->{audit_old}) {
        my $manifest_lineage=join(q{|},@{$m}{qw(lock_id owner_id lock_nonce lock_pid lock_started lock_birth)});
        my $current_lineage=join(q{|},$lock_id,$owner_id,$lock_nonce,$lock_pid,$lock_started,$lock_birth);
        my $recovery_lineage=defined($recovery_lock_id) && length($recovery_lock_id)
          ? join(q{|},$recovery_lock_id,$recovery_owner_id,$recovery_nonce,$recovery_pid,
              $recovery_started,$recovery_birth) : q{};
        bad() unless $manifest_lineage eq $current_lineage
          || (length($recovery_lineage) && $manifest_lineage eq $recovery_lineage);
        # State is mutable; audit is append-only. If audit was not installed, restore exact old
        # state and let the caller retry. We never delete an already visible audit row.
        restore_old_state($state_old,$m->{state_old},$m->{state_old_mode},$m->{state_new});
        bad() unless live_mark($spec_fh,q{audit.md}) eq $m->{audit_old};
        wal_remove($wf);
      } elsif ($ls eq $m->{state_new} && $la eq $m->{audit_new}) {
        my $manifest_lineage=join(q{|},@{$m}{qw(lock_id owner_id lock_nonce lock_pid lock_started lock_birth)});
        my $current_lineage=join(q{|},$lock_id,$owner_id,$lock_nonce,$lock_pid,$lock_started,$lock_birth);
        my $recovery_lineage=defined($recovery_lock_id) && length($recovery_lock_id)
          ? join(q{|},$recovery_lock_id,$recovery_owner_id,$recovery_nonce,$recovery_pid,
              $recovery_started,$recovery_birth) : q{};
        bad() unless $manifest_lineage eq $current_lineage
          || (length($recovery_lineage) && $manifest_lineage eq $recovery_lineage);
        wal_remove($wf);
      } else {
        # audit-new/state-old is impossible for this writer order. Preserve both audit evidence and
        # WAL; never promote the attacker/crash bytes into state authority.
        bad();
      }
    }
  }
}
exit 0 if $mode eq q{recover};
bad() unless defined($rows) && length($rows) && audit_valid($header.$rows);
my $old_state=read_at($spec_fh,q{state.md},1,0); my $old_audit=read_at($spec_fh,q{audit.md},1,0);
bad() if length($audit_base_expected)
  && (!$old_audit->{exists} || $old_audit->{hash} ne $audit_base_expected);
my $state_new;
if ($state_ready eq q{1}) {
  bad() unless defined($state_base_record);
  if ($state_base_record eq q{missing}) { bad() if $old_state->{exists} }
  else {
    $state_base_record=~/\A(?:v4-current|v3|v2|legacy)\|([0-9]+:[0-9]+)\|([0-9a-f]{64})\|([0-9]+)\|(0[0-7]{3})\z/ or bad();
    bad() unless $old_state->{exists} && $old_state->{id} eq $1 && $old_state->{hash} eq $2
      && $old_state->{len}==$3 && $old_state->{mode}==oct($4);
  }
  $state_new=read_sealed_state();
} else { bad() unless $old_state->{exists}; $state_new=$old_state }
my $audit_base=$old_audit->{exists} ? $old_audit->{raw} : $header;
bad() unless audit_valid($audit_base); my $audit_new=$audit_base.$rows; bad() unless audit_valid($audit_new);
bad() if $state_new->{raw}=~/\x00/ || $audit_new=~/\x00/ || length($audit_new)>$limit;
my $state_old_hash=$old_state->{exists} ? $old_state->{hash} : q{missing};
my $audit_old_hash=$old_audit->{exists} ? $old_audit->{hash} : q{missing};
my $state_mode=sprintf(q{%04o},$state_new->{mode});
my $audit_mode=sprintf(q{%04o},$old_audit->{exists} ? $old_audit->{mode} : 0644);
my $state_old_mode=$old_state->{exists} ? sprintf(q{%04o},$old_state->{mode}) : q{missing};
my $audit_old_mode=$old_audit->{exists} ? sprintf(q{%04o},$old_audit->{mode}) : q{missing};
my $manifest=join(q{},
  "version=3\n","spec_id=$spec_id\n","lock_id=$lock_id\n","owner_id=$owner_id\n",
  "lock_nonce=$lock_nonce\n","lock_pid=$lock_pid\n","lock_started=$lock_started\n",
  "lock_birth=$lock_birth\n","state_old=$state_old_hash\n",
  "state_new=$state_new->{hash}\n","audit_old=$audit_old_hash\n",
  "audit_new=".digest($audit_new)."\n","state_old_mode=$state_old_mode\n",
  "audit_old_mode=$audit_old_mode\n","state_mode=$state_mode\n","audit_mode=$audit_mode\n");
chdir($root_fh) or bad(); mkdir($wal,0700) or bad(); my $wf=wal_open(); bad() unless $wf;
write_at($wf,q{state.old},$old_state->{raw},0600) if $old_state->{exists};
write_at($wf,q{audit.old},$old_audit->{raw},0600) if $old_audit->{exists};
write_at($wf,q{state.next},$state_new->{raw},0600);
write_at($wf,q{audit.next},$audit_new,0600);
write_at($wf,q{manifest},$manifest,0600);
write_at($wf,q{PREPARED},q{},0600); sync_fh($wf);
write_at($wf,q{COMMIT},q{},0600); sync_fh($wf); sync_fh($root_fh);
install_target(q{state.md},$state_new->{raw},oct($state_mode),$state_old_hash,$state_new->{hash});
if ($test_pause eq q{after-state}) {
  open(my $gate,q{>&=9}) or bad(); my $msg=q{pid=}.$$ . "\n";
  syswrite($gate,$msg,length($msg))==length($msg) or bad(); close $gate or bad();
  kill(q{STOP},$$)==1 or bad();
} elsif (length($test_pause)) { bad() }
install_target(q{audit.md},$audit_new,oct($audit_mode),$audit_old_hash,digest($audit_new));
bad() unless live_mark($spec_fh,q{audit.md}) eq digest($audit_new)
  && live_mark($spec_fh,q{state.md}) eq $state_new->{hash};
wal_remove($wf);
PERL
}

pair_tx_recover() {
  pair_tx_engine recover "" 0 || die "$CMD: pair-WAL recovery не подтверждён"
}

pair_tx_commit() {
  local leaf=""
  [ -n "$AUDIT_ROWS" ] || die "$CMD: state/audit transaction без audit rows"
  if [ "$STATE_TX_READY" -eq 1 ]; then
    [ -n "$STATE_TMP_RECORD" ] && [ -n "$STATE_SNAPSHOT_LEAF" ] \
      && [ -n "$STATE_SNAPSHOT_RECORD" ] \
      || die "$CMD: prepared state snapshot authority отсутствует"
    leaf="$STATE_SNAPSHOT_LEAF"
  fi
  if ! pair_tx_engine commit "$leaf" "$STATE_TX_READY"; then
    # Preserve the exact owner lock as the recovery lineage for any durable WAL. The process exits
    # immediately; the next command reclaims the now-dead owner and accepts only its bound manifest.
    PRESERVE_MUTATION_LOCK=1
    die "$CMD: state/audit pair commit не подтверждён; WAL/lock lineage сохранены для reconcile"
  fi
  if [ "$STATE_TX_READY" -eq 1 ]; then
    # pair engine consumed the private snapshot and removed its exact root before PREPARED/COMMIT.
    VERIFY_TMP=""; VERIFY_TMP_ID=""
    # Commit-metadata leaves shared that root. Their records must not survive root consumption:
    # later post-commit guards rematerialize the immutable blobs into a fresh private root.
    unset SNAP_candidate_h_state SNAP_candidate_h_audit SNAP_candidate_h_source SNAP_candidate_h_commit \
      SNAP_candidate_c_state SNAP_candidate_c_audit SNAP_candidate_c_source SNAP_candidate_c_commit \
      SNAP_h_state SNAP_h_audit SNAP_h_source SNAP_h_commit \
      SNAP_b_state SNAP_b_audit SNAP_b_source SNAP_b_commit 2>/dev/null || true
  fi
  STATE_TMP=""; STATE_TMP_ID=""; STATE_TMP_RECORD=""; STATE_BASE_RECORD=""
  STATE_SNAPSHOT_LEAF=""; STATE_SNAPSHOT_RECORD=""
  STATE_TX_READY=0; AUDIT_ROWS=""; AUDIT_BASE_EXPECTED=""
}

mark_stage() { # $1 stage, $2 символ, $3 file
  [ "$3" = "$STATE_TMP" ] || die "mark_stage: non-transaction target"
  state_temp_transform mark-stage "$1" "$2"
}
set_gate() { # $1 ключ, $2 значение, $3 file
  # VAL санитизируется ЗДЕСЬ — единая точка защиты для gate/approve/verdict
  [ "$3" = "$STATE_TMP" ] || die "set_gate: non-transaction target"
  state_temp_transform set-gate "$1" "$(sanitize "$2")"
}
set_conf() { # $1 stage, $2 value, $3 file
  local f="$3"
  [ "$f" = "$STATE_TMP" ] || die "set_conf: non-transaction target"
  # секция ## Confidence отсутствует (legacy state.md без confidence) → вставить 4 строки «—»
  # СТРОГО после Gates-блока (анкер quality-verdict), НИКОГДА append-EOF: units-set awk срезает
  # всё после '## Units' до EOF и уничтожил бы секцию в конце файла.
  state_temp_transform set-conf "$1" "$2"
}
conf_nonblocking() { # $1 stage, $2 file
  # return 1 если yellow|red БЕЗ ack-суффикса (fail-safe: сомнение стопит до ack владельца).
  # Структурный анкер ' · ack:' (не подстрока где угодно) — причина не может подделать ack.
  local line
  line="$(grep -E "^- confidence-$1: " "$2" 2>/dev/null | head -1 || true)"
  case "$line" in
    ""|*": —"*) return 0 ;;               # нет строки или не задекларирован — legacy-нейтраль
  esac
  printf '%s' "$line" | grep -qE "^- confidence-$1: green\b" && return 0
  if printf '%s' "$line" | grep -qE "^- confidence-$1: (yellow|red)\b"; then
    printf '%s' "$line" | grep -qE ' · ack: ' && return 0   # acked владельцем
    return 1                                                 # non-green без ack → BLOCKED
  fi
  return 0
}
upd_ts() {
  [ "$1" = "$STATE_TMP" ] || die "upd_ts: non-transaction target"
  state_temp_transform upd-ts "$TS"
}

stage_status() { # $1 file, $2 stage; shape must already be valid
  local line stage="$2"
  while IFS= read -r line || [ -n "$line" ]; do
    if [ "$line" = "- [ ] $stage" ]; then printf ' '; return 0; fi
    if [ "$line" = "- [-] $stage" ]; then printf '-'; return 0; fi
    if [ "$line" = "- [x] $stage" ]; then printf 'x'; return 0; fi
  done < "$1"
  return 1
}
scope_value() {
  local v
  v="$(sed -n 's/^- Scope: //p' "$1" | head -1)"
  [ -n "$v" ] || v=feature   # frozen pre-version writer had no Scope: explicit legacy default
  printf '%s' "$v"
}
has_units() { grep -q '^## Units$' "$1"; }
units_complete() {
  local f="$1" raw scope
  raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$f" 2>/dev/null)" || return 1
  case "$raw" in *$'\036') raw="${raw%$'\036'}";; *) return 1;; esac
  scope="$(scope_value <(printf '%s' "$raw"))"
  if ! has_units <(printf '%s' "$raw"); then [ "$scope" != enterprise ]; return; fi
  ! grep -qE '^- \[[ -]\] unit:' <(printf '%s' "$raw")
}
gate_ready_strict() {
  LC_ALL=C grep -Eq '^- constitution-gate: MUST-FLAG: 0 · SHOULD-FLAG: [0-9]+ · NEEDS-INFO: 0 \([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\)$' "$1"
}
gate_ready_legacy_publish() {
  LC_ALL=C grep -Eq '^- constitution-gate: MUST-FLAG: 0 · SHOULD-FLAG: [0-9]+ · NEEDS-INFO: [0-9]+' "$1"
}
approval_ready() { # V4 approval is authority only while it binds the exact current Design-Root
  local f="$1" design raw
  # Callers also pass /dev/stdin and process-substitution FDs.  Those streams are not rewindable:
  # read once, then run every predicate against the same bounded bytes.
  raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$f" 2>/dev/null)" || return 1
  case "$raw" in *$'\036') raw="${raw%$'\036'}";; *) return 1;; esac
  design="$(printf '%s' "$raw" | sed -n 's/^- Design-Root: //p' | head -1)"
  printf '%s' "$design" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | LC_ALL=C grep -Eq "^- user-approval: approved design=$design \\([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z, .+\\)$"
}
verdict_pass_strict() { LC_ALL=C grep -Eq '^- quality-verdict: PASS — [^[:space:]].* \([0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\)$' "$1"; }
verdict_pass_legacy() { grep -Eq '^- quality-verdict: PASS( — .+)? \(' "$1"; }
require_running() {
  [ "$(stage_status "$STATE" "$1")" = "-" ] || die "$CMD: $1 должна быть в состоянии [-]"
}
stages_from() {
  case "$1" in
    stage-1-creative) echo "$STAGES" ;;
    stage-2-audit) echo "stage-2-audit stage-3-dev stage-4-quality" ;;
    stage-3-dev) echo "stage-3-dev stage-4-quality" ;;
    stage-4-quality) echo "stage-4-quality" ;;
  esac
}
reset_conf_if_present() {
  if grep -q '^## Confidence$' "$1"; then set_conf "$2" "—" "$1"; fi
}
set_quality_head() { # $1 value, $2 file; V3/V4 anchor is already present
  [ "$2" = "$STATE_TMP" ] || die "set_quality_head: non-transaction target"
  state_temp_transform set-quality "$1"
}
set_root() { # $1 Design-Root|Implementation-Root|Evidence-Root, $2 value, $3 file
  [ "$3" = "$STATE_TMP" ] || die "set_root: non-transaction target"
  state_temp_transform set-root "$1" "$2"
}
reset_quality_head_if_present() {
  if grep -q '^- Quality-HEAD:' "$1"; then set_quality_head "—" "$1"; fi
}
reset_units() {
  [ "$1" = "$STATE_TMP" ] || die "reset_units: non-transaction target"
  state_temp_transform reset-units
}
invalidate_from() { # $1 file, $2 current stage
  local f="$1" s="$2" x
  for x in $(stages_from "$s"); do mark_stage "$x" " " "$f"; reset_conf_if_present "$f" "$x"; done
  reset_quality_head_if_present "$f"
  case "$s" in
    stage-1-creative|stage-2-audit)
      set_root Design-Root "—" "$f"; set_root Implementation-Root "—" "$f"; set_root Evidence-Root "—" "$f"
      set_gate constitution-gate "—" "$f"; set_gate user-approval "—" "$f"; set_gate quality-verdict "—" "$f"; reset_units "$f" ;;
    stage-3-dev)
      set_root Implementation-Root "—" "$f"; set_root Evidence-Root "—" "$f"
      set_gate quality-verdict "—" "$f"; reset_units "$f" ;;
    stage-4-quality)
      set_root Evidence-Root "—" "$f"
      set_gate quality-verdict "—" "$f" ;;
  esac
}
normalize_units() { # stdout canonical CSV; invalid → exit 2
  local list="$1" oldifs raw name seen="|" out=""
  case "$list" in ''|,*|*,|*,,*) die "units-set: список должен быть непустым, без пустых элементов";; esac
  set -f   # пользовательский `*` не должен раскрыться в файлы cwd до grammar-check
  oldifs="$IFS"; IFS=','; set -- $list; IFS="$oldifs"
  for raw in "$@"; do
    name="$(printf '%s' "$raw" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    printf '%s' "$name" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' \
      || die "units-set: невалидное имя unit (ожидаю [A-Za-z0-9][A-Za-z0-9._-]{0,63})"
    case "$seen" in *"|$name|"*) die "units-set: duplicate unit";; esac
    seen="$seen$name|"; out="${out:+$out,}$name"
  done
  set +f
  [ -n "$out" ] || die "units-set: список не содержит unit"
  printf '%s' "$out"
}
unit_status() { # $1 file, $2 exact unit name
  local c
  for c in " " "-" "x"; do grep -Fqx -- "- [$c] unit:$2" "$1" && { printf '%s' "$c"; return 0; }; done
  return 1
}

# --- architecture-evidence-v1: causal review receipts and Design-Root -----------------------
architecture_candidate_root() {
  local out
  [ -r "$ARCH_VERIFY" ] || die "$CMD: architecture verifier недоступен"
  out="$(perl "$ARCH_VERIFY" candidate "$GIT_ROOT" "$SPEC_REL")" || return $?
  printf '%s' "$out" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
    || die "$CMD: architecture candidate output malformed"
  printf '%s' "$out"
}

architecture_verify_record() { # [unbound]; stdout root|attempt|generation|actor|review-sha256|audit-sha256
  local out verify_cmd=verify-bound
  [ "${1:-}" != unbound ] || verify_cmd=verify
  [ -r "$ARCH_VERIFY" ] || die "$CMD: architecture verifier недоступен"
  out="$(perl "$ARCH_VERIFY" "$verify_cmd" "$GIT_ROOT" "$SPEC_REL")" || return $?
  printf '%s\n' "$out" | perl -e '
    use strict; use warnings; local $/; my $v=<STDIN>//q{};
    $v =~ /\ADesign-Root: ([0-9a-f]{64})\nReview-Attempt: ([0-9a-f]{64})\nReview-Generation: (0|[1-9][0-9]*)\nReview-Actor: ([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\nReview-SHA256: ([0-9a-f]{64})\nAudit-SHA256: ([0-9a-f]{64})\n\z/
      or exit 2;
    exit 2 if length($3)>10 || $3>2147483647;
    print join(q{|},$1,$2,$3,$4,$5,$6);
  ' || die "$CMD: architecture verify output malformed"
}

design_authority_current() {
  local record oldifs root attempt generation actor review_sha audit_sha state_root
  [ -n "$GIT_ROOT" ] && [ -n "$SPEC_REL" ] || return 1
  record="$(architecture_verify_record)" || return $?
  oldifs="$IFS"; IFS='|'; set -- $record; IFS="$oldifs"
  [ "$#" -eq 6 ] || return 2
  root="$1"; attempt="$2"; generation="$3"; actor="$4"; review_sha="$5"; audit_sha="$6"
  state_root="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
  [ "$state_root" = "$root" ] || return 1
  printf '%s' "$audit_sha" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'
}

implementation_lifecycle_selector() { # <start|bound>; current retained lifecycle tuple
  local mode="$1"
  MODE="$mode" perl - "$AUDIT" <<'PERL'
use strict; use warnings; use utf8;
use Encode qw(decode encode FB_CROAK LEAVE_SRC);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG S_ISLNK);
sub did { my (@s)=@_; return $s[0].q{:}.$s[1] }
my $path=shift; my @named=lstat($path); exit 2 unless @named && !S_ISLNK($named[2])
  && S_ISREG($named[2]) && $named[3]==1 && ($named[2]&07777)==0644;
sysopen(my $fh,$path,O_RDONLY|O_NOFOLLOW) or exit 2; my @opened=stat($fh);
exit 2 unless @opened && did(@opened) eq did(@named);
my $raw=q{}; while (1) { my $n=sysread($fh,my $buf,65536); exit 2 unless defined($n);
  last unless $n; $raw.=$buf; exit 2 if length($raw)>16777216 }
my $text; eval { $text=decode(q{UTF-8},$raw,FB_CROAK|LEAVE_SRC); 1 } or exit 2;
my $modern=encode(q{UTF-8},
  "# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n");
my $legacy="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $header=index($raw,$modern)==0 ? $modern : index($raw,$legacy)==0 ? $legacy : exit 2;
my $body=substr($raw,length($header)); my @row;
while (length($body)) {
  $body=~s/\A\| \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
    or exit 2; push @row,[$1,$2];
}
my ($generation,$active,$bound)=(0,undef,undef); my %used;
for my $row (@row) {
  my ($event,$detail)=@$row;
  if ($event eq q{receipt-invalidate}) {
    $detail=~/\Ageneration=(0|[1-9][0-9]*);scopes=(architecture,implementation,quality,evidence|implementation,quality,evidence|quality,evidence)\z/
      or exit 2; my ($next,$scope)=($1,$2);
    exit 2 if length($next)>10 || $next>2147483647 || $next!=$generation+1;
    $generation=$next;
    if (grep { $_ eq q{implementation} } split /,/, $scope) { $active=undef; $bound=undef }
    next;
  }
  if ($event eq q{implementation-start}) {
    $detail=~/\Aattempt=([0-9a-f]{64});generation=(0|[1-9][0-9]*);actor=([A-Za-z0-9][A-Za-z0-9._:-]{0,127});subject=([0-9a-f]{64});capability=implementation-v1;base=([0-9a-f]{40}|[0-9a-f]{64})\z/
      or exit 2;
    my %v=(attempt=>$1,generation=>$2,actor=>$3,design=>$4,base=>$5);
    exit 2 if length($v{generation})>10 || $v{generation}>2147483647
      || $v{generation}!=$generation || $used{$v{attempt}}++ || defined($active);
    $active=\%v; $bound=undef; next;
  }
  if ($event eq q{implementation-bind}) {
    $detail=~/\Aroot=([0-9a-f]{64});base=([0-9a-f]{40}|[0-9a-f]{64});design=([0-9a-f]{64});attempt=([0-9a-f]{64});generation=(0|[1-9][0-9]*);actor=([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\z/
      or exit 2;
    my %v=(root=>$1,base=>$2,design=>$3,attempt=>$4,generation=>$5,actor=>$6);
    exit 2 unless defined($active) && !defined($bound);
    for my $key (qw(base design attempt generation actor)) { exit 2 unless $v{$key} eq $active->{$key} }
    $bound=\%v; next;
  }
  exit 2 if $event=~/implementation-(?:start|bind)/ || $detail=~/implementation-(?:start|bind)/;
}
my $mode=$ENV{MODE}//q{};
if ($mode eq q{start}) {
  exit 1 unless defined($active);
  print join(q{|},@{$active}{qw(attempt generation actor design base)});
} elsif ($mode eq q{bound}) {
  exit 1 unless defined($bound);
  print join(q{|},@{$bound}{qw(root base design attempt generation actor)});
} else { exit 2 }
my @after=stat($fh); my @again=lstat($path); close($fh) or exit 2;
exit 2 unless @after && @again && !S_ISLNK($again[2])
  && did(@after) eq did(@opened) && did(@again) eq did(@opened) && $after[7]==length($raw);
PERL
}

implementation_verify_record() { # <base> <design> <attempt>; canonical 7-field tuple
  local base="$1" design="$2" attempt="$3" out
  [ -r "$IMPLEMENTATION_VERIFY" ] || die "$CMD: implementation verifier недоступен"
  mint_internal_git_context
  out="$(perl "$IMPLEMENTATION_VERIFY" verify "$GIT_ROOT" "$SPEC_REL" \
    "$base" "$design" "$attempt")" || return $?
  printf '%s\n' "$out" | perl -e '
    use strict; use warnings; local $/; my $v=<STDIN>//q{};
    $v=~/\AImplementation-Root: ([0-9a-f]{64})\nBase: ([0-9a-f]{40}|[0-9a-f]{64})\nDesign-Root: ([0-9a-f]{64})\nImplementation-Attempt: ([0-9a-f]{64})\nImplementation-Generation: (0|[1-9][0-9]*)\nImplementation-Actor: ([A-Za-z0-9][A-Za-z0-9._:-]{0,127})\nAudit-SHA256: ([0-9a-f]{64})\n\z/ or exit 2;
    exit 2 if length($5)>10 || $5>2147483647;
    print join(q{|},$1,$2,$3,$4,$5,$6,$7);
  ' || die "$CMD: implementation verify output malformed"
}

implementation_authority_current() {
  local selector record oldifs root base design attempt generation actor audit_sha state_root state_design
  selector="$(implementation_lifecycle_selector bound)" || return $?
  oldifs="$IFS"; IFS='|'; set -- $selector; IFS="$oldifs"
  [ "$#" -eq 6 ] || return 2
  root="$1"; base="$2"; design="$3"; attempt="$4"; generation="$5"; actor="$6"
  state_root="$(sed -n 's/^- Implementation-Root: //p' "$STATE" | head -1)"
  state_design="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
  [ "$state_root" = "$root" ] && [ "$state_design" = "$design" ] || return 1
  record="$(implementation_verify_record "$base" "$design" "$attempt")" || return $?
  oldifs="$IFS"; IFS='|'; set -- $record; IFS="$oldifs"
  [ "$#" -eq 7 ] || return 2
  [ "$1|$2|$3|$4|$5|$6" = "$root|$base|$design|$attempt|$generation|$actor" ] || return 1
  audit_sha="$7"; printf '%s' "$audit_sha" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'
}

implementation_authority_frozen() { # post-C: cheap retained identity preflight; Evidence verifier proves TDD
  local selector oldifs root base design attempt generation actor state_root state_design
  selector="$(implementation_lifecycle_selector bound)" || return $?
  oldifs="$IFS"; IFS='|'; set -- $selector; IFS="$oldifs"
  [ "$#" -eq 6 ] || return 2
  root="$1"; base="$2"; design="$3"; attempt="$4"; generation="$5"; actor="$6"
  state_root="$(sed -n 's/^- Implementation-Root: //p' "$STATE" | head -1)"
  state_design="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
  [ "$state_root" = "$root" ] && [ "$state_design" = "$design" ] || return 1
  # Both callers immediately enter the exact-C Evidence verifier, which recomputes retained roots
  # and replays this same trusted receipt helper from the immutable checkpoint.  Since Evidence
  # does that even for an all-non-behavioral delivery, repeating the live helper here adds no
  # predicate; this preflight keeps the precise lifecycle/state diagnostic before the full proof.
  return 0
}

receipt_detail_validate() { # <start|finish|blocked> <role> <attempt> <expected-1> <expected-2> <detail>
  perl - "$@" <<'PERL'
use strict; use warnings;
my ($kind,$role,$attempt,$expected1,$expected2,$detail)=@ARGV;
my %capability=(
  architecture => 'architecture-review-v1',
  'critical-code' => 'critical-code-review-v1',
  performance => 'performance-review-v1',
);
exit 1 unless defined($capability{$role}) && $attempt=~/\A[0-9a-f]{64}\z/;
my $uint=qr/(?:0|[1-9][0-9]*)/;
my $actor=qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
my $subject=qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/;
my ($got_attempt,$generation,$got_actor,$got_subject,$capability,$terminal);
if ($kind eq q{start}) {
  ($got_attempt,$generation,$got_actor,$got_subject,$capability)=
    ($detail=~/\Aattempt=([0-9a-f]{64});generation=($uint);actor=($actor);subject=($subject);capability=($actor)\z/);
  exit 1 unless defined($capability) && $got_actor eq $expected1 && $got_subject eq $expected2;
} elsif ($kind eq q{blocked}) {
  ($got_attempt,$generation,$got_actor,$got_subject,$capability,$terminal)=
    ($detail=~/\Aattempt=([0-9a-f]{64});generation=($uint);actor=($actor);subject=($subject);capability=($actor);reason=(unavailable|lost|invalid-output)\z/);
  exit 1 unless defined($terminal) && $terminal eq $expected1;
} elsif ($kind eq q{finish}) {
  ($got_attempt,$generation,$got_actor,$got_subject,$capability,$terminal)=
    ($detail=~/\Aattempt=([0-9a-f]{64});generation=($uint);actor=($actor);subject=($subject);capability=($actor);artifact=([^;|\r\n]+);sha256=[0-9a-f]{64}\z/);
  exit 1 unless defined($terminal) && $terminal eq $expected1;
} else { exit 1 }
exit 1 unless $got_attempt eq $attempt && $capability eq $capability{$role}
  && length($generation)<=10 && $generation<=2147483647;
exit 0;
PERL
}

# --- immutable quality boundary and per-worktree publish authority -------------------------
valid_full_oid() {
  printf '%s' "$1" | LC_ALL=C grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

canonical_spec_rel() {
  LC_ALL=C perl -e 'exit(($ARGV[0] // q{}) =~ /\Aspecs\/[0-9]{3}-[a-z0-9][a-z0-9-]*\z/ ? 0 : 1)' "$1"
}

pipeline_physical_dir_from() {
  local base="$1" path="$2"
  case "$path" in
    /*) (cd "$path" 2>/dev/null && pwd -P) ;;
    *)  (cd "$base/$path" 2>/dev/null && pwd -P) ;;
  esac
}

validate_localized_git_context() { # $1 registered root, $2 local gitdir; safe local-ahead only
  local root="$1" local_dir="$2" top rc registered_common local_common
  local root_phys top_phys registered_common_phys local_common_phys registered_head local_head
  [ -d "$local_dir" ] && [ ! -L "$local_dir" ] \
    && [ -f "$local_dir/HEAD" ] && [ ! -L "$local_dir/HEAD" ] \
    || die "$CMD: localized gitdir malformed"
  top="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --show-toplevel 2>/dev/null
  )" || die "$CMD: localized gitdir не определяет worktree"
  registered_common="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git rev-parse --git-common-dir 2>/dev/null
  )" || die "$CMD: registered common repository недоступен"
  local_common="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --git-common-dir 2>/dev/null
  )" || die "$CMD: localized common repository недоступен"
  root_phys="$(cd "$root" 2>/dev/null && pwd -P)" || die "$CMD: registered worktree недоступен"
  top_phys="$(cd "$top" 2>/dev/null && pwd -P)" || die "$CMD: localized worktree недоступен"
  registered_common_phys="$(pipeline_physical_dir_from "$root" "$registered_common")" \
    || die "$CMD: registered common repository path invalid"
  local_common_phys="$(pipeline_physical_dir_from "$root" "$local_common")" \
    || die "$CMD: localized common repository path invalid"
  [ "$root_phys" = "$top_phys" ] && [ "$registered_common_phys" = "$local_common_phys" ] \
    || die "$CMD: localized gitdir не принадлежит registered worktree repository"
  registered_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || die "$CMD: registered HEAD не commit"
  local_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || die "$CMD: localized HEAD не commit"
  valid_full_oid "$registered_head" && valid_full_oid "$local_head" \
    || die "$CMD: registered/localized HEAD не canonical OID"
  [ "$registered_head" = "$local_head" ] && return 0
  rc=0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git merge-base --is-ancestor "$registered_head" "$local_head" 2>/dev/null
  ) || rc=$?
  [ "$rc" -eq 0 ] && return 0
  [ "$rc" -eq 1 ] || die "$CMD: ancestry registered→localized не доказана"
  rc=0
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git merge-base --is-ancestor "$local_head" "$registered_head" 2>/dev/null
  ) || rc=$?
  [ "$rc" -eq 1 ] || {
    [ "$rc" -eq 0 ] && die "$CMD: localized HEAD stale относительно registered HEAD — relocalize/retest"
    die "$CMD: ancestry localized→registered не доказана"
  }
  die "$CMD: registered/localized HEAD diverged — explicit recovery/retest required"
}

bootstrap_effective_git_context() { # <git -C probe>; selects publisher-compatible localized gitdir
  local probe="$1" probe_root local_gitdir effective_root
  probe_root="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    git -C "$probe" rev-parse --show-toplevel 2>/dev/null
  )" \
    || die "$CMD: требуется запуск из Git worktree"
  local_gitdir="$probe_root/.codex-worktree-git"
  if [ -e "$local_gitdir" ]; then
    validate_localized_git_context "$probe_root" "$local_gitdir"
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    export GIT_DIR="$local_gitdir"
    export GIT_WORK_TREE="$probe_root"
    effective_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "$CMD: effective gitdir не определяет worktree"
  else
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    # Pin subsequent Git consumers to the frozen per-worktree gitdir instead of rediscovering
    # `.git` from the worktree path after the handshake.
    export GIT_DIR="$OUTER_REGISTERED_GITDIR"
    export GIT_WORK_TREE="$OUTER_REGISTERED_ROOT"
    effective_root="$(git rev-parse --show-toplevel 2>/dev/null)" \
      || die "$CMD: frozen registered gitdir не определяет worktree"
  fi
  [ -d "$effective_root" ] || die "$CMD: canonical Git root недоступен"
  GIT_ROOT="$effective_root"
  cd "$GIT_ROOT" || die "$CMD: canonical Git root недоступен"
}

strict_git_object_context() { # object identity must mean the bytes that pack transfer will publish
  local replace_refs grafts
  # Git replacement objects affect rev-list/ls-tree/cat-file, but pack transfer intentionally
  # ignores them.  Keeping replacements enabled here would therefore prove one commit view and
  # publish another under the same printed OID.
  export GIT_NO_REPLACE_OBJECTS=1
  replace_refs="$(git for-each-ref --format='%(refname)' refs/replace 2>/dev/null)" \
    || die "$CMD: refs/replace не читаются fail-closed"
  [ -z "$replace_refs" ] \
    || die "$CMD: refs/replace запрещены для strict quality/publish proof"
  grafts="$(git rev-parse --git-path info/grafts 2>/dev/null)" \
    || die "$CMD: Git grafts path не определяется"
  [ ! -s "$grafts" ] \
    || die "$CMD: non-empty info/grafts запрещён для strict quality/publish proof"
}

strict_git_context() { # canonical selector + the same effective gitdir used by publisher
  canonical_spec_rel "$INPUT_DIR" \
    || die "$CMD: SPEC_DIR должен exact-match specs/NNN-lowercase-slug"
  [ -n "$OUTER_REGISTERED_ROOT" ] \
    || die "$CMD: outer Git worktree authority unavailable"
  revalidate_outer_registered_authority \
    || die "$CMD: frozen outer Git authority changed"
  bootstrap_effective_git_context "$OUTER_REGISTERED_ROOT"
  [ "$(cd "$GIT_ROOT" 2>/dev/null && pwd -P)" = "$OUTER_REGISTERED_ROOT" ] \
    || die "$CMD: effective worktree differs from pinned outer authority"
  revalidate_outer_registered_authority \
    || die "$CMD: frozen outer Git authority changed"
  strict_git_object_context
  revalidate_outer_registered_authority \
    || die "$CMD: frozen outer Git authority changed"
  SPEC_REL="$INPUT_DIR"
  DIR="$SPEC_REL"; STATE="$DIR/state.md"; AUDIT="$DIR/audit.md"
}

mint_internal_git_context() { # validated writer -> implementation/TDD helpers
  local worktree gitdir common_raw common index_raw index_dir index head tree record
  [ -n "$GIT_ROOT" ] || die "$CMD: internal Git context requested before strict validation"
  revalidate_outer_registered_authority \
    || die "$CMD: frozen outer Git authority changed"
  worktree="$(cd "$GIT_ROOT" 2>/dev/null && pwd -P)" \
    || die "$CMD: effective worktree unavailable"
  gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" \
    || die "$CMD: effective gitdir unavailable"
  gitdir="$(cd "$gitdir" 2>/dev/null && pwd -P)" \
    || die "$CMD: effective gitdir is not a real directory"
  common_raw="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || die "$CMD: effective common-dir unavailable"
  case "$common_raw" in
    /*) common="$(cd "$common_raw" 2>/dev/null && pwd -P)" ;;
    *) common="$(cd "$worktree/$common_raw" 2>/dev/null && pwd -P)" ;;
  esac || die "$CMD: effective common-dir is not a real directory"
  index_raw="$(git rev-parse --git-path index 2>/dev/null)" \
    || die "$CMD: effective index path unavailable"
  case "$index_raw" in /*) index="$index_raw" ;; *) index="$worktree/$index_raw" ;; esac
  index_dir="$(cd "$(dirname "$index")" 2>/dev/null && pwd -P)" \
    || die "$CMD: effective index parent unavailable"
  index="$index_dir/$(basename "$index")"
  head="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" \
    || die "$CMD: effective HEAD is not a commit"
  tree="$(git write-tree 2>/dev/null)" \
    || die "$CMD: effective index cannot be materialized"
  valid_full_oid "$head" && valid_full_oid "$tree" \
    || die "$CMD: effective HEAD/index tree is not canonical"
  record="$(WORKTREE="$worktree" GITDIR_VALUE="$gitdir" COMMON_VALUE="$common" \
    INDEX_VALUE="$index" HEAD_VALUE="$head" TREE_VALUE="$tree" perl - \
    <<'PERL'
use strict; use warnings;
use Digest::SHA qw(sha256_hex);
use Fcntl qw(O_RDONLY O_NOFOLLOW S_ISREG S_ISLNK);
sub hx { unpack(q{H*}, $_[0]) }
my $path=$ENV{INDEX_VALUE}; my @named=lstat($path);
exit 2 unless @named && !S_ISLNK($named[2]) && S_ISREG($named[2]) && $named[3]==1;
sysopen(my $fh,$path,O_RDONLY|O_NOFOLLOW) or exit 2; binmode($fh,q{:raw});
my @opened=stat($fh); exit 2 unless @opened && $opened[0]==$named[0] && $opened[1]==$named[1];
my $raw=q{}; while (1) { my $n=sysread($fh,my $b,65536); exit 2 unless defined($n);
  last unless $n; $raw.=$b; exit 2 if length($raw)>134217728 }
my @again=lstat($path); close($fh) or exit 2;
exit 2 unless @again && !S_ISLNK($again[2]) && S_ISREG($again[2]) && $again[3]==1
  && $again[0]==$named[0] && $again[1]==$named[1] && $again[7]==length($raw);
print join(q{:},q{1},map(hx($ENV{$_}),qw(WORKTREE GITDIR_VALUE COMMON_VALUE INDEX_VALUE)),
  $ENV{HEAD_VALUE},$ENV{TREE_VALUE},$named[0],$named[1],$named[7],sha256_hex($raw));
PERL
  )" || die "$CMD: effective index capability cannot be pinned"
  [ "$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" = "$head" ] \
    && [ "$(git write-tree 2>/dev/null)" = "$tree" ] \
    || die "$CMD: effective Git context changed while capability was minted"
  revalidate_outer_registered_authority \
    || die "$CMD: frozen outer Git authority changed"
  export HARNESS_INTERNAL_GIT_CONTEXT_V1="$record"
}

evidence_candidate_root() { # <checkpoint-C>; stdout exact EvidenceRoot
  local checkpoint="$1" out
  [ -r "$EVIDENCE_VERIFY" ] || die "$CMD: evidence verifier недоступен"
  mint_internal_git_context
  out="$(perl "$EVIDENCE_VERIFY" candidate "$GIT_ROOT" "$SPEC_REL" "$checkpoint")" \
    || return $?
  printf '%s\n' "$out" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
    && [ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 1 ] \
    || die "$CMD: evidence candidate output malformed"
  printf '%s' "$out"
}

evidence_verify_bound_root() { # <checkpoint-C>; stdout exact EvidenceRoot
  local checkpoint="$1" out
  [ -r "$EVIDENCE_VERIFY" ] || die "$CMD: evidence verifier недоступен"
  mint_internal_git_context
  out="$(perl "$EVIDENCE_VERIFY" verify-bound "$GIT_ROOT" "$SPEC_REL" "$checkpoint")" \
    || return $?
  CHECKPOINT_EXPECTED="$checkpoint" printf '%s\n' "$out" | CHECKPOINT_EXPECTED="$checkpoint" perl -e '
    use strict; use warnings; local $/; my $v=<STDIN>//q{}; my $c=$ENV{CHECKPOINT_EXPECTED}//q{};
    $v =~ /\AEvidence-Root: ([0-9a-f]{64})\nCheckpoint-C: (?:[0-9a-f]{40}|[0-9a-f]{64})\nImplementation-Root: [0-9a-f]{64}\nImplementation-Attempt: [0-9a-f]{64}\nImplementation-Generation: (?:0|[1-9][0-9]*)\nImplementation-Actor: [A-Za-z0-9][A-Za-z0-9._:-]{0,127}\nCritical-Attempt: [0-9a-f]{64}\nCritical-Actor: [A-Za-z0-9][A-Za-z0-9._:-]{0,127}\nPerformance-Attempt: [0-9a-f]{64}\nPerformance-Actor: [A-Za-z0-9][A-Za-z0-9._:-]{0,127}\nPerformance-Mode: (?:process|n-a)\nAudit-SHA256: [0-9a-f]{64}\n\z/ or exit 2;
    my $root=$1;
    $v =~ /\nCheckpoint-C: ([0-9a-f]{40}|[0-9a-f]{64})\n/ or exit 2;
    my $got=$1;
    exit 2 unless defined($got) && $got eq $c; print $root;
  ' || die "$CMD: bound evidence output malformed"
}

evidence_verify_committed_root() { # <C> <H> <B>; stdout exact EvidenceRoot
  local c="$1" h="$2" b="$3" out
  [ -r "$EVIDENCE_VERIFY" ] || die "$CMD: evidence verifier недоступен"
  mint_internal_git_context
  out="$(perl "$EVIDENCE_VERIFY" verify-committed "$GIT_ROOT" "$SPEC_REL" \
    "$c" "$h" "$b")" || return $?
  C_EXPECTED="$c" H_EXPECTED="$h" B_EXPECTED="$b" printf '%s\n' "$out" \
    | C_EXPECTED="$c" H_EXPECTED="$h" B_EXPECTED="$b" perl -e '
      use strict; use warnings; local $/; my $v=<STDIN>//q{};
      $v =~ /\AEvidence-Root: ([0-9a-f]{64})\nCheckpoint-C: ([0-9a-f]{40}|[0-9a-f]{64})\nEvidence-HEAD: ([0-9a-f]{40}|[0-9a-f]{64})\nBound-HEAD: ([0-9a-f]{40}|[0-9a-f]{64})\nImplementation-Root: [0-9a-f]{64}\nAudit-SHA256: [0-9a-f]{64}\n\z/ or exit 2;
      exit 2 unless $2 eq ($ENV{C_EXPECTED}//q{}) && $3 eq ($ENV{H_EXPECTED}//q{})
        && $4 eq ($ENV{B_EXPECTED}//q{}); print $1;
    ' || die "$CMD: committed evidence output malformed"
}

head_commit_oid() {
  local oid
  oid="$(git rev-parse --verify HEAD^{commit} 2>/dev/null)" || die "$CMD: HEAD не является commit"
  valid_full_oid "$oid" || die "$CMD: Git вернул неканонический полный HEAD OID"
  printf '%s' "$oid"
}

make_verify_tmp() {
  local tmp_base
  [ -z "$VERIFY_TMP" ] || return 0
  [ -r "$PRIVATE_TMP_HELPER" ] || die "$CMD: private temp helper недоступен"
  if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = 1 ]; then
    { : >&9; } 2>/dev/null || die "$CMD: private temp test gate недоступен"
  fi
  tmp_base="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" \
    || die "$CMD: private verification temp base недоступен"
  VERIFY_TMP="$(umask 077; mktemp -d "$tmp_base/pipeline-state.XXXXXX" 2>/dev/null)" \
    || die "$CMD: не удалось создать private verification tempdir"
  chmod 700 "$VERIFY_TMP" 2>/dev/null \
    || die "$CMD: private verification tempdir не защищён"
  VERIFY_TMP_ID="$(perl "$PRIVATE_TMP_HELPER" id "$VERIFY_TMP" 2>/dev/null)" \
    || die "$CMD: private verification tempdir не привязан к inode"
  if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = 1 ]; then
    printf 'ready\n' >&9 || die "$CMD: private temp test gate недоступен"
    kill -STOP "$$" 2>/dev/null || die "$CMD: private temp test pause не установлен"
    verify_tmp_guard || die "$CMD: private verification tempdir identity changed"
  fi
}

verify_tmp_guard() {
  [ -n "$VERIFY_TMP" ] && [ -n "$VERIFY_TMP_ID" ] \
    && perl "$PRIVATE_TMP_HELPER" guard "$VERIFY_TMP" "$VERIFY_TMP_ID" >/dev/null 2>&1
}

metadata_tree_oids() { # <commit> → state-oid|audit-oid; exact two 100644 blobs
  local commit="$1"
  git ls-tree -z "$commit" -- "$STATE" "$AUDIT" 2>/dev/null \
    | EXPECT_STATE="$STATE" EXPECT_AUDIT="$AUDIT" perl -0e '
      use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
      my %v; for my $r (split(/\0/,$d)) {
        next if $r eq q{};
        $r =~ /\A100644 blob ([0-9a-f]{40}|[0-9a-f]{64})\t(.+)\z/s or exit 1;
        $v{$2}=$1;
      }
      my ($s,$a)=@ENV{qw(EXPECT_STATE EXPECT_AUDIT)};
      exit 1 unless keys(%v)==2 && defined($v{$s}) && defined($v{$a});
      print "$v{$s}|$v{$a}";
    '
}

metadata_index_oids() { # stdout state-oid|audit-oid; exact stage-0 100644 entries
  git ls-files -s -z -- "$STATE" "$AUDIT" 2>/dev/null \
    | EXPECT_STATE="$STATE" EXPECT_AUDIT="$AUDIT" perl -0e '
      use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
      my %v; for my $r (split(/\0/,$d)) {
        next if $r eq q{};
        $r =~ /\A100644 ([0-9a-f]{40}|[0-9a-f]{64}) 0\t(.+)\z/s or exit 1;
        $v{$2}=$1;
      }
      my ($s,$a)=@ENV{qw(EXPECT_STATE EXPECT_AUDIT)};
      exit 1 unless keys(%v)==2 && defined($v{$s}) && defined($v{$a});
      print "$v{$s}|$v{$a}";
    '
}

index_flags_standard() {
  git ls-files -v -z | perl -0e '
    use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
    for my $r (split(/\0/, $d)) { next if $r eq q{}; exit 1 if $r =~ /\A(?:[a-z]|S) / }
    exit 0;
  '
}

authority_git() { # authority must not inherit weak stat-cache/fsmonitor trust from repo config
  git -c core.trustctime=true -c core.checkStat=default -c core.fsmonitor=false \
    -c core.ignoreStat=false "$@"
}

authority_raw_worktree_run() { # <clean|paths|untracked> [SPEC_DIR]; raw tree-vs-filesystem proof
  local mode="$1" spec_arg="${2:-}" git_dir work_tree head proof_rc=0
  make_verify_tmp
  verify_tmp_guard || return 1
  git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  work_tree="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  head="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || return 1
  if [ "$mode" = untracked ]; then
    perl "$PRIVATE_TMP_HELPER" worktree-proof "$VERIFY_TMP" "$VERIFY_TMP_ID" \
      "$git_dir" "$work_tree" "$head" "$mode" "$spec_arg" || proof_rc=$?
  else
    perl "$PRIVATE_TMP_HELPER" worktree-proof "$VERIFY_TMP" "$VERIFY_TMP_ID" \
      "$git_dir" "$work_tree" "$head" "$mode" || proof_rc=$?
  fi
  verify_tmp_guard || return 1
  return "$proof_rc"
}

strong_worktree_clean() {
  # Helper/Git details are already suppressed internally. Preserve make_verify_tmp's stable,
  # metadata-only fatal on allocator/canonicalization failure for operator recovery.
  authority_raw_worktree_run clean >/dev/null
}

strong_worktree_paths() { # NUL paths differing from exact HEAD, independent of the live index cache
  authority_raw_worktree_run paths
}

tracked_tree_clean() {
  authority_git diff --cached --quiet --no-ext-diff --no-textconv --ignore-submodules=none -- \
    && strong_worktree_clean
}

no_untracked_in_spec() {
  local rc=0
  # No standard excludes: ignored bytes are still untracked bytes inside the authority directory.
  # Enumerate the descriptor-pinned filesystem against the exact HEAD tree, not the mutable real
  # index: intent-to-add entries are "tracked" only in that index and cannot hide a raw leaf.
  authority_raw_worktree_run untracked "$SPEC_REL" | perl -0e '
    use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
    exit(length($d) ? 1 : 0);
  ' || rc=$?
  [ "$rc" -eq 0 ]
}

stage4_untracked_paths_allowed() { # before H, only first-cycle mandatory evidence may be absent at C
  local rc=0
  authority_raw_worktree_run untracked "$SPEC_REL" \
    | EXPECT_CRITICAL="$SPEC_REL/reviews/critical-code-review.md" \
      EXPECT_PERFORMANCE="$SPEC_REL/reviews/performance-review.md" \
      EXPECT_REQUIREMENT="$SPEC_REL/checklists/requirement-evidence.md" perl -0e '
        use strict; use warnings; local $/; my $raw=<STDIN>//q{};
        my %allowed=map { $_=>1 } @ENV{qw(EXPECT_CRITICAL EXPECT_PERFORMANCE EXPECT_REQUIREMENT)};
        my %seen;
        for my $path (split(/\0/,$raw,-1)) {
          next if $path eq q{}; exit 1 unless $allowed{$path} && !$seen{$path}++;
        }
        exit 0;
      ' || rc=$?
  [ "$rc" -eq 0 ]
}

worktree_delta_is_metadata_only() {
  strong_worktree_paths \
    | EXPECT_STATE="$STATE" EXPECT_AUDIT="$AUDIT" perl -0e '
    use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
    my %got; for my $p (split(/\0/, $d)) { next if $p eq q{}; $got{$p}++ }
    my ($s,$a)=@ENV{qw(EXPECT_STATE EXPECT_AUDIT)};
    exit(keys(%got)==2 && ($got{$s}//0)==1 && ($got{$a}//0)==1 ? 0 : 1);
  '
}

changed_commit_paths_are_metadata_only() { # <H> <B>
  git diff-tree --no-commit-id --name-only --no-ext-diff --no-textconv -r -z "$1" "$2" | EXPECT_STATE="$STATE" EXPECT_AUDIT="$AUDIT" perl -0e '
    use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
    my %got; for my $p (split(/\0/, $d)) { next if $p eq q{}; $got{$p}++ }
    my ($s,$a)=@ENV{qw(EXPECT_STATE EXPECT_AUDIT)};
    exit(keys(%got)==2 && ($got{$s}//0)==1 && ($got{$a}//0)==1 ? 0 : 1);
  '
}

quality_candidate_paths_allowed() { # <Stage-3 checkpoint C> <candidate H>
  # Aggregate C→H delta is deliberately narrower than the final H→B envelope.  State/audit must
  # be ordinary modifications; quality evidence may only be added/modified as regular markdown
  # below the selected spec's reviews/ or checklists/ directories.
  git diff-tree --no-commit-id --raw --no-abbrev --no-renames -r -z "$1" "$2" \
    | EXPECT_STATE="$STATE" EXPECT_AUDIT="$AUDIT" EXPECT_SPEC="$SPEC_REL" perl -0e '
      use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
      my @parts=split(/\0/,$d,-1); pop @parts if @parts && $parts[-1] eq q{};
      my ($state_count,$audit_count)=(0,0);
      while (@parts) {
        @parts>=2 or exit 1;
        my $hdr=shift @parts; my $path=shift @parts;
        $hdr =~ /\A:(\d{6}) (\d{6}) ([0-9a-f]{40}|[0-9a-f]{64}) ([0-9a-f]{40}|[0-9a-f]{64}) ([A-Z])\z/
          or exit 1;
        my ($oldmode,$newmode,$status)=($1,$2,$5);
        my ($state,$audit,$spec)=@ENV{qw(EXPECT_STATE EXPECT_AUDIT EXPECT_SPEC)};
        if ($path eq $state || $path eq $audit) {
          exit 1 unless $status eq q{M} && $oldmode eq q{100644} && $newmode eq q{100644};
          $path eq $state ? $state_count++ : $audit_count++;
          next;
        }
        my $prefix_re=qr/\A\Q$spec\E\/(?:reviews|checklists)\/(.+)\z/s;
        $path =~ $prefix_re or exit 1;
        my $leaf=$1;
        exit 1 if $leaf =~ /[\x00-\x1f\x7f]/ || $leaf =~ m{(?:\A|/)\.\.?(/|\z)};
        exit 1 unless $leaf =~ /\.md\z/ && ($status eq q{A} || $status eq q{M});
        exit 1 unless $newmode eq q{100644};
        exit 1 if $status eq q{M} && $oldmode ne q{100644};
      }
      exit($state_count==1 && $audit_count==1 ? 0 : 1);
    '
}

live_metadata_regular() {
  [ ! -L specs ] && [ ! -L "$SPEC_REL" ] && [ -d "$SPEC_REL" ] \
    && [ -f "$STATE" ] && [ ! -L "$STATE" ] \
    && [ -f "$AUDIT" ] && [ ! -L "$AUDIT" ]
}

internal_spec_exact() {
  grep -Fqx -- "- SPEC_DIR: $SPEC_REL" "$1"
}

quality_checkpoint_from_audit() { # <immutable H audit>; stdout exact Stage-3 checkpoint C
  perl - "$1" <<'PERL'
use strict; use warnings; use utf8;
use Encode qw(decode FB_CROAK);
my $f=shift;
sub bad { print STDERR "pipeline-state: FATAL: candidate audit: $_[0]\n"; exit 2 }
open(my $fh,'<:raw',$f) or bad('blob unreadable'); local $/; my $raw=<$fh>; close $fh;
$raw=q{} unless defined $raw; my $v; eval { $v=decode('UTF-8',$raw,FB_CROAK) }; bad('invalid UTF-8') if $@;
my $modern="# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $legacy="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $body;
if (index($v,$modern)==0) { $body=substr($v,length($modern)) }
elsif (index($v,$legacy)==0) { $body=substr($v,length($legacy)) }
else { bad('header mismatch') }
my $last;
while (length $body) {
  $body =~ s/\A\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
    or bad('malformed row');
  $last=$3 if $2 eq 'stage-4-quality:start';
}
defined($last) or bad('missing stage-4-quality:start');
$last =~ /^checkpoint=([0-9a-f]{40}|[0-9a-f]{64})$/ or bad('latest Stage 4 start has no canonical checkpoint');
print $1;
PERL
}

quality_candidate_audit_contract() { # <C audit> <H audit> <C oid> <C S4 status>
  perl - "$1" "$2" "$3" "$4" <<'PERL'
use strict; use warnings; use utf8;
use Encode qw(decode FB_CROAK);
my ($cf,$hf,$checkpoint,$c_s4)=@ARGV;
sub bad { print STDERR "pipeline-state: FATAL: candidate audit: $_[0]\n"; exit 2 }
sub slurp_raw { my ($f)=@_; open(my $x,'<:raw',$f) or bad('blob unreadable'); local $/; my $v=<$x>; close $x; return defined($v)?$v:q{} }
sub text { my ($raw)=@_; my $v; eval { $v=decode('UTF-8',$raw,FB_CROAK) }; bad('invalid UTF-8') if $@; return $v }
my $modern="# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $legacy="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
sub table {
  my ($raw,$where)=@_; my $v=text($raw); my $body;
  if (index($v,$modern)==0) { $body=substr($v,length($modern)) }
  elsif (index($v,$legacy)==0) { $body=substr($v,length($legacy)) }
  else { bad("$where header mismatch") }
  my @rows;
  while (length $body) {
    $body =~ s/\A\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
      or bad("$where malformed row");
    push @rows,[$1,$2,$3];
  }
  return @rows;
}
my $cr=slurp_raw($cf); my $hr=slurp_raw($hf); table($cr,'C audit'); table($hr,'H audit');
length($hr)>length($cr) && substr($hr,0,length($cr)) eq $cr or bad('C audit is not an exact byte prefix of H');
defined($c_s4) && ($c_s4 eq q{ } || $c_s4 eq q{x}) or bad('C Stage 4 status is not fresh/done');
my $suffix=text(substr($hr,length($cr))); my @transition;
my %premature=map { $_=>1 } (
  'quality-head',
  'quality-verdict',
  'confidence:stage-4-quality',
  'confidence-ack:stage-4-quality',
  'stage-4-quality:done',
);
while (length $suffix) {
  $suffix =~ s/\A\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n//
    or bad('malformed C→H audit suffix');
  my ($ev,$detail)=($2,$3);
  if ($ev eq 'stage-4-quality:start') {
    push @transition,$ev;
    $detail eq "checkpoint=$checkpoint" or bad('Stage 4 start checkpoint mismatch');
  } elsif ($ev eq 'stage-4-quality:invalidated') {
    push @transition,$ev;
    $detail eq 'reset from stage-4-quality'
      or bad('Stage 4 reopen invalidation detail is not canonical');
  }
  bad("premature strict lifecycle event before H: $ev") if $premature{$ev};
}
my @expected_transition = $c_s4 eq q{x}
  ? ('stage-4-quality:invalidated','stage-4-quality:start')
  : ('stage-4-quality:start');
@transition==@expected_transition or bad('C→H Stage 4 reopen/start transition count mismatch');
for my $i (0..$#expected_transition) {
  $transition[$i] eq $expected_transition[$i]
    or bad("C→H Stage 4 transition out of order: expected $expected_transition[$i], got $transition[$i]");
}
exit 0;
PERL
}

audit_contract() { # <table|partial|full> <H-audit> <B/live-audit> <H-oid> [B/live-state]
  perl - "$@" <<'PERL'
use strict; use warnings; use utf8;
use Encode qw(decode FB_CROAK);
my ($mode,$hf,$bf,$candidate,$sf)=@ARGV;
sub bad { print STDERR "pipeline-state: FATAL: audit envelope: $_[0]\n"; exit 2 }
sub slurp_raw { my ($f)=@_; open(my $x,'<:raw',$f) or bad('blob unreadable'); local $/; my $v=<$x>; close $x; return defined($v)?$v:q{} }
sub text { my ($raw)=@_; my $v; eval { $v=decode('UTF-8',$raw,FB_CROAK) }; bad('invalid UTF-8') if $@; return $v }
my $modern="# Pipeline Audit — append-only журнал (пишет только scripts/pipeline-state.sh)\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
my $legacy="# Pipeline Audit\n\n| ts (UTC) | event | detail |\n|---|---|---|\n";
sub parse_table {
  my ($raw,$where)=@_; my $v=text($raw);
  my $body;
  if (index($v,$modern)==0) { $body=substr($v,length($modern)) }
  elsif (index($v,$legacy)==0) { $body=substr($v,length($legacy)) }
  else { bad("$where header mismatch") }
  my @rows;
  while (length $body) {
    $body =~ s/\A(\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n)//
      or bad("$where malformed row");
    push @rows,[$2,$3,$4];
  }
  return @rows;
}
my $hr=slurp_raw($hf); my $br=slurp_raw($bf);
parse_table($hr,'H audit'); parse_table($br,'B audit');
exit 0 if $mode eq 'table';
length($br)>length($hr) && substr($br,0,length($hr)) eq $hr or bad('H audit is not an exact byte prefix');
my $suffix=substr($br,length($hr)); my $suffix_text=text($suffix); my @rows;
while (length $suffix_text) {
  $suffix_text =~ s/\A(\| (\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z) \| ([^|\r\n]+) \| ([^|\r\n]+) \|\n)//
    or bad('malformed audit suffix row');
  push @rows,[$2,$3,$4];
}
my @expected=(
  'quality-head',
  'quality-verdict',
  'confidence:stage-4-quality',
  'stage-4-quality:done',
);
defined($sf) && length($sf) or bad('state oracle missing for strict audit envelope');
my $state=text(slurp_raw($sf));
my ($conf)=($state =~ /^- confidence-stage-4-quality: (.*)$/m);
defined($conf) or bad('state has no Stage 4 confidence anchor');
my $tsre=qr/\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z/;
my ($qv_evidence,$qv_ts);
if ($state =~ /^- quality-verdict: PASS \x{2014} (.+) \(($tsre)\)$/m) {
  ($qv_evidence,$qv_ts)=($1,$2);
}
my ($conf_level,$conf_reason,$conf_ts,$ack_by,$ack_ts);
if ($conf =~ /^green \(($tsre)\)$/) {
  ($conf_level,$conf_reason,$conf_ts)=('green','-',$1);
} elsif ($conf =~ /^green \x{2014} (.+) \(($tsre)\)$/) {
  ($conf_level,$conf_reason,$conf_ts)=('green',$1,$2);
} elsif ($conf =~ / \x{b7} ack: /) {
  $conf =~ /^(yellow|red) \x{2014} (.+) \(($tsre)\) \x{b7} ack: (.+) \(($tsre)\)$/
    or bad('state Stage 4 confidence+ack is not canonical');
  ($conf_level,$conf_reason,$conf_ts,$ack_by,$ack_ts)=($1,$2,$3,$4,$5);
} elsif ($conf =~ /^(yellow|red) \x{2014} (.+) \(($tsre)\)$/) {
  ($conf_level,$conf_reason,$conf_ts)=($1,$2,$3);
} elsif ($conf ne "\x{2014}") {
  bad('state Stage 4 confidence is not canonical');
}
my $need_ack=defined($ack_by) ? 1 : 0;
my $max=@expected+$need_ack;
@rows>=1 or bad('audit suffix must begin its strict lifecycle with quality-head');
for my $phase (0..$#rows) {
  my ($ts,$ev,$detail)=@{$rows[$phase]};
  $phase<$max or bad("foreign/extra strict lifecycle row: $ev");
  my $want=$phase<@expected ? $expected[$phase] : 'confidence-ack:stage-4-quality';
  $ev eq $want
    or bad("foreign/out-of-order strict lifecycle row: expected $want, got $ev");
  if ($phase==0) {
    $detail eq $candidate or bad('quality-head detail is not candidate H');
  } elsif ($phase==1) {
    defined($qv_evidence) or bad('B state has no PASS evidence for quality-verdict row');
    $detail eq "PASS \x{2014} $qv_evidence" && $ts eq $qv_ts
      or bad('quality-verdict audit row does not match B state evidence/timestamp');
  } elsif ($phase==2) {
    defined($conf_level) or bad('B state has no confidence for confidence audit row');
    $detail eq "level=$conf_level reason=$conf_reason" && $ts eq $conf_ts
      or bad('Stage 4 confidence audit row does not match B state level/reason/timestamp');
  } elsif ($phase==3) {
    $state =~ /^- \[x\] stage-4-quality$/m or bad('B state Stage 4 is not done');
    defined($conf_ts) && $detail eq q{-} && $ts eq $conf_ts
      or bad('Stage 4 done row does not match confidence transition timestamp');
  } else {
    $need_ack && $detail eq "by=$ack_by" && $ts eq $ack_ts
      or bad('Stage 4 ack audit row does not match B state actor/timestamp');
  }
}
bad('missing ordered quality-head→PASS→confidence-4→S4-done evidence')
  if $mode eq 'full' && @rows!=$max;
exit 0;
PERL
}

semantic_state_pair() { # <H-state> <B/live-state> <H-oid>; freezes every non-envelope byte
  perl - "$1" "$2" "$3" <<'PERL'
use strict; use warnings; use utf8;
my ($hf,$bf,$candidate)=@ARGV;
sub bad { print STDERR "pipeline-state: FATAL: state envelope: $_[0]\n"; exit 2 }
sub slurp { my ($f)=@_; open(my $x,'<:utf8',$f) or bad('blob unreadable'); local $/; my $v=<$x>; close $x; return defined($v)?$v:q{} }
my ($h,$b)=(slurp($hf),slurp($bf));
for my $pair ([H=>$h],[B=>$b]) {
  my ($n,$v)=@$pair;
  $v =~ /^- Started: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m or bad("$n Started timestamp invalid");
  $v =~ /^- Updated: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m or bad("$n Updated timestamp invalid");
}
$h =~ /^- Quality-HEAD: \x{2014}$/m or bad('H Quality-HEAD must be dash');
$b =~ /^- Quality-HEAD: \Q$candidate\E$/m or bad('B Quality-HEAD does not equal H');
my @rules=(
  qr/^- Updated:.*$/m,
  qr/^- Quality-HEAD:.*$/m,
  qr/^- \[[ x-]\] stage-4-quality$/m,
  qr/^- quality-verdict:.*$/m,
  qr/^- confidence-stage-4-quality:.*$/m,
);
for my $i (0..$#rules) {
  my $rh=($h =~ s/$rules[$i]/__LV029_ALLOWED_${i}__/g);
  my $rb=($b =~ s/$rules[$i]/__LV029_ALLOWED_${i}__/g);
  $rh==1 && $rb==1 or bad('allowed anchor is not unique');
}
$h eq $b or bad('upstream metadata/state bytes changed outside quality envelope');
exit 0;
PERL
}

semantic_stage4_candidate_pair() { # <V4 checkpoint C state> <candidate H state>
  local c_profile c_s4 s c_raw h_raw
  c_raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$1" 2>/dev/null)" || return 1
  h_raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$2" 2>/dev/null)" || return 1
  case "$c_raw:$h_raw" in *$'\036':*$'\036')
    c_raw="${c_raw%$'\036'}"; h_raw="${h_raw%$'\036'}";; *) return 1;; esac
  c_profile="$(printf '%s' "$c_raw" | validate_state_bytes)" || return $?
  [ "$c_profile" = v4-current ] \
    || die "$CMD: checkpoint C должен быть V4 current"
  printf '%s' "$c_raw" | internal_spec_exact /dev/stdin \
    || die "$CMD: C internal SPEC_DIR не совпадает byte-exact"
  printf '%s' "$h_raw" | preboundary_state_ready /dev/stdin \
    || die "$CMD: H state не canonical V4 running boundary"
  for s in stage-1-creative stage-2-audit stage-3-dev; do
    [ "$(printf '%s' "$c_raw" | stage_status /dev/stdin "$s")" = x ] \
      || die "$CMD: C upstream stage chain не завершён"
  done
  printf '%s' "$c_raw" | gate_ready_strict /dev/stdin \
    && printf '%s' "$c_raw" | approval_ready /dev/stdin \
    && printf '%s' "$c_raw" | units_complete /dev/stdin \
    && printf '%s' "$c_raw" | conf_nonblocking stage-3-dev /dev/stdin \
    || die "$CMD: C upstream gates/Units/confidence не разрешают Stage 4"
  c_s4="$(printf '%s' "$c_raw" | stage_status /dev/stdin stage-4-quality)"
  [ "$c_s4" = " " ] || [ "$c_s4" = x ] \
    || die "$CMD: V4 checkpoint C обязан предшествовать current S4 start"
  perl - <(printf '%s' "$c_raw") <(printf '%s' "$h_raw") <<'PERL'
use strict; use warnings; use utf8;
my ($cf,$hf)=@ARGV;
sub bad { print STDERR "pipeline-state: FATAL: candidate state: $_[0]\n"; exit 2 }
sub slurp { my ($f)=@_; open(my $x,'<:utf8',$f) or bad('blob unreadable'); local $/; my $v=<$x>; close $x; return defined($v)?$v:q{} }
my ($c,$h)=(slurp($cf),slurp($hf));
for my $pair ([C=>$c],[H=>$h]) {
  my ($n,$v)=@$pair;
  $v =~ /^- Started: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m or bad("$n Started timestamp invalid");
  $v =~ /^- Updated: \d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$/m or bad("$n Updated timestamp invalid");
}
my @rules=(
  qr/^- Updated:.*$/m,
  qr/^- Evidence-Root:.*$/m,
  qr/^- Quality-HEAD:.*$/m,
  qr/^- \[[ x-]\] stage-4-quality$/m,
  qr/^- quality-verdict:.*$/m,
  qr/^- confidence-stage-4-quality:.*$/m,
);
for my $i (0..$#rules) {
  my $rc=($c =~ s/$rules[$i]/__LV029_CANDIDATE_${i}__/g);
  my $rh=($h =~ s/$rules[$i]/__LV029_CANDIDATE_${i}__/g);
  $rc==1 && $rh==1 or bad('allowed Stage-4-start anchor is not unique');
}
$c eq $h or bad('C→H state changed outside V4 evidence/current-S4-open envelope');
exit 0;
PERL
}

preboundary_state_ready() { # immutable candidate H
  local f="$1" s raw
  raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$f" 2>/dev/null)" || return 1
  case "$raw" in *$'\036') raw="${raw%$'\036'}";; *) return 1;; esac
  [ "$(printf '%s' "$raw" | validate_state_bytes)" = v4-current ] || return 1
  printf '%s' "$raw" | internal_spec_exact /dev/stdin || return 1
  for s in stage-1-creative stage-2-audit stage-3-dev; do
    [ "$(printf '%s' "$raw" | stage_status /dev/stdin "$s")" = x ] || return 1
  done
  [ "$(printf '%s' "$raw" | stage_status /dev/stdin stage-4-quality)" = "-" ] || return 1
  printf '%s' "$raw" | grep -Eq '^- Design-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Eq '^- Implementation-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Eq '^- Evidence-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Fqx -- '- Quality-HEAD: —' || return 1
  printf '%s' "$raw" | grep -Fqx -- '- quality-verdict: —' || return 1
  printf '%s' "$raw" | grep -Fqx -- '- confidence-stage-4-quality: —' || return 1
  printf '%s' "$raw" | gate_ready_strict /dev/stdin \
    && printf '%s' "$raw" | approval_ready /dev/stdin \
    && printf '%s' "$raw" | units_complete /dev/stdin \
    && printf '%s' "$raw" | conf_nonblocking stage-3-dev /dev/stdin
}

bound_state_ready() { # immutable bound commit B
  local f="$1" s raw
  raw="$(perl -e 'local $/; my $v=<>//q{}; exit 1 if length($v)>16777216 || $v=~/\x00/;
    print $v,"\x1e"' "$f" 2>/dev/null)" || return 1
  case "$raw" in *$'\036') raw="${raw%$'\036'}";; *) return 1;; esac
  [ "$(printf '%s' "$raw" | validate_state_bytes)" = v4-current ] || return 1
  printf '%s' "$raw" | internal_spec_exact /dev/stdin || return 1
  for s in $STAGES; do
    [ "$(printf '%s' "$raw" | stage_status /dev/stdin "$s")" = x ] || return 1
  done
  printf '%s' "$raw" | gate_ready_strict /dev/stdin \
    && printf '%s' "$raw" | approval_ready /dev/stdin \
    && printf '%s' "$raw" | units_complete /dev/stdin \
    && printf '%s' "$raw" | verdict_pass_strict /dev/stdin || return 1
  printf '%s' "$raw" | grep -Eq '^- Design-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Eq '^- Implementation-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Eq '^- Evidence-Root: [0-9a-f]{64}$' || return 1
  printf '%s' "$raw" | grep -Eq '^- Quality-HEAD: ([0-9a-f]{40}|[0-9a-f]{64})$' || return 1
  printf '%s' "$raw" | grep -Fqx -- '- confidence-stage-4-quality: —' && return 1
  printf '%s' "$raw" | conf_nonblocking stage-4-quality /dev/stdin
}

validate_live_at_commit() { # <commit> [skip-audit-table]; immutable blobs + index + live-byte oracle
  local commit="$1" table_mode="${2:-table}" state_oid audit_oid idx_state idx_audit live_state live_audit tuple oldifs
  live_metadata_regular || die "$CMD: state/audit должны быть regular non-symlink внутри canonical SPEC_DIR"
  tuple="$(metadata_tree_oids "$commit")" || die "$CMD: commit state/audit должны быть blobs mode 100644"
  oldifs="$IFS"; IFS='|'; set -- $tuple; IFS="$oldifs"; [ "$#" -eq 2 ] || die "$CMD: tree metadata tuple malformed"
  state_oid="$1"; audit_oid="$2"
  tuple="$(metadata_index_oids)" || die "$CMD: index state/audit не canonical stage-0 mode 100644"
  oldifs="$IFS"; IFS='|'; set -- $tuple; IFS="$oldifs"; [ "$#" -eq 2 ] || die "$CMD: index metadata tuple malformed"
  idx_state="$1"; idx_audit="$2"
  [ "$idx_state" = "$state_oid" ] && [ "$idx_audit" = "$audit_oid" ] \
    || die "$CMD: index state/audit не совпадает с immutable commit"
  tuple="$(printf '%s\n%s\n' "$STATE" "$AUDIT" | git hash-object --no-filters --stdin-paths)" \
    || die "$CMD: live state/audit не хешируются"
  set -- $tuple; [ "$#" -eq 2 ] || die "$CMD: live hash tuple malformed"
  live_state="$1"; live_audit="$2"
  [ "$live_state" = "$state_oid" ] && [ "$live_audit" = "$audit_oid" ] \
    || die "$CMD: live state/audit bytes не совпадают с bound commit"
  if [ "$table_mode" != skip-audit-table ]; then audit_contract table "$AUDIT" "$AUDIT" "$commit"; fi
}

strict_clean_checkpoint() { # stage-4 start / quality-head capture input
  local head
  STRICT_CHECKPOINT_HEAD=""
  index_flags_standard || die "$CMD: index содержит assume-unchanged/skip-worktree flags"
  tracked_tree_clean || die "$CMD: требуется clean tracked checkpoint"
  no_untracked_in_spec || die "$CMD: untracked path внутри SPEC_DIR запрещён"
  head="$(head_commit_oid)"
  validate_live_at_commit "$head" || return $?
  internal_spec_exact "$STATE" \
    || die "$CMD: internal SPEC_DIR не совпадает canonical selector до Stage-4 mutation"
  STRICT_CHECKPOINT_HEAD="$head"
}

materialize_commit_metadata() { # <commit> <prefix>
  local commit="$1" prefix="$2" state_record audit_record prior_commit
  case "$prefix" in candidate_h|candidate_c|h|b) ;; *) die "$CMD: internal metadata prefix invalid";; esac
  if [ "$prefix" = candidate_h ] && [ "${SNAP_h_commit:-}" = "$commit" ]; then
    SNAP_candidate_h_state="$SNAP_h_state"
    SNAP_candidate_h_audit="$SNAP_h_audit"
    SNAP_candidate_h_source=h
    SNAP_candidate_h_commit="$commit"
    return 0
  fi
  eval "prior_commit=\${SNAP_${prefix}_commit:-}"
  if [ -n "$prior_commit" ]; then
    [ "$prior_commit" = "$commit" ] \
      && snapshot_read "$prefix" state >/dev/null \
      && snapshot_read "$prefix" audit >/dev/null \
      || die "$CMD: immutable metadata snapshot reuse mismatch"
    return 0
  fi
  make_verify_tmp
  verify_tmp_guard || die "$CMD: private verification tempdir identity changed"
  state_record="$(git cat-file blob "$commit:$STATE" 2>/dev/null \
    | perl "$PRIVATE_TMP_HELPER" write "$VERIFY_TMP" "$VERIFY_TMP_ID" "$prefix.state" 2>/dev/null)" \
    || die "$CMD: immutable state blob не читается"
  audit_record="$(git cat-file blob "$commit:$AUDIT" 2>/dev/null \
    | perl "$PRIVATE_TMP_HELPER" write "$VERIFY_TMP" "$VERIFY_TMP_ID" "$prefix.audit" 2>/dev/null)" \
    || die "$CMD: immutable audit blob не читается"
  eval "SNAP_${prefix}_state=\$state_record"
  eval "SNAP_${prefix}_audit=\$audit_record"
  eval "SNAP_${prefix}_commit=\$commit"
}

snapshot_read() { # <prefix> <state|audit>; descriptor-verifies bytes on every consumption
  local prefix="$1" kind="$2" record source
  case "$prefix:$kind" in
    candidate_h:state|candidate_h:audit|candidate_c:state|candidate_c:audit|h:state|h:audit|b:state|b:audit) ;;
    *) return 1;;
  esac
  eval "record=\${SNAP_${prefix}_${kind}:-}"
  eval "source=\${SNAP_${prefix}_source:-$prefix}"
  [ -n "$record" ] || return 1
  perl "$PRIVATE_TMP_HELPER" read "$VERIFY_TMP" "$VERIFY_TMP_ID" "$source.$kind" "$record" 2>/dev/null
}

validate_quality_candidate_boundary() { # <H>; proves committed Stage-3 checkpoint C→H
  local h="$1" c c_s4 parents evidence_root state_evidence
  valid_full_oid "$h" || die "$CMD: candidate H не canonical full OID"
  if [ "${SNAP_h_commit:-}" != "$h" ]; then
    metadata_tree_oids "$h" >/dev/null || die "$CMD: H state/audit mode/type не 100644 blobs"
  fi
  materialize_commit_metadata "$h" candidate_h
  c="$(quality_checkpoint_from_audit <(snapshot_read candidate_h audit))" || return $?
  valid_full_oid "$c" || die "$CMD: Stage-4 checkpoint C не canonical full OID"
  [ "$c" != "$h" ] || die "$CMD: Stage-4 checkpoint C не может совпадать с H"
  [ "$(git cat-file -t "$c" 2>/dev/null || true)" = commit ] \
    || die "$CMD: Stage-4 checkpoint C object не commit"
  # Endpoint tree equality is not a commit-history proof: an add→revert chain or an `ours` merge
  # can leave an allowlisted H tree while attaching forbidden/private blobs that exact push would
  # still transfer to the remote.  H is therefore one single-parent commit directly on C; the
  # existing aggregate path/mode and semantic checks below validate that sole commit's tree delta.
  parents="$(git rev-list --parents -n 1 "$h" 2>/dev/null)" \
    || die "$CMD: candidate H parent graph не читается"
  set -- $parents
  [ "$#" -eq 2 ] && [ "$1" = "$h" ] && [ "$2" = "$c" ] \
    || die "$CMD: candidate H должен быть sole single-parent direct child checkpoint C; intermediate/add-revert/merge history запрещена"
  quality_candidate_paths_allowed "$c" "$h" \
    || die "$CMD: C→H меняет путь/mode вне state,audit и regular markdown reviews/checklists"
  metadata_tree_oids "$c" >/dev/null || die "$CMD: C state/audit mode/type не 100644 blobs"
  materialize_commit_metadata "$c" candidate_c
  semantic_stage4_candidate_pair <(snapshot_read candidate_c state) \
    <(snapshot_read candidate_h state) || return $?
  c_s4="$(stage_status <(snapshot_read candidate_c state) stage-4-quality)"
  quality_candidate_audit_contract <(snapshot_read candidate_c audit) \
    <(snapshot_read candidate_h audit) "$c" "$c_s4" || return $?
  if [ "$(head_commit_oid)" = "$h" ]; then
    evidence_root="$(evidence_verify_bound_root "$c")" || return $?
    state_evidence="$(snapshot_read candidate_h state | sed -n 's/^- Evidence-Root: //p' | head -1)"
    [ "$state_evidence" = "$evidence_root" ] \
      || die "$CMD: immutable H Evidence-Root не совпадает exact evidence verifier"
  fi
}

captured_quality_guard() { # live post-quality-head mutations; HEAD must remain exact H
  local mode="${1:-mutation}" head qh h_state_oid h_audit_oid idx_state idx_audit tuple oldifs
  index_flags_standard || die "$CMD: index содержит assume-unchanged/skip-worktree flags"
  authority_git diff --cached --quiet --no-ext-diff --no-textconv --ignore-submodules=none -- || die "$CMD: staged changes после Quality-HEAD запрещены"
  worktree_delta_is_metadata_only || die "$CMD: после Quality-HEAD изменяться могут ровно state.md и audit.md"
  no_untracked_in_spec || die "$CMD: untracked path внутри SPEC_DIR запрещён"
  live_metadata_regular || die "$CMD: live state/audit должны быть regular non-symlink"
  head="$(head_commit_oid)"
  qh="$(sed -n 's/^- Quality-HEAD: //p' "$STATE" | head -1)"
  valid_full_oid "$qh" && [ "$qh" = "$head" ] \
    || die "$CMD: Quality-HEAD отсутствует или HEAD изменился — re-open Stage 3 и retest"
  tuple="$(metadata_tree_oids "$head")" || die "$CMD: H state/audit mode/type invalid"
  oldifs="$IFS"; IFS='|'; set -- $tuple; IFS="$oldifs"; [ "$#" -eq 2 ] || die "$CMD: H tree tuple malformed"
  h_state_oid="$1"; h_audit_oid="$2"
  tuple="$(metadata_index_oids)" || die "$CMD: H index entries invalid"
  oldifs="$IFS"; IFS='|'; set -- $tuple; IFS="$oldifs"; [ "$#" -eq 2 ] || die "$CMD: H index tuple malformed"
  idx_state="$1"; idx_audit="$2"
  [ "$idx_state" = "$h_state_oid" ] && [ "$idx_audit" = "$h_audit_oid" ] \
    || die "$CMD: index drift после Quality-HEAD"
  materialize_commit_metadata "$head" h
  preboundary_state_ready <(snapshot_read h state) \
    || die "$CMD: immutable H не является V4 pre-quality boundary"
  validate_quality_candidate_boundary "$head" || return $?
  [ "$(validate_state_shape "$STATE")" = v4-current ] || die "$CMD: live state не V4 current"
  internal_spec_exact "$STATE" || die "$CMD: internal SPEC_DIR не совпадает byte-exact"
  semantic_state_pair <(snapshot_read h state) "$STATE" "$head" || return $?
  audit_contract partial <(snapshot_read h audit) "$AUDIT" "$head" "$STATE" || return $?
  if [ "$mode" = pending ]; then
    [ "$(stage_status "$STATE" stage-4-quality)" = "-" ] \
      && grep -Fqx -- '- quality-verdict: —' "$STATE" \
      && grep -Fqx -- '- confidence-stage-4-quality: —' "$STATE" \
      || die "$CMD: idempotent quality-head допустим только до verdict/confidence/done"
  fi
}

validate_h_b_envelope() { # stdout: B|H|binding-ref; caller already established clean live authority
  local b h c parents spec_hash binding_ref got evidence_root state_evidence
  b="$(head_commit_oid)"
  validate_live_at_commit "$b" skip-audit-table || return $?
  h="$(sed -n 's/^- Quality-HEAD: //p' "$STATE" | head -1)"
  valid_full_oid "$h" || die "$CMD: Quality-HEAD не является полным lowercase commit OID"
  [ "$(git cat-file -t "$h" 2>/dev/null || true)" = commit ] || die "$CMD: Quality-HEAD object не commit"
  parents="$(git rev-list --parents -n 1 "$b" 2>/dev/null)" || die "$CMD: parent B не читается"
  set -- $parents
  [ "$#" -eq 2 ] && [ "$1" = "$b" ] && [ "$2" = "$h" ] \
    || die "$CMD: B должен быть единственным direct child H (merge/grandchild/empty chain запрещены)"
  changed_commit_paths_are_metadata_only "$h" "$b" \
    || die "$CMD: H→B должен менять ровно state.md и audit.md"
  metadata_tree_oids "$h" >/dev/null || die "$CMD: H state/audit mode/type не 100644 blobs"
  materialize_commit_metadata "$h" h
  materialize_commit_metadata "$b" b
  bound_state_ready <(snapshot_read b state) || die "$CMD: B state не полный V4 PASS"
  validate_quality_candidate_boundary "$h" || return $?
  c="$(quality_checkpoint_from_audit <(snapshot_read h audit))" || return $?
  evidence_root="$(evidence_verify_committed_root "$c" "$h" "$b")" || return $?
  state_evidence="$(snapshot_read b state | sed -n 's/^- Evidence-Root: //p' | head -1)"
  [ "$state_evidence" = "$evidence_root" ] \
    || die "$CMD: bound B Evidence-Root не совпадает exact C→H→B verifier"
  semantic_state_pair <(snapshot_read h state) <(snapshot_read b state) "$h" || return $?
  audit_contract full <(snapshot_read h audit) <(snapshot_read b audit) "$h" \
    <(snapshot_read b state) || return $?
  spec_hash="$(printf '%s' "$SPEC_REL" | git hash-object --stdin)" \
    || die "$CMD: spec hash не вычислен"
  valid_full_oid "$spec_hash" || die "$CMD: spec hash неканонический"
  binding_ref="refs/worktree/agent-harness-bindings/$spec_hash/$h"
  printf '%s|%s|%s' "$b" "$h" "$binding_ref"
}

validate_outbound_base() { # <pinned remote R>; require exact public graph R→C→H→B
  local remote="$1" tuple b h rest c parents
  valid_full_oid "$remote" || die "$CMD: remote base R не canonical full OID"
  [ "$(git cat-file -t "$remote" 2>/dev/null || true)" = commit ] \
    || die "$CMD: remote base R object не commit"
  tuple="$(validate_h_b_envelope)" || return $?
  b="${tuple%%|*}"; rest="${tuple#*|}"; h="${rest%%|*}"
  materialize_commit_metadata "$h" candidate_h
  c="$(quality_checkpoint_from_audit <(snapshot_read candidate_h audit))" || return $?
  parents="$(git rev-list --parents -n 1 "$c" 2>/dev/null)" \
    || die "$CMD: checkpoint C parent graph не читается"
  set -- $parents
  [ "$#" -eq 2 ] && [ "$1" = "$c" ] && [ "$2" = "$remote" ] \
    || die "$CMD: checkpoint C должен быть sole single-parent direct child pinned remote R; pre-C intermediate/add-revert/merge history запрещена"
  printf '%s|%s|%s|%s' "$remote" "$c" "$h" "$b"
}

direct_binding_ref_oid() { # <ref>; stdout OID; 0=direct commit ref, 1=absent, 2=malformed/symref
  local ref="$1" row parsed
  # for-each-ref omits a symbolic ref whose target does not exist.  Without this raw symref probe
  # bind-head would misclassify that existing ref as absent and update-ref --no-deref could replace
  # it under the zero-OID CAS.  Reject every symbolic ref before absent/direct classification.
  if git symbolic-ref -q "$ref" >/dev/null 2>&1; then return 2; fi
  row="$(git for-each-ref --format='%(refname)|%(objectname)|%(symref)' "$ref" 2>/dev/null)" \
    || return 2
  [ -n "$row" ] || return 1
  parsed="$(EXPECTED_REF="$ref" perl -e '
    use strict; use warnings; my $v=do { local $/; <STDIN> }; $v=q{} unless defined $v;
    $v =~ s/\n\z//;
    my ($refname,$oid,$sym)=split(/\|/,$v,-1);
    exit 1 unless defined($sym) && $refname eq $ENV{EXPECTED_REF} && $sym eq q{}
      && $oid =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/ && $v !~ /\n/;
    print $oid;
  ' <<<"$row")" || return 2
  [ "$(git cat-file -t "$parsed" 2>/dev/null || true)" = commit ] || return 2
  printf '%s' "$parsed"
}

bound_authority() { # <envelope|ref>; stdout B|H|ref
  local mode="$1" tuple b h ref got
  index_flags_standard || die "$CMD: index содержит assume-unchanged/skip-worktree flags"
  tracked_tree_clean || die "$CMD: tracked worktree должен exact-match bound commit"
  no_untracked_in_spec || die "$CMD: untracked path внутри SPEC_DIR запрещён"
  tuple="$(validate_h_b_envelope)" || exit $?
  OLDIFS="$IFS"; IFS='|'; set -- $tuple; IFS="$OLDIFS"
  [ "$#" -eq 3 ] || die "$CMD: internal envelope tuple malformed"
  b="$1"; h="$2"; ref="$3"
  if [ "$mode" = ref ]; then
    got="$(direct_binding_ref_oid "$ref")" \
      || die "$CMD: per-worktree binding ref отсутствует, symbolic/malformed или указывает не на commit"
    [ "$got" = "$b" ] || die "$CMD: direct per-worktree binding ref указывает не на B"
  fi
  printf '%s|%s|%s' "$b" "$h" "$ref"
}

check_transition() { # <stage|publish>; caller already owns/recovered the per-SPEC lock when one exists
  local s="$1" profile="" ok=0 x auth_out="" shape_rc=0
  [ "$s" = publish ] || valid_stage "$s" || die "неизвестный этап (ожидаю: $STAGES | publish)"
  if [ ! -f "$STATE" ]; then
    if [ "$s" = stage-1-creative ]; then note "state ещё нет — stage-1 можно (init создаст)"; return 0; fi
    echo "pipeline-state: BLOCKED $s: нет $STATE (сначала init и предыдущие этапы)" >&2
    return 1
  fi
  profile="$(validate_state_shape "$STATE")" || return $?
  case "$profile" in
    v4-current) ;;
    legacy|v2|v3)
      echo "pipeline-state: BLOCKED $s: migration-required: State $profile inspect-only; выполни migrate-v4" >&2
      return 1 ;;
    *)
      echo "pipeline-state: BLOCKED $s: contract-migration-required" >&2
      return 1 ;;
  esac
  if [ "$s" = publish ]; then strict_git_context; fi
  case "$s" in
    stage-1-creative) ;;
    stage-2-audit)
      [ "$(stage_status "$STATE" stage-1-creative)" = x ] \
        || { echo "pipeline-state: BLOCKED stage-2: stage-1-creative не завершён (нет [x] в $STATE)" >&2; ok=1; }
      conf_nonblocking stage-1-creative "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-2: confidence stage-1 = non-green без ack — сомнение стадии-1 стопит переход (ack владельца снимает: pipeline-state.sh ack $DIR stage-1-creative)" >&2; ok=1; } ;;
    stage-3-dev)
      for x in stage-1-creative stage-2-audit; do
        [ "$(stage_status "$STATE" "$x")" = x ] \
          || { echo "pipeline-state: BLOCKED stage-3: $x не завершён" >&2; ok=1; }
      done
      gate_ready_strict "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-3: нужны MUST-FLAG:0 и NEEDS-INFO:0 canonical gate" >&2; ok=1; }
      if ! design_authority_current; then
        echo "pipeline-state: BLOCKED stage-3: Design-Root или независимое architecture review отсутствует/устарело" >&2
        ok=1
      fi
      approval_ready "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-3: user-approval != approved (гейт владельца обязателен)" >&2; ok=1; } ;;
    stage-4-quality)
      for x in stage-1-creative stage-2-audit stage-3-dev; do
        [ "$(stage_status "$STATE" "$x")" = x ] \
          || { echo "pipeline-state: BLOCKED stage-4: $x не завершён" >&2; ok=1; }
      done
      gate_ready_strict "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-4: constitution-gate не canonical green" >&2; ok=1; }
      if ! design_authority_current; then
        echo "pipeline-state: BLOCKED stage-4: Design-Root/review authority устарела" >&2
        ok=1
      fi
      if ! implementation_authority_current; then
        echo "pipeline-state: BLOCKED stage-4: Implementation-Root/TDD authority отсутствует или не воспроизводится" >&2
        ok=1
      fi
      approval_ready "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-4: user-approval != approved" >&2; ok=1; }
      conf_nonblocking stage-3-dev "$STATE" \
        || { echo "pipeline-state: BLOCKED stage-4: confidence stage-3 = non-green без ack — сомнение реализации стопит quality (ack: pipeline-state.sh ack $DIR stage-3-dev)" >&2; ok=1; }
      if ! units_complete "$STATE"; then
        echo "pipeline-state: BLOCKED stage-4: не все юниты прошли convergence-check (unit-done):" >&2
        grep '^- \[[ -]\] unit:' "$STATE" >&2 || true; ok=1
      fi ;;
    publish)
      if ! design_authority_current; then
        echo "pipeline-state: BLOCKED publish: Design-Root/review authority устарела" >&2
        ok=1
      fi
      if ! implementation_authority_frozen; then
        echo "pipeline-state: BLOCKED publish: retained Implementation-Root/TDD authority отсутствует" >&2
        ok=1
      fi
      if auth_out="$(bound_authority ref 2>&1)"; then :; else
        validate_state_shape "$STATE" >/dev/null || shape_rc=$?
        [ "$shape_rc" -eq 0 ] || return "$shape_rc"
        [ -z "$auth_out" ] || printf '%s\n' "$auth_out" >&2
        echo "pipeline-state: BLOCKED publish: immutable H→B/ref/live predicate не прошёл" >&2
        ok=1
      fi ;;
  esac
  if [ "$ok" -eq 0 ]; then note "check OK: $s можно $([ "$s" = publish ] && echo публиковать || echo стартовать)"; fi
  return "$ok"
}

show_status() { # caller owns/recovered lock
  local next="" s
  need_state
  validate_state_shape "$STATE" >/dev/null
  cat "$STATE"; echo
  for s in $STAGES; do grep -q "^- \[x\] $s" "$STATE" || { next="$s"; break; }; done
  if [ -z "$next" ]; then
    note "все этапы [x] — пайплайн завершён (итог: см. quality-verdict)"
  elif check_transition "$next" >/dev/null 2>&1; then
    note "next: $next (check OK — стартуй с него)"
  else
    note "next: $next — BLOCKED:"
    check_transition "$next" || true
  fi
}

# Resolve every repository-bound selector before deriving the per-SPEC lock path.  This makes
# nested-cwd behavior deterministic and prevents a caller from locking one spelling while the
# verifier authorizes another canonical path.
case "$CMD" in
  review-start|review-finish|review-blocked|performance-run|evidence-bind|design-bind|implementation-start|implementation-content-root|tdd-run|implementation-bind|sdd-append|delivery-append|quality-head|verdict|bind-head|publish-base)
    strict_git_context ;;
  approve)
    [ "${3:-}" != approved ] || strict_git_context ;;
  stage-start)
    case "${3:-}" in stage-3-dev|stage-4-quality) strict_git_context ;; esac ;;
  stage-done)
    case "${3:-}" in stage-2-audit|stage-3-dev|stage-4-quality) strict_git_context ;; esac ;;
  status)
    # A canonical repo-relative status selector can authorize the displayed next transition.
    # Resolve it before taking the pair lock so status and explicit check share one physical
    # worktree/spec identity (notably across /tmp -> /private/tmp aliases on macOS).  Absolute
    # legacy/recovery selectors remain inspect-only and deliberately do not gain authority.
    if canonical_spec_rel "$INPUT_DIR" && [ -n "$OUTER_REGISTERED_ROOT" ]; then
      strict_git_context
    fi ;;
  check)
    case "${3:-}" in stage-3-dev|stage-4-quality|publish) strict_git_context ;; esac ;;
esac

case "$CMD" in
  init)
    mkdir -p "$DIR"
    mutation_lock_acquire
    pair_tx_recover
    ;;
  migrate-v4|migrate-contract|link-ticket|link-ticket-cas|gate|approve|units-set|unit-done|event|validate-state)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
  review-start|review-finish|review-blocked|performance-run|evidence-bind|design-bind|implementation-start|implementation-content-root|tdd-run|implementation-bind|sdd-append|delivery-append)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
  stage-start|stage-done|ack)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
  verdict|quality-head|bind-head)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
  check)
    # A missing spec has no pair to reconcile and retains the historical BLOCKED/Stage-1 answer.
    # Once the directory exists, readers serialize on the same lock and recover-or-fail before
    # observing state/audit, so the audit-first install window is never externally authorizing.
    # Publish checks are different: resolve and validate the canonical selector before probing
    # the pair.  Otherwise a nested cwd (or a selector containing a control byte) is mistaken for
    # a merely missing relative path and bypasses both the strict selector diagnostic and the
    # per-SPEC recovery lock.
    # `check publish` already resolved the exact Git/spec identity before this lock branch.  The
    # transition itself performs the mandatory post-recovery strict revalidation; a second
    # pre-lock discovery here was identical work with no intervening mutation or recovery.
    if [ -d "$DIR" ]; then mutation_lock_acquire; pair_tx_recover; fi
    ;;
  publish-base)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
  status)
    [ -d "$DIR" ] || die "нет $STATE — сначала: pipeline-state.sh init $DIR \"<фича>\""
    mutation_lock_acquire
    pair_tx_recover
    ;;
esac

# Legacy V1/V2/V3 is byte-readable only. Run this after pair-WAL recovery but before every
# authorizing mutation or Git predicate so the typed migration result cannot be shadowed by an
# unrelated repository-context error.
case "$CMD" in
  status|validate-state|migrate-v4|migrate-contract) ;;
  check) ;;
  init)
    if [ -f "$STATE" ]; then require_current_authority; fi ;;
  *)
    if [ -f "$STATE" ]; then require_current_authority; fi ;;
esac

case "$CMD" in
  init)
    arity 2 5 '<SPEC_DIR> [описание] [feature|bugfix|enterprise] [ticket]'
    FEATURE="${3:-}"; SCOPE="${4:-feature}"; TICKET="${5:-}"  # ticket — строго 5-й позиционный, опционален
    case "$SCOPE" in feature|bugfix|enterprise) ;; *) die "init: scope ожидаю feature|bugfix|enterprise";; esac
    # санитизация: значения попадают в markdown-шапку state.md (FEATURE тоже, не только TICKET)
    TICKET="$(sanitize "$TICKET")"; FEATURE="$(sanitize "$FEATURE")"
    if [ -f "$STATE" ]; then
      note "state уже существует — это resume, init пропущен (data sacred). Статус:"
      show_status
      exit 0
    fi
    # V4 metadata stays repo-relative even when a compatibility caller supplies an absolute
    # filesystem location. File creation still uses the caller path; strict Stage 4 later requires
    # this proven relative value to match specs/NNN-slug. Non-Git locations remain inspectable but
    # cannot later satisfy strict Stage-4/publish authority.
    case "$DIR" in /*) STATE_SPEC_DIR="unbound" ;; *) STATE_SPEC_DIR="$DIR" ;; esac
    INIT_ROOT="$OUTER_REGISTERED_ROOT"
    if [ -n "$INIT_ROOT" ]; then
      revalidate_outer_registered_authority \
        || die "$CMD: frozen outer Git authority changed"
      INIT_ABS="$(cd "$DIR" && pwd -P)"
      revalidate_outer_registered_authority \
        || die "$CMD: frozen outer Git authority changed"
      case "$INIT_ABS" in
        "$INIT_ROOT"/*)
          INIT_REL="${INIT_ABS#$INIT_ROOT/}"
          STATE_SPEC_DIR="$INIT_REL" ;;
      esac
    fi
    state_tmp_create
    STATE_BASE_RECORD="missing"
    state_tmp_initialize <<EOF
# Pipeline State — ${FEATURE:-<фича не описана>}

- State-Version: 4
- Delivery-Contract: architecture-evidence-v1
- SPEC_DIR: $STATE_SPEC_DIR
- Scope: $SCOPE
- Ticket: ${TICKET:-—}
- Started: $TS
- Updated: $TS
- Design-Root: —
- Implementation-Root: —
- Evidence-Root: —
- Quality-HEAD: —

## Stages

- [ ] stage-1-creative
- [ ] stage-2-audit
- [ ] stage-3-dev
- [ ] stage-4-quality

## Gates

- constitution-gate: —
- user-approval: —
- quality-verdict: —

## Confidence

- confidence-stage-1-creative: —
- confidence-stage-2-audit: —
- confidence-stage-3-dev: —
- confidence-stage-4-quality: —

> Файл ведёт \`scripts/pipeline-state.sh\` — чекбоксы, гейты и confidence руками не редактируются;
> журнал событий — \`audit.md\` рядом (append-only). Confidence — fail-safe сигнал стадий:
> non-green блокирует следующий этап до \`ack\` владельца; green ничего не разблокирует;
> «—» = не задекларирован (поведение как до фичи).
EOF
    state_tx_commit
    audit_row "init" "scope=$SCOPE · ${FEATURE:--}"
    if [ -n "$TICKET" ]; then audit_row "ticket:linked" "$TICKET"; fi
    pair_tx_commit
    note "state создан: $STATE (scope: $SCOPE${TICKET:+, ticket: $TICKET})"
    ;;

  migrate-v4)
    arity 2 2 '<SPEC_DIR>'
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    case "$PROFILE" in
      v4-current)
        note "migrate-v4: state уже V4 current — no-op"
        exit 0 ;;
      legacy|v2|v3) ;;
      *) die "migrate-v4: contract-migration-required" ;;
    esac
    MIGRATION_SCOPE="$(scope_value "$STATE")"
    NEXT_GENERATION="$(receipt_generation next)" \
      || die "migrate-v4: receipt generation audit malformed/exhausted"
    state_tx_begin
    state_temp_transform migrate-v4 "$MIGRATION_SCOPE" "$TS"
    state_tx_commit
    audit_row "migration:v4" "from=$PROFILE;contract=architecture-evidence-v1"
    audit_row "receipt-invalidate" "generation=$NEXT_GENERATION;scopes=architecture,implementation,quality,evidence"
    pair_tx_commit
    [ "$(validate_state_shape "$STATE")" = v4-current ] \
      || die "migrate-v4: postcondition V4 current не подтверждён"
    note "migrate-v4: $PROFILE → v4-current; Stage 2–4 reopened"
    ;;

  migrate-contract)
    arity 2 2 '<SPEC_DIR>'
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    case "$PROFILE" in
      v4-current)
        die "migrate-contract:no-migration-path: registered from→current plan отсутствует" ;;
      legacy|v2|v3)
        die "migrate-contract: migration-required: сначала migrate-v4" ;;
      *) die "migrate-contract: contract-migration-required" ;;
    esac
    ;;

  link-ticket|link-ticket-cas)
    if [ "$CMD" = link-ticket-cas ]; then
      [ "$ARGC" -eq 4 ] || [ "$ARGC" -eq 8 ] \
        || die "$CMD: ожидаю <SPEC_DIR> <expected-ticket> <ticket> [root-id specs-id dir-id state-id] (получено аргументов: $ARGC)"
      EXPECTED_TICKET="$3"; KEY="$4"
      if [ "$ARGC" -eq 8 ]; then
        EXPECTED_ROOT_ID="$5"; EXPECTED_SPECS_ID="$6"
        EXPECTED_DIR_ID="$7"; EXPECTED_STATE_ID="$8"
        expected_spec_authority "$EXPECTED_ROOT_ID" "$EXPECTED_SPECS_ID" \
          "$EXPECTED_DIR_ID" "$EXPECTED_STATE_ID" \
          || die "link-ticket-cas: caller SPEC authority не совпадает"
      fi
    else
      arity 3 3 '<SPEC_DIR> <ticket>'
      EXPECTED_TICKET=""; KEY="$3"
    fi
    # Пост-фактум привязка SPEC_DIR ↔ тикет. Идемпотентность явная:
    # тот же KEY → no-op БЕЗ нового audit-события; другой KEY → overwrite + событие с деталью old → new.
    # Существование тикета в бэкенде здесь НЕ проверяется (state-машина обязана работать офлайн;
    # best-effort валидация — забота оператора/этап-промптов, не гейт).
    need_state
    validate_state_shape "$STATE" >/dev/null
    KEY="$(sanitize "$KEY")"
    CUR="$(sed -n 's/^- Ticket: //p' "$STATE" | head -1)"
    if [ "$CMD" = link-ticket-cas ]; then
      if [ "$ARGC" -eq 8 ]; then
        expected_spec_authority "$EXPECTED_ROOT_ID" "$EXPECTED_SPECS_ID" \
          "$EXPECTED_DIR_ID" "$EXPECTED_STATE_ID" \
          || die "link-ticket-cas: caller SPEC authority изменилась до mutation"
      fi
      EXPECTED_TICKET="$(sanitize "$EXPECTED_TICKET")"
      [ "$CUR" = "$EXPECTED_TICKET" ] \
        || die "link-ticket-cas: current Ticket не совпадает с expected"
    fi
    if [ "$CUR" = "$KEY" ]; then
      note "link-ticket: тикет уже привязан ($KEY) — no-op (идемпотентность, событие не дублируется)"
    else
      state_tx_begin
      state_temp_transform link-ticket "$KEY"
      upd_ts "$STATE_TMP"; state_tx_commit
      if [ -n "$CUR" ] && [ "$CUR" != "—" ]; then
        audit_row "ticket:linked" "$CUR → $KEY"
      else
        audit_row "ticket:linked" "$KEY"
      fi
      pair_tx_commit
      note "link-ticket: $KEY → $STATE"
    fi
    # Догон маркера «Источник: тикет»: при пост-фактум привязке spec.md обязан нести
    # «Источник: тикет KEY» (канонический bullet, распознаётся spec-lint/dora-metrics). Advisory:
    # только если spec.md рядом; выполняется и на no-op (гарантирует маркер даже при повторной привязке).
    SP="$DIR/spec.md"
    if [ -f "$SP" ]; then
      if grep -qE '^[-*>]?[[:space:]]*Источник:.*[Тт]икет' "$SP"; then
        KEYV="$KEY" perl -pi -e 's/^[-*>]?\s*Источник:.*[Тт]икет.*$/- Источник: тикет $ENV{KEYV}/' "$SP"
      else
        KEYV="$KEY" perl -pi -e '$_ .= "\n- Источник: тикет $ENV{KEYV}\n" if $. == 1' "$SP"
      fi
      note "link-ticket: маркер «Источник: тикет ${KEY}» в spec.md (догон маркера)"
    fi
    ;;

  units-set)
    arity 3 3 '<SPEC_DIR> "unit-a,unit-b"'
    LIST="$3"
    need_state
    validate_state_shape "$STATE" >/dev/null
    require_running stage-2-audit
    LIST="$(normalize_units "$LIST")"
    if grep -q '^## Units' "$STATE"; then
      grep -q '^- \[x\] unit:' "$STATE" && die "units-set: юниты уже есть и часть отмечена done — пере-задание уничтожило бы прогресс (data sacred); правь точечно"
    fi
    state_tx_begin
    state_temp_transform units-set "$LIST"
    upd_ts "$STATE_TMP"; state_tx_commit; audit_row "units-set" "$LIST"; pair_tx_commit
    note "units заданы: $LIST (stage-4 заблокирован, пока каждый не unit-done)"
    ;;

  unit-done)
    arity 3 3 '<SPEC_DIR> <unit>'
    U="$3"
    need_state
    validate_state_shape "$STATE" >/dev/null
    require_running stage-3-dev
    printf '%s' "$U" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$' || die "unit-done: невалидное имя"
    USTAT="$(unit_status "$STATE" "$U")" || die "unit-done: unit не найден exact-match"
    if [ "$USTAT" = x ]; then note "unit-done: $U уже done — no-op"; exit 0; fi
    state_tx_begin
    state_temp_transform unit-done "$U"
    upd_ts "$STATE_TMP"; state_tx_commit; audit_row "unit-done" "$U"; pair_tx_commit
    note "unit done: $U"
    ;;

  stage-start)
    arity 3 3 '<SPEC_DIR> <stage>'
    S="$3"
    valid_stage "$S" || die "неизвестный этап (ожидаю: $STAGES)"
    case "$S" in stage-3-dev|stage-4-quality) strict_git_context ;; esac
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    CUR="$(stage_status "$STATE" "$S")"
    if [ "$S" = stage-4-quality ]; then
      internal_spec_exact "$STATE" \
        || die "stage-start: internal SPEC_DIR не совпадает canonical selector"
      case "$PROFILE" in
        v4-current) ;;
        *) die "stage-start: migration-required: strict Stage 4 требует V4 current" ;;
      esac
    fi
    check_transition "$S" || die "этап $S BLOCKED — причина выше; обход гейта запрещён"
    if [ "$CUR" = "-" ]; then
      if [ "$S" = stage-4-quality ]; then
        RESUME_CHECKPOINT="$(quality_checkpoint_from_audit "$AUDIT")" || exit $?
        valid_full_oid "$RESUME_CHECKPOINT" \
          && [ "$(git cat-file -t "$RESUME_CHECKPOINT" 2>/dev/null || true)" = commit ] \
          || die "stage-start: running S4 не имеет usable Stage-3 checkpoint C — re-open Stage 3"
      fi
      note "$S уже [-] — resume no-op (новый start-event не дублируется)"
      exit 0
    fi
    if [ "$S" = stage-4-quality ]; then
      strict_clean_checkpoint || exit $?
      S4_CHECKPOINT="$STRICT_CHECKPOINT_HEAD"
      valid_full_oid "$S4_CHECKPOINT" || die "stage-start: validated Stage-3 checkpoint C потерян"
    fi
    INVALIDATED=""
    # Даже [ ] может соседствовать с историческим downstream [x]/PASS в pre-V2 state.
    # Любой не-resume start очищает snapshot от текущей стадии и ниже, иначе старый PASS
    # способен пережить последовательное дозавершение upstream и ложно открыть publish.
    for x in $(stages_from "$S"); do
      OLD="$(stage_status "$STATE" "$x")"
      [ "$OLD" = " " ] || INVALIDATED="$INVALIDATED $x"
    done
    if [ -n "$INVALIDATED" ]; then
      NEXT_GENERATION="$(receipt_generation next)" \
        || die "stage-start: receipt generation audit malformed/exhausted"
      INVALIDATION_SCOPES="$(invalidation_scopes "$S")" \
        || die "stage-start: invalidation scope отсутствует"
    fi
    state_tx_begin
    invalidate_from "$STATE_TMP" "$S"
    mark_stage "$S" "-" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit
    for x in $INVALIDATED; do audit_row "$x:invalidated" "reset from $S"; done
    if [ -n "$INVALIDATED" ]; then
      audit_row "receipt-invalidate" "generation=$NEXT_GENERATION;scopes=$INVALIDATION_SCOPES"
    fi
    if [ "$S" = stage-4-quality ]; then
      audit_row "$S:start" "checkpoint=$S4_CHECKPOINT"
    else
      audit_row "$S:start"
    fi
    pair_tx_commit
    note "$S → start"
    ;;

  stage-done)
    arity 3 5 '<SPEC_DIR> <stage> [green|yellow|red] [причина]'
    S="$3"
    COLOR="${4:-}"; REASON="${5:-}"   # опциональная confidence-декларация; молчание = «—»
    valid_stage "$S" || die "неизвестный этап (ожидаю: $STAGES)"
    case "$S" in stage-3-dev|stage-4-quality) strict_git_context ;; esac
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    CUR="$(stage_status "$STATE" "$S")"
    [ "$CUR" != " " ] || die "stage-done: $S ещё [ ] — сначала stage-start"
    if [ "$CUR" = x ] && [ -z "$COLOR" ]; then
      note "stage-done: $S уже [x], confidence не передан — no-op"
      exit 0
    fi
    if [ "$S" = stage-4-quality ] && [ "$CUR" = x ]; then
      die "stage-done: confidence завершённой strict Stage 4 заморожен; новый замер только через official re-open Stage 4"
    fi
    if [ "$S" = stage-4-quality ]; then
      [ "$PROFILE" = v4-current ] || die "stage-done: strict Stage 4 требует V4 current + quality-head"
      captured_quality_guard mutation || exit $?
      [ -n "$COLOR" ] || die "stage-done: V4 Stage 4 требует явный confidence green|yellow|red"
    fi
    [ -n "$COLOR" ] || [ -z "$REASON" ] || die "stage-done: причина без цвета confidence запрещена"
    if [ -n "$COLOR" ]; then
      case "$COLOR" in
        green|yellow|red) ;;
        *) die "stage-done: цвет confidence ожидаю green|yellow|red (эмодзи/иной регистр не принимаются — храним ascii)";;
      esac
      if [ "$COLOR" = green ]; then
        # механический пол против green-театра: green невозможен при незакрытых флагах/FAIL/юнитах
        grep -q '^- quality-verdict: FAIL' "$STATE" \
          && die "stage-done: green запрещён при quality-verdict: FAIL — доработай и переори verdict до green (анти-театр I-17)"
        if grep -q '^- constitution-gate: ' "$STATE" && ! grep -q '^- constitution-gate: —' "$STATE"; then
          grep -Eq '^- constitution-gate: .*MUST-FLAG: 0($|[^0-9])' "$STATE" \
            || die "stage-done: green запрещён при MUST-FLAG>0 — устрани флаги или задекларируй yellow|red"
        fi
        if [ "$S" = "stage-3-dev" ] && ! units_complete "$STATE"; then
          die "stage-done: green на stage-3-dev при незакрытых юнитах (unit без convergence-check) запрещён — заврши юниты или yellow|red"
        fi
      elif ! printf '%s' "$REASON" | grep -q '[^[:space:]]'; then
        die "stage-done: $COLOR требует причину 5-м аргументом (\"что под сомнением + как проверить\") — fail-safe гейт без причины бессмыслен"
      fi
      REASON="$(sanitize "$REASON")"
      # периметр публичного git-журнала (I-1): причина без путей машины/IP
      if printf '%s' "$REASON" | grep -Eq '/(Users|home)/|[0-9]{1,3}(\.[0-9]{1,3}){3}'; then
        die "stage-done: причина confidence несёт путь машины/IP — audit.md публичен (I-1); переформулируй без литералов среды"
      fi
      REASON="${REASON// · / - }"   # вырезать разделитель ' · ' — причина не сформирует поддельный ' · ack:' суффикс
      if [ -n "$REASON" ]; then CVAL="$COLOR — $REASON ($TS)"; else CVAL="$COLOR ($TS)"; fi
    fi
    if [ "$CUR" = "-" ]; then
      case "$S" in
        stage-1-creative) ;;
        stage-2-audit)
          gate_ready_strict "$STATE" || die "stage-done: stage-2 требует MUST-FLAG:0 и NEEDS-INFO:0"
          design_authority_current || die "stage-done: stage-2 требует current Design-Root + causal architecture review"
          approval_ready "$STATE" || die "stage-done: stage-2 требует user-approval: approved"
          [ "$(scope_value "$STATE")" != enterprise ] || has_units "$STATE" || die "stage-done: enterprise требует непустые Units" ;;
        stage-3-dev)
          units_complete "$STATE" || die "stage-done: stage-3 требует все Units [x] (enterprise — Units обязательны)"
          implementation_authority_current \
            || die "stage-done: stage-3 требует current воспроизводимый Implementation-Root + runner TDD receipts" ;;
        stage-4-quality)
          verdict_pass_strict "$STATE" || die "stage-done: stage-4 требует PASS с непустым evidence текущей попытки" ;;
      esac
    fi
    state_tx_begin
    mark_stage "$S" "x" "$STATE_TMP"
    if [ -n "$COLOR" ]; then set_conf "$S" "$CVAL" "$STATE_TMP"; fi
    upd_ts "$STATE_TMP"
    [ "$(stage_status "$STATE_TMP" "$S")" = x ] || die "stage-done: postcondition [x] не выполнен"
    state_tx_commit
    if [ -n "$COLOR" ]; then
      audit_row "confidence:$S" "level=$COLOR reason=${REASON:--}"
    fi
    if [ "$CUR" = "-" ]; then
      audit_row "$S:done"
    fi
    pair_tx_commit
    if [ -n "$COLOR" ]; then note "confidence recorded: $S $COLOR"; fi
    if [ "$CUR" = "-" ]; then
      note "$S → done"
    else
      note "stage-done: $S уже [x] — обновлён только confidence"
    fi
    ;;

  ack)
    arity 3 4 '<SPEC_DIR> <stage> [кто]'
    S="$3"; BY="${4:-owner}"
    valid_stage "$S" || die "ack: неизвестный этап (ожидаю: $STAGES)"
    if [ "$S" = stage-4-quality ]; then strict_git_context; fi
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    if [ "$S" = stage-4-quality ] && [ "$PROFILE" = v4-current ]; then captured_quality_guard mutation; fi
    [ "$(stage_status "$STATE" "$S")" = x ] || die "ack: $S должна быть завершена [x]"
    ACKLINE="$(grep -E "^- confidence-$S: " "$STATE" | head -1 || true)"
    [ -n "$ACKLINE" ] || die "ack: нет confidence-строки для $S — нечего подтверждать (сначала stage-done с цветом)"
    case "$ACKLINE" in *": —"*) die "ack: confidence $S = «—» (не задекларирован) — нечего подтверждать";; esac
    printf '%s' "$ACKLINE" | grep -qE "^- confidence-$S: (yellow|red)\b" \
      || die "ack: confidence $S не yellow|red — green/иное не блокирует, ack не нужен"
    if printf '%s' "$ACKLINE" | grep -qE ' · ack: '; then
      note "ack: $S уже подтверждён — no-op (идемпотентность, I-2)"
    else
      BY="$(sanitize "$BY")"
      state_tx_begin
      state_temp_transform confidence-ack "$S" " · ack: $BY ($TS)"
      upd_ts "$STATE_TMP"; state_tx_commit; audit_row "confidence-ack:$S" "by=$BY"; pair_tx_commit
      note "ack: $S подтверждён ($BY) — гейт снят"
    fi
    ;;

  gate)
    arity 3 3 '<SPEC_DIR> "MUST-FLAG: N · SHOULD-FLAG: N · NEEDS-INFO: N"'
    RES="$3"
    need_state
    validate_state_shape "$STATE" >/dev/null
    require_running stage-2-audit
    printf '%s' "$RES" | LC_ALL=C grep -Eq '^MUST-FLAG: [0-9]+ · SHOULD-FLAG: [0-9]+ · NEEDS-INFO: [0-9]+$' \
      || die "gate: ожидаю ровно canonical triple неотрицательных целых"
    state_tx_begin
    set_gate "constitution-gate" "$RES ($TS)" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit; audit_row "constitution-gate" "$RES"; pair_tx_commit
    note "constitution-gate: $RES"
    ;;

  review-start)
    arity 5 5 '<SPEC_DIR> <architecture|critical-code|performance> <attempt64> <actor>'
    ROLE="$3"; ATTEMPT="$4"; ACTOR="$5"
    case "$ROLE" in
      architecture)
        need_state; validate_state_shape "$STATE" >/dev/null
        require_running stage-2-audit
        SUBJECT="$(architecture_candidate_root)" || exit $? ;;
      critical-code|performance)
        need_state; validate_state_shape "$STATE" >/dev/null
        require_running stage-4-quality
        grep -Fqx -- '- Quality-HEAD: —' "$STATE" \
          || die "review-start: quality review после Quality-HEAD запрещён"
        grep -Fqx -- '- Evidence-Root: —' "$STATE" \
          || die "review-start: quality review после Evidence-Root запрещён"
        SUBJECT="$(quality_checkpoint_from_audit "$AUDIT")" || exit $? ;;
      *) die "review-start: unknown role" ;;
    esac
    DETAIL="$(perl "$RECEIPT_VERIFY" start-detail "$GIT_ROOT" "$SPEC_REL" \
      "$ROLE" "$ATTEMPT" "$ACTOR" "$SUBJECT")" \
      || die "review-start: receipt authority rejected"
    receipt_detail_validate start "$ROLE" "$ATTEMPT" "$ACTOR" "$SUBJECT" "$DETAIL" \
      || die "review-start: helper returned non-canonical detail"
    audit_row "review-start:$ROLE" "$DETAIL"
    pair_tx_commit
    note "review-start: $ROLE attempt=$ATTEMPT subject=$SUBJECT"
    ;;

  review-finish)
    arity 5 5 '<SPEC_DIR> <architecture|critical-code|performance> <attempt64> <artifact-rel.md>'
    ROLE="$3"; ATTEMPT="$4"; ARTIFACT="$5"
    case "$ROLE" in
      architecture) require_running stage-2-audit ;;
      critical-code|performance) require_running stage-4-quality ;;
      *) die "review-finish: unknown role" ;;
    esac
    DETAIL="$(perl "$RECEIPT_VERIFY" finish-detail "$GIT_ROOT" "$SPEC_REL" \
      "$ROLE" "$ATTEMPT" "$ARTIFACT")" \
      || die "review-finish: receipt authority rejected"
    receipt_detail_validate finish "$ROLE" "$ATTEMPT" "$ARTIFACT" - "$DETAIL" \
      || die "review-finish: helper returned non-canonical detail"
    audit_row "review-finish:$ROLE" "$DETAIL"
    pair_tx_commit
    note "review-finish: $ROLE attempt=$ATTEMPT"
    ;;

  review-blocked)
    arity 5 5 '<SPEC_DIR> <architecture|critical-code|performance> <attempt64> <unavailable|lost|invalid-output>'
    ROLE="$3"; ATTEMPT="$4"; REASON="$5"
    case "$ROLE" in
      architecture) require_running stage-2-audit ;;
      critical-code|performance) require_running stage-4-quality ;;
      *) die "review-blocked: unknown role" ;;
    esac
    DETAIL="$(perl "$RECEIPT_VERIFY" blocked-detail "$GIT_ROOT" "$SPEC_REL" \
      "$ROLE" "$ATTEMPT" "$REASON")" \
      || die "review-blocked: receipt authority rejected"
    receipt_detail_validate blocked "$ROLE" "$ATTEMPT" "$REASON" - "$DETAIL" \
      || die "review-blocked: helper returned non-canonical detail"
    audit_row "review-blocked:$ROLE" "$DETAIL"
    pair_tx_commit
    note "review-blocked: $ROLE attempt=$ATTEMPT reason=$REASON"
    ;;

  performance-run)
    arity 3 3 '<SPEC_DIR> <attempt64>'
    ATTEMPT="$3"
    printf '%s' "$ATTEMPT" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
      || die "performance-run: attempt должен быть 64hex"
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-4-quality
    grep -Fqx -- '- Quality-HEAD: —' "$STATE" \
      || die "performance-run: после Quality-HEAD execution запрещён"
    grep -Fqx -- '- Evidence-Root: —' "$STATE" \
      || die "performance-run: после Evidence-Root execution запрещён"
    C="$(quality_checkpoint_from_audit "$AUDIT")" || exit $?
    [ "$(head_commit_oid)" = "$C" ] \
      || die "performance-run: HEAD должен оставаться exact checkpoint C"
    [ -r "$PERFORMANCE_PROCESS" ] || die "performance-run: producer недоступен"
    mint_internal_git_context
    PERF_OUT="$(perl "$PERFORMANCE_PROCESS" run "$GIT_ROOT" "$SPEC_REL" \
      "$ATTEMPT" "$SPEC_REL/reviews/performance-review.md" "$C")" \
      || die "performance-run: trusted process producer rejected workload set"
    PERF_RECORD="$(printf '%s\n' "$PERF_OUT" | EXPECTED_ATTEMPT="$ATTEMPT" \
      EXPECTED_C="$C" EXPECTED_ARTIFACT="$SPEC_REL/reviews/performance-review.md" \
      perl -e '
        use strict; use warnings; local $/; my $v=<STDIN>//q{};
        my $a=$ENV{EXPECTED_ATTEMPT}//q{}; my $c=$ENV{EXPECTED_C}//q{};
        my $artifact=$ENV{EXPECTED_ARTIFACT}//q{};
        my $uint=qr/(?:0|[1-9][0-9]*)/; my $actor=qr/[A-Za-z0-9][A-Za-z0-9._:-]{0,127}/;
        my $oid=qr/(?:[0-9a-f]{40}|[0-9a-f]{64})/; my $root=qr/[0-9a-f]{64}/;
        $v =~ /\ARun-Start-Detail: (attempt=($root);generation=($uint);actor=($actor);subject=($oid);capability=performance-process-v1;workloads=($uint);manifest=($root);producer=($root))\nRun-Finish-Detail: (attempt=($root);generation=($uint);actor=($actor);subject=($oid);capability=performance-process-v1;workloads=($uint);manifest=($root);producer=($root);raw-samples=($root);artifact=([^;\r\n]+);sha256=($root))\nAudit-SHA256: ($root)\nRaw-Samples-SHA256: ($root)\nArtifact-SHA256: ($root)\n\z/ or exit 2;
        my ($start,$sa,$sg,$sx,$sc,$sn,$sm,$sp,$finish,$fa,$fg,$fx,$fc,$fn,$fm,$fp,
          $raw,$path,$sha,$audit,$raw_line,$sha_line)=($1,$2,$3,$4,$5,$6,$7,$8,$9,
            $10,$11,$12,$13,$14,$15,$16,$17,$18,$19,$20,$21,$22);
        exit 2 unless $sa eq $a && $sc eq $c && $sn > 0 && $sn <= 64 && $fa eq $sa && $fg eq $sg
          && $fx eq $sx && $fc eq $sc && $fn eq $sn && $fm eq $sm && $fp eq $sp
          && $path eq $artifact && $raw_line eq $raw && $sha_line eq $sha;
        print join("\t",$start,$finish,$audit);
      ')" || die "performance-run: producer output malformed"
    OLDIFS="$IFS"; IFS=$'\t'; set -- $PERF_RECORD; IFS="$OLDIFS"
    [ "$#" -eq 3 ] || die "performance-run: producer record framing malformed"
    RUN_START_DETAIL="$1"; RUN_FINISH_DETAIL="$2"; AUDIT_BASE_EXPECTED="$3"
    audit_row performance-run-start "$RUN_START_DETAIL"
    audit_row performance-run-finish "$RUN_FINISH_DETAIL"
    pair_tx_commit
    note "performance-run: complete manifest PASS; reserved lifecycle appended"
    ;;

  evidence-bind)
    arity 2 2 '<SPEC_DIR>'
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-4-quality
    grep -Fqx -- '- Quality-HEAD: —' "$STATE" \
      || die "evidence-bind: после Quality-HEAD binding запрещён"
    C="$(quality_checkpoint_from_audit "$AUDIT")" || exit $?
    [ "$(head_commit_oid)" = "$C" ] \
      || die "evidence-bind: HEAD должен оставаться exact checkpoint C"
    index_flags_standard || die "evidence-bind: index содержит assume-unchanged/skip-worktree flags"
    CURRENT_EROOT="$(sed -n 's/^- Evidence-Root: //p' "$STATE" | head -1)"
    EVIDENCE_BIND_TEST_PAUSE=0
    if [ "$CURRENT_EROOT" = "—" ] \
        && [ "${HARNESS_PIPELINE_EVIDENCE_BIND_TEST_PAUSE_AFTER_PAIR:-0}" = 1 ]; then
      # An ambient hook name alone is inert.  A writable inherited FD9 is the explicit test
      # synchronization capability; any later write failure remains best-effort and can never turn
      # a durable production mutation into a reported failure.
      if { : >&9; } 2>/dev/null; then EVIDENCE_BIND_TEST_PAUSE=1; fi
    fi
    unset HARNESS_PIPELINE_EVIDENCE_BIND_TEST_PAUSE_AFTER_PAIR 2>/dev/null || true
    if printf '%s' "$CURRENT_EROOT" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$'; then
      # `pair_tx_commit` is durable before the original command stages its new state/audit bytes.
      # A transient Git/index failure in that small post-commit window therefore resumes here:
      # validate the one retained canonical bind, stage only its metadata, and never append a
      # duplicate lifecycle row.  verify-bound remains the exact evidence/index authority.
      preboundary_state_ready "$STATE" \
        || die "evidence-bind: retained bound state is not a valid pre-H boundary"
      git add -- "$STATE" "$AUDIT" \
        || die "evidence-bind: retained bound state/audit не индексируются"
      stage4_untracked_paths_allowed \
        || die "evidence-bind: retained bind has forbidden untracked path"
      VERIFIED_ROOT="$(evidence_verify_bound_root "$C")" \
        || die "evidence-bind: retained bound Stage-4 evidence revalidation failed"
      [ "$VERIFIED_ROOT" = "$CURRENT_EROOT" ] \
        || die "evidence-bind: retained state/bound EvidenceRoot mismatch"
      note "evidence-bind: root=$CURRENT_EROOT; retained bind revalidated and staged"
    else
      [ "$CURRENT_EROOT" = "—" ] \
        || die "evidence-bind: Evidence-Root state malformed"
      git add -- "$STATE" "$AUDIT" \
        "$SPEC_REL/reviews/critical-code-review.md" \
        "$SPEC_REL/reviews/performance-review.md" \
        "$SPEC_REL/checklists/requirement-evidence.md" \
        || die "evidence-bind: mandatory evidence set не индексируется"
      stage4_untracked_paths_allowed \
        || die "evidence-bind: untracked path вне first-cycle mandatory evidence запрещён"
      EROOT="$(evidence_candidate_root "$C")" \
        || die "evidence-bind: exact Stage-4 evidence candidate rejected"
      state_tx_begin
      set_root Evidence-Root "$EROOT" "$STATE_TMP"
      upd_ts "$STATE_TMP"; state_tx_commit
      audit_row evidence-bind "checkpoint=$C;root=$EROOT"
      pair_tx_commit
      if [ "$EVIDENCE_BIND_TEST_PAUSE" -eq 1 ]; then
        if { printf 'pid=%s\n' "$$" >&9; } 2>/dev/null; then
          kill -STOP "$$" 2>/dev/null || true
        fi
      fi
      git add -- "$STATE" "$AUDIT" \
        || die "evidence-bind: bound state/audit не индексируются"
      VERIFIED_ROOT="$(evidence_verify_bound_root "$C")" \
        || die "evidence-bind: bound Stage-4 evidence revalidation failed"
      [ "$VERIFIED_ROOT" = "$EROOT" ] \
        || die "evidence-bind: candidate/bound EvidenceRoot mismatch"
      note "evidence-bind: root=$EROOT; exact Stage-4 set staged"
    fi
    ;;

  design-bind)
    arity 2 2 '<SPEC_DIR>'
    need_state
    validate_state_shape "$STATE" >/dev/null
    require_running stage-2-audit
    RECORD="$(architecture_verify_record unbound)" || die "design-bind: architecture/review authority rejected"
    OLDIFS="$IFS"; IFS='|'; set -- $RECORD; IFS="$OLDIFS"
    [ "$#" -eq 6 ] || die "design-bind: internal verify record malformed"
    DROOT="$1"; RATTEMPT="$2"; RGENERATION="$3"; RACTOR="$4"; RSHA="$5"; AUDIT_BASE_EXPECTED="$6"
    DETAIL="root=$DROOT;attempt=$RATTEMPT;generation=$RGENERATION;actor=$RACTOR;sha256=$RSHA"
    CURRENT_DROOT="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
    if [ "$CURRENT_DROOT" = "$DROOT" ] && design_authority_current; then
      AUDIT_BASE_EXPECTED=""
      note "design-bind: Design-Root=$DROOT уже current — no-op"
      exit 0
    fi
    state_tx_begin
    set_root Design-Root "$DROOT" "$STATE_TMP"
    set_gate user-approval "—" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit
    audit_row "design-bind" "$DETAIL"
    pair_tx_commit
    design_authority_current || die "design-bind: postcondition authority не подтверждён"
    note "design-bind: Design-Root=$DROOT"
    ;;

  implementation-start)
    arity 5 5 '<SPEC_DIR> <base-GitOid> <attempt64> <actor>'
    BASE="$3"; ATTEMPT="$4"; ACTOR="$5"
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-3-dev
    valid_full_oid "$BASE" || die "implementation-start: base должен быть canonical full GitOid"
    printf '%s' "$ATTEMPT" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
      || die "implementation-start: attempt должен быть 64hex"
    printf '%s' "$ACTOR" | LC_ALL=C grep -Eq '^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$' \
      || die "implementation-start: actor malformed"
    [ "$(git rev-parse --verify "$BASE^{commit}" 2>/dev/null || true)" = "$BASE" ] \
      || die "implementation-start: base не exact commit"
    [ "$(head_commit_oid)" = "$BASE" ] \
      || die "implementation-start: base должен совпадать с текущим HEAD R"
    design_authority_current \
      || die "implementation-start: Design-Root/review authority отсутствует или устарела"
    approval_ready "$STATE" \
      || die "implementation-start: user approval не связывает current Design-Root"
    [ "$(sed -n 's/^- Implementation-Root: //p' "$STATE" | head -1)" = "—" ] \
      || die "implementation-start: Implementation-Root уже связан; re-open Stage 3 для новой попытки"
    GENERATION="$(receipt_generation current)" \
      || die "implementation-start: receipt generation malformed"
    DESIGN="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
    EXPECTED="$ATTEMPT|$GENERATION|$ACTOR|$DESIGN|$BASE"
    if ACTIVE="$(implementation_lifecycle_selector start)"; then
      [ "$ACTIVE" = "$EXPECTED" ] \
        || die "implementation-start: другая implementation lifecycle уже active"
      INIT_CREATED="$(implementation_artifacts_batch init)" \
        || die "implementation-start: atomic canonical artifact initialization rejected"
      INIT_TXN="$(implementation_init_token "$INIT_CREATED")" \
        || die "implementation-start: initializer transaction token malformed"
      if ! stage_implementation_start_paths "$INIT_CREATED"; then
        preserve_implementation_start_paths "$INIT_CREATED" \
          || die "implementation-start: created-path staging rejected; transaction token malformed"
        die "implementation-start: created-path staging/index verification rejected; transaction retained for retry/reconcile"
      fi
      implementation_artifacts_batch finalize "$INIT_TXN" \
        || die "implementation-start: initializer finalize не подтверждён; retry reconciles"
      git add -- "$STATE" "$AUDIT" \
        || die "implementation-start: retained lifecycle state/audit не индексируются"
      note "implementation-start: attempt=$ATTEMPT уже current — no-op"
      exit 0
    else
      SELECTOR_RC=$?
      [ "$SELECTOR_RC" -eq 1 ] \
        || die "implementation-start: retained lifecycle audit malformed"
    fi
    INIT_CREATED="$(implementation_artifacts_batch init)" \
      || die "implementation-start: atomic canonical artifact initialization rejected"
    INIT_TXN="$(implementation_init_token "$INIT_CREATED")" \
      || die "implementation-start: initializer transaction token malformed"
    if ! stage_implementation_start_paths "$INIT_CREATED"; then
      preserve_implementation_start_paths "$INIT_CREATED" \
        || die "implementation-start: created-path staging rejected; transaction token malformed"
      die "implementation-start: created-path staging/index verification rejected; transaction retained for retry/reconcile"
    fi
    DETAIL="attempt=$ATTEMPT;generation=$GENERATION;actor=$ACTOR;subject=$DESIGN;capability=implementation-v1;base=$BASE"
    audit_row "implementation-start" "$DETAIL"
    pair_tx_commit
    implementation_artifacts_batch finalize "$INIT_TXN" \
      || die "implementation-start: initializer finalize не подтверждён; retry reconciles"
    git add -- "$STATE" "$AUDIT" \
      || die "implementation-start: state/audit не staged после durable append"
    [ "$(implementation_lifecycle_selector start)" = "$EXPECTED" ] \
      || die "implementation-start: postcondition lifecycle не подтверждён"
    note "implementation-start: attempt=$ATTEMPT base=$BASE"
    ;;

  implementation-content-root)
    arity 4 4 '<SPEC_DIR> <base-GitOid> <implementation-attempt64>'
    BASE="$3"; ATTEMPT="$4"
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-3-dev
    valid_full_oid "$BASE" || die "implementation-content-root: base malformed"
    printf '%s' "$ATTEMPT" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
      || die "implementation-content-root: attempt malformed"
    ACTIVE="$(implementation_lifecycle_selector start)" \
      || die "implementation-content-root: current implementation-start absent/malformed"
    OLDIFS="$IFS"; IFS='|'; set -- $ACTIVE; IFS="$OLDIFS"
    [ "$#" -eq 5 ] && [ "$1" = "$ATTEMPT" ] && [ "$5" = "$BASE" ] \
      || die "implementation-content-root: attempt/base mismatch"
    DESIGN="$4"
    mint_internal_git_context
    CONTENT_ROOT="$(perl "$IMPLEMENTATION_VERIFY" content-candidate "$GIT_ROOT" \
      "$SPEC_REL" "$BASE" "$DESIGN" "$ATTEMPT")" \
      || die "implementation-content-root: candidate authority rejected"
    printf '%s' "$CONTENT_ROOT" | LC_ALL=C grep -Eq '^[0-9a-f]{64}$' \
      || die "implementation-content-root: helper output malformed"
    note "TDD-Content-Root: $CONTENT_ROOT"
    ;;

  tdd-run)
    [ "$ARGC" -ge 11 ] \
      || die 'tdd-run: ожидаю <SPEC_DIR> <base-GitOid> <implementation-attempt64> <run64> <primary-TestId> <red|green|adjacent> <executed-TestId> <actor> -- <argv...>'
    BASE="$3"; ATTEMPT="$4"; RUN="$5"; TEST_ID="$6"; PHASE="$7"; EXECUTED_ID="$8"; ACTOR="$9"
    [ "${10}" = -- ] || die "tdd-run: требуется exact -- перед argv"
    shift 10
    [ "$#" -gt 0 ] || die "tdd-run: executable argv absent"
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-3-dev
    valid_full_oid "$BASE" || die "tdd-run: base malformed"
    printf '%s' "$ATTEMPT$RUN" | LC_ALL=C grep -Eq '^[0-9a-f]{128}$' \
      || die "tdd-run: implementation/run attempts malformed"
    case "$PHASE" in red|green|adjacent) ;; *) die "tdd-run: phase malformed" ;; esac
    ACTIVE="$(implementation_lifecycle_selector start)" \
      || die "tdd-run: current implementation-start absent/malformed"
    implementation_artifacts_batch verify \
      || die "tdd-run: canonical Stage-3 artifact batch absent, partial or unsafe; rerun implementation-start"
    OLDIFS="$IFS"; IFS='|' read -r ACTIVE_ATTEMPT ACTIVE_GENERATION ACTIVE_ACTOR ACTIVE_DESIGN ACTIVE_BASE <<EOF
$ACTIVE
EOF
    IFS="$OLDIFS"
    [ -n "$ACTIVE_BASE" ] || die "tdd-run: lifecycle selector malformed"
    [ "$ACTIVE_GENERATION" -lt 2147483647 ] \
      || die "tdd-run: receipt generation exhausted; failure recovery cannot be guaranteed"
    [ "$ACTIVE_ATTEMPT" = "$ATTEMPT" ] && [ "$ACTIVE_ACTOR" = "$ACTOR" ] && [ "$ACTIVE_BASE" = "$BASE" ] \
      || die "tdd-run: caller identity/base mismatches implementation-start"
    [ "$ACTIVE_DESIGN" = "$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)" ] \
      || die "tdd-run: current Design-Root differs from implementation-start"
    mint_internal_git_context
    TDD_OUTPUT="$(perl "$TDD_RECEIPT" run "$GIT_ROOT" "$SPEC_REL" \
      "$TEST_ID" "$PHASE" "$EXECUTED_ID" "$RUN" "$ATTEMPT" "$ACTOR" -- "$@")" \
      || die "tdd-run: trusted process execution rejected"
    TDD_RECORD="$(printf '%s\n' "$TDD_OUTPUT" | TEST="$TEST_ID" PHASE="$PHASE" EXECUTED="$EXECUTED_ID" perl -e '
      use strict; use warnings; local $/; my $v=<STDIN>//q{};
      $v=~/\AStart-Detail: ([^|\r\n]+)\nFinish-Detail: ([^|\r\n]+)\nAudit-SHA256: ([0-9a-f]{64})\nAccepted: (yes|no)\n\z/ or exit 2;
      my ($start,$finish,$audit,$accepted)=($1,$2,$3,$4);
      $start=~/\Atest=\Q$ENV{TEST}\E;phase=\Q$ENV{PHASE}\E;executed=\Q$ENV{EXECUTED}\E;/ or exit 2;
      index($finish,$start.q{;})==0 or exit 2;
      print join(q{|},$start,$finish,$audit,$accepted);
    ')" || die "tdd-run: helper output malformed"
    OLDIFS="$IFS"; IFS='|'; set -- $TDD_RECORD; IFS="$OLDIFS"
    [ "$#" -eq 4 ] || die "tdd-run: parsed receipt record malformed"
    START_DETAIL="$1"; FINISH_DETAIL="$2"; AUDIT_BASE_EXPECTED="$3"; ACCEPTED="$4"
    audit_row "tdd-run-start:$PHASE" "$START_DETAIL"
    audit_row "tdd-run-finish:$PHASE" "$FINISH_DETAIL"
    if [ "$ACCEPTED" = no ]; then
      NEXT_GENERATION=$((ACTIVE_GENERATION + 1))
      # A rejected trusted receipt invalidates the whole implementation authority, including an
      # already-bound root. Keep Stage 3 running so the next generation can start immediately;
      # downstream state and completed units must not survive bytes proven stale by this receipt.
      state_tx_begin
      invalidate_from "$STATE_TMP" stage-3-dev
      mark_stage stage-3-dev "-" "$STATE_TMP"
      upd_ts "$STATE_TMP"; state_tx_commit
      audit_row receipt-invalidate \
        "generation=$NEXT_GENERATION;scopes=implementation,quality,evidence"
    fi
    pair_tx_commit
    git add -- "$STATE" "$AUDIT" || die "tdd-run: state/audit receipt не staged после durable append"
    [ "$ACCEPTED" = yes ] \
      || die "tdd-run: process receipt записан и lifecycle invalidated; начни новую implementation attempt"
    note "tdd-run: $TEST_ID/$PHASE accepted run=$RUN"
    ;;

  implementation-bind)
    arity 4 4 '<SPEC_DIR> <base-GitOid> <attempt64>'
    BASE="$3"; ATTEMPT="$4"
    need_state; validate_state_shape "$STATE" >/dev/null
    require_running stage-3-dev
    valid_full_oid "$BASE" || die "implementation-bind: base malformed"
    ACTIVE="$(implementation_lifecycle_selector start)" \
      || die "implementation-bind: current implementation-start absent/malformed"
    OLDIFS="$IFS"; IFS='|'; set -- $ACTIVE; IFS="$OLDIFS"
    [ "$#" -eq 5 ] || die "implementation-bind: lifecycle selector malformed"
    [ "$1" = "$ATTEMPT" ] && [ "$5" = "$BASE" ] \
      || die "implementation-bind: attempt/base mismatch"
    GENERATION="$2"; ACTOR="$3"; DESIGN="$4"
    RECORD="$(implementation_verify_record "$BASE" "$DESIGN" "$ATTEMPT")" \
      || die "implementation-bind: Implementation/TDD authority rejected"
    OLDIFS="$IFS"; IFS='|'; set -- $RECORD; IFS="$OLDIFS"
    [ "$#" -eq 7 ] || die "implementation-bind: verify record malformed"
    IROOT="$1"; VBASE="$2"; VDESIGN="$3"; VATtempt="$4"; VGENERATION="$5"; VACTOR="$6"; AUDIT_BASE_EXPECTED="$7"
    [ "$VBASE|$VDESIGN|$VATtempt|$VGENERATION|$VACTOR" = "$BASE|$DESIGN|$ATTEMPT|$GENERATION|$ACTOR" ] \
      || die "implementation-bind: verifier identity mismatches lifecycle"
    CURRENT_IROOT="$(sed -n 's/^- Implementation-Root: //p' "$STATE" | head -1)"
    if [ "$CURRENT_IROOT" = "$IROOT" ] && implementation_authority_current; then
      AUDIT_BASE_EXPECTED=""
      note "implementation-bind: Implementation-Root=$IROOT уже current — no-op"
      exit 0
    fi
    [ "$CURRENT_IROOT" = "—" ] \
      || die "implementation-bind: state содержит другой Implementation-Root"
    DETAIL="root=$IROOT;base=$BASE;design=$DESIGN;attempt=$ATTEMPT;generation=$GENERATION;actor=$ACTOR"
    state_tx_begin
    set_root Implementation-Root "$IROOT" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit
    audit_row "implementation-bind" "$DETAIL"
    pair_tx_commit
    git add -- "$STATE" "$AUDIT" \
      || die "implementation-bind: state/audit не staged после durable bind"
    implementation_authority_current \
      || die "implementation-bind: postcondition authority не подтверждён"
    note "implementation-bind: Implementation-Root=$IROOT"
    ;;

  sdd-append|delivery-append)
    if [ "$CMD" = sdd-append ]; then
      arity 5 5 '<SPEC_DIR> <revision> <change> <reason>'
      CHANGELOG_KIND=sdd; CHANGELOG_EVENT=sdd-append; require_running stage-2-audit
    else
      arity 5 5 '<SPEC_DIR> <revision> <result> <evidence>'
      CHANGELOG_KIND=delivery; CHANGELOG_EVENT=delivery-append; require_running stage-3-dev
    fi
    REVISION="$3"; CHANGELOG_VALUE1="$4"; CHANGELOG_VALUE2="$5"
    CHANGELOG_RESULT="$(perl "$CHANGELOG_APPEND" "$CHANGELOG_KIND" "$GIT_ROOT" "$SPEC_REL" \
      "$REVISION" "$CHANGELOG_VALUE1" "$CHANGELOG_VALUE2")" \
      || die "$CMD: canonical append rejected"
    printf '%s' "$CHANGELOG_RESULT" | LC_ALL=C \
      grep -Eq '^(appended|existing) sha256=[0-9a-f]{64}$' \
      || die "$CMD: changelog helper output malformed"
    CHANGELOG_SHA="${CHANGELOG_RESULT##*sha256=}"
    CHANGELOG_DETAIL="revision=$REVISION;sha256=$CHANGELOG_SHA"
    if grep -Fq "| $CHANGELOG_EVENT | $CHANGELOG_DETAIL |" "$AUDIT"; then
      note "$CMD: revision=$REVISION уже recorded — no-op"
      exit 0
    fi
    audit_row "$CHANGELOG_EVENT" "$CHANGELOG_DETAIL"
    pair_tx_commit
    note "$CMD: revision=$REVISION"
    ;;

  approve)
    arity 3 4 '<SPEC_DIR> <approved|revise|abort> [кто]'
    V="$3"; BY="${4:-owner}"
    case "$V" in approved|revise|abort) ;; *) die "approve: ожидаю approved|revise|abort";; esac
    need_state
    validate_state_shape "$STATE" >/dev/null
    require_running stage-2-audit
    if [ "$V" = "approved" ]; then
      gate_ready_strict "$STATE" \
        || die "approve=approved запрещён: нужны MUST-FLAG: 0 и NEEDS-INFO: 0 canonical gate"
      design_authority_current \
        || die "approve=approved запрещён: Design-Root/review authority отсутствует или устарела"
    fi
    BY="$(sanitize "$BY")"
    # #4055: `revise` means the owner sent this candidate back, so the design authority computed
    # for it — including any already-closed architecture receipt — must stop being current.  The
    # stage-2 contract already says a revised candidate "проходит новый independent receipt/bind/
    # approval", but nothing advanced the receipt generation, and receipt-v1 locks a role for the
    # whole generation once its lifecycle terminates (receipt-v1.pl:317-321, unlocked only by
    # `blocked`).  The result was a dead end: an honest FAIL recorded via review-finish made every
    # further independent round impossible, which is exactly how specs 339 and 341 got stuck.
    # Closing a real FAIL as `blocked` would be a lie — `blocked` means the review never produced
    # a verdict (unavailable/lost/invalid-output).  So the generation advances here, where the
    # owner's own decision justifies it.
    REVISE_GENERATION=""
    if [ "$V" = revise ]; then
      REVISE_GENERATION="$(receipt_generation next)" \
        || die "approve: receipt generation audit malformed/exhausted"
    fi
    state_tx_begin
    if [ "$V" = approved ]; then
      DROOT="$(sed -n 's/^- Design-Root: //p' "$STATE" | head -1)"
      set_gate "user-approval" "approved design=$DROOT ($TS, $BY)" "$STATE_TMP"
      APPROVAL_AUDIT="approved design=$DROOT by $BY"
    else
      set_gate "user-approval" "$V ($TS, $BY)" "$STATE_TMP"
      APPROVAL_AUDIT="$V by $BY"
    fi
    if [ "$V" = revise ]; then
      set_root Design-Root "—" "$STATE_TMP"
      set_root Implementation-Root "—" "$STATE_TMP"
      set_root Evidence-Root "—" "$STATE_TMP"
    fi
    upd_ts "$STATE_TMP"; state_tx_commit; audit_row "user-approval" "$APPROVAL_AUDIT"
    if [ -n "$REVISE_GENERATION" ]; then
      audit_row "receipt-invalidate" \
        "generation=$REVISE_GENERATION;scopes=architecture,implementation,quality,evidence"
    fi
    pair_tx_commit
    note "user-approval: $V"
    ;;

  verdict)
    arity 3 4 '<SPEC_DIR> <PASS|FAIL> [detail]'
    V="$3"; DET="${4:-}"
    case "$V" in PASS|FAIL) ;; *) die "verdict: ожидаю PASS|FAIL";; esac
    strict_git_context
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    [ "$PROFILE" = v4-current ] || die "verdict: требуется V4 current boundary"
    require_running stage-4-quality
    grep -Fqx -- '- quality-verdict: —' "$STATE" \
      || die "verdict: current S4/H уже имеет verdict — PASS/FAIL single-shot; re-open Stage 3 для fresh quality boundary"
    QH="$(sed -n 's/^- Quality-HEAD: //p' "$STATE" | head -1)"
    if [ "$V" = FAIL ] && [ "$QH" = "—" ]; then
      # A reviewer must be able to record the finding before evidence commit H exists.  This path
      # is intentionally FAIL-only: the resulting non-pending verdict makes quality-head and bind
      # impossible, while re-opening Stage 3 resets it through the ordinary invalidation contract.
      FAIL_CHECKPOINT="$(quality_checkpoint_from_audit "$AUDIT")" || exit $?
      valid_full_oid "$FAIL_CHECKPOINT" \
        && [ "$(git cat-file -t "$FAIL_CHECKPOINT" 2>/dev/null || true)" = commit ] \
        || die "verdict FAIL pre-H: current S4 checkpoint C отсутствует или не commit"
      FAIL_HEAD="$(head_commit_oid)"
      git merge-base --is-ancestor "$FAIL_CHECKPOINT" "$FAIL_HEAD" 2>/dev/null \
        || die "verdict FAIL pre-H: current HEAD не descendant Stage-3 checkpoint C"
    else
      # PASS is never accepted before captured H.  A post-H FAIL uses the same immutable guard as
      # PASS so no HEAD/path/state substitution can be hidden by changing the verdict to red.
      captured_quality_guard mutation || exit $?
    fi
    DET="$(sanitize "$DET")"
    # Честность (I-13): PASS обязан нести evidence — иначе «зелёный со слов»;
    # FAIL самодостаточен как красный сигнал (detail опционален).
    if [ "$V" = "PASS" ] && ! printf '%s' "$DET" | grep -q '[^[:space:]]'; then
      die "verdict PASS требует detail-evidence 4-м аргументом (напр. \"620/0 + перечень проверенного\") — PASS без доказательства запрещён (I-13); FAIL detail опционален"
    fi
    state_tx_begin
    set_gate "quality-verdict" "$V${DET:+ — $DET} ($TS)" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit; audit_row "quality-verdict" "$V${DET:+ — $DET}"; pair_tx_commit
    note "quality-verdict: $V"
    ;;

  quality-head)
    arity 2 2 '<SPEC_DIR>'
    strict_git_context
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    [ "$PROFILE" = v4-current ] || die "quality-head: требуется V4 current"
    require_running stage-4-quality
    H="$(head_commit_oid)"
    QH="$(sed -n 's/^- Quality-HEAD: //p' "$STATE" | head -1)"
    if [ "$QH" = "$H" ]; then
      captured_quality_guard pending || exit $?
      note "quality-head: $H уже зафиксирован — no-op (идемпотентность)"
      exit 0
    fi
    [ "$QH" = "—" ] || die "quality-head: anchor уже содержит иной commit — re-open Stage 3"
    strict_clean_checkpoint || exit $?
    [ "$STRICT_CHECKPOINT_HEAD" = "$H" ] \
      || die "quality-head: HEAD изменился во время clean checkpoint validation"
    preboundary_state_ready "$STATE" \
      || die "quality-head: нужен canonical V4 boundary (bound roots, S1–S3 done, S4 running, pending verdict/confidence/QH)"
    design_authority_current \
      || die "quality-head: Design-Root/review authority устарела"
    implementation_authority_frozen \
      || die "quality-head: retained Implementation-Root/TDD authority отсутствует"
    # All fallible C→H checks run before the first state/audit mutation.  This keeps a malformed
    # checkpoint event, forbidden Stage-4 path, rewritten upstream state or audit prefix atomic.
    validate_quality_candidate_boundary "$H" || exit $?
    state_tx_begin
    set_quality_head "$H" "$STATE_TMP"
    upd_ts "$STATE_TMP"; state_tx_commit
    audit_row "quality-head" "$H"
    pair_tx_commit
    captured_quality_guard pending || exit $?
    note "quality-head: candidate H=$H зафиксирован; HEAD менять запрещено"
    ;;

  bind-head)
    arity 2 2 '<SPEC_DIR>'
    strict_git_context
    need_state
    TUPLE="$(bound_authority envelope)" || exit $?
    # Re-read every immutable/live predicate immediately before the only mutation (CAS ref).
    TUPLE2="$(bound_authority envelope)" || exit $?
    [ "$TUPLE2" = "$TUPLE" ] || die "bind-head: authority изменилась между проверками"
    OLDIFS="$IFS"; IFS='|'; set -- $TUPLE; IFS="$OLDIFS"
    [ "$#" -eq 3 ] || die "bind-head: internal envelope tuple malformed"
    B="$1"; H="$2"; BINDING_REF="$3"
    if EXISTING="$(direct_binding_ref_oid "$BINDING_REF")"; then
      [ "$EXISTING" = "$B" ] || die "bind-head: H уже связан с другим B в этом worktree"
      note "bind-head: binding H→B уже существует — no-op (идемпотентность)"
      exit 0
    else
      REF_RC=$?
      [ "$REF_RC" -eq 1 ] \
        || die "bind-head: существующий binding ref symbolic/malformed; CAS запрещён"
    fi
    case "${#B}" in
      40) ZERO_OID="0000000000000000000000000000000000000000" ;;
      64) ZERO_OID="0000000000000000000000000000000000000000000000000000000000000000" ;;
      *) die "bind-head: unexpected B OID length" ;;
    esac
    if ! git update-ref --no-deref "$BINDING_REF" "$B" "$ZERO_OID" 2>/dev/null; then
      if EXISTING="$(direct_binding_ref_oid "$BINDING_REF")"; then
        [ "$EXISTING" = "$B" ] \
          || die "bind-head: CAS conflict — direct binding ref не равен B"
      else
        die "bind-head: CAS conflict — ref отсутствует либо symbolic/malformed"
      fi
    fi
    POST_BINDING="$(direct_binding_ref_oid "$BINDING_REF")" \
      || die "bind-head: CAS postcondition не создал direct commit ref"
    [ "$POST_BINDING" = "$B" ] || die "bind-head: CAS postcondition не равен B"
    note "bind-head OK: exact H=$H → B=$B (per-worktree authority)"
    ;;

  event)
    arity 3 4 '<SPEC_DIR> <event> [detail]'
    EV="$(sanitize "$3")"; DET="$(sanitize "${4:-}")"
    need_state
    PROFILE="$(validate_state_shape "$STATE")"
    if [ "$PROFILE" = v4-current ]; then
      QH="$(sed -n 's/^- Quality-HEAD: //p' "$STATE" | head -1)"
      EROOT="$(sed -n 's/^- Evidence-Root: //p' "$STATE" | head -1)"
      [ "$QH" = "—" ] && [ "$EROOT" = "—" ] \
        || die "event: generic telemetry после Evidence-Root/Quality-HEAD запрещена; strict lifecycle уже заморожен"
      [ "$(stage_status "$STATE" stage-4-quality)" != "-" ] \
        || die "event: generic telemetry внутри strict Stage 4 запрещена; используй typed review/performance/evidence commands"
    fi
    generic_event_field_safe "$EV" && generic_event_field_safe "$DET" \
      || die "event: reserved strict authority token; используй штатную state transition command"
    audit_row "$EV" "$DET"
    pair_tx_commit
    note "event: $EV"
    ;;

  validate-state)
    arity 2 2 '<SPEC_DIR>'
    need_state
    validate_state_shape "$STATE" >/dev/null
    note "validate-state OK: $STATE"
    ;;

  publish-base)
    arity 3 3 '<SPEC_DIR> <pinned-remote-oid>'
    strict_git_context
    need_state
    validate_state_shape "$STATE" >/dev/null
    validate_outbound_base "$3" >/dev/null
    note "publish-base OK: exact public graph R→C→H→B"
    ;;

  check)
    arity 3 3 '<SPEC_DIR> <stage|publish>'
    check_transition "$3"
    ;;

  status)
    arity 2 2 '<SPEC_DIR>'
    show_status
    ;;

  *) die "неизвестная команда" ;;
esac
