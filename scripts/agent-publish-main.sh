#!/usr/bin/env bash
# agent-publish-main.sh — единственный канал публикации (устав I-10). Три режима:
#
#   1. PR-режим (по умолчанию на feature-ветке): clean-tree → fetch → rebase на свежую вершину
#      <remote>/<branch> → `scripts/check.sh` (пропуск только AGENT_PUBLISH_SKIP_TESTS=1) →
#      `git push --force-with-lease -u` ветки → подсказка открыть PR (`gh pr create --fill`, если
#      origin — GitHub). Целевая ветка не трогается; merge жмёт человек. DORA: `publish:pr`.
#   2. Прямая публикация (текущая ветка = целевой, либо явно AGENT_PUBLISH_MODE=main) — для solo-
#      проектов: lease-гейт (ДО trap: отказ не пишет ложный publish:failed) → dirty-guard → EXIT-trap
#      DORA → retry-цикл ≤3: свежий fetch каждой итерации → rebase при дивергенции (конфликт →
#      авто-abort + честный die) → повторный lease-чек (под trap — легитимный publish:failed) → push →
#      verify-after-push (ls-remote, не ослабляется). Гонка на push → stderr `retry N/3 (diverged)` +
#      best-effort publish:retry → бэкофф → следующая итерация; исчерпание → честный die.
#   3. Strict exact-OID (PIPELINE_SPEC_DIR — pipeline binding R→C→H→B, или AGENT_PUBLISH_EXPECT_HEAD):
#      immutable single attempt без rebase/autocommit/retry, с повторной binding-проверкой и
#      literal-OID refspec; mismatch → REVALIDATION_REQUIRED (exit 3) без push.
# Все сетевые git-вызовы режимов 2–3 — в bounded owned session/process-group: зависшая сеть и
# same-session descendants завершаются TERM→KILL, а escaped pipe holder не может удержать capture.
#
# DORA-события (docs/ops-journal.md через scripts/ops-log.sh): publish:done | publish:failed |
# publish:noop | publish:retry | publish:pr. Это НЕ deploy:* — деплой пишет деплой-скрипт проекта;
# dora-metrics.sh считает поставку по publish:done только если deploy:* в журнале нет вовсе.
#
# Usage: bash scripts/agent-publish-main.sh [remote] [branch]      # дефолт: origin main
# Exit:  0 = опубликовано / noop · 1 = отказ или сбой · 3 = REVALIDATION_REQUIRED (exact-режим)
#
# ENV:
#   AGENT_PUBLISH_MODE          pr | main (дефолт: pr на feature-ветке, main на целевой ветке)
#   AGENT_PUBLISH_SKIP_TESTS    =1 — PR-режим без scripts/check.sh (только осознанно, с WARN)
#   AGENT_PUBLISH_NET_TIMEOUT   таймаут сетевых git-вызовов, сек (дефолт 30; 0 = без таймаута)
#   AGENT_PUBLISH_BACKOFF_BASE  база бэкоффа retry: sleep BASE*N сек (дефолт 2; тесты ставят 0)
#   PIPELINE_SPEC_DIR           strict V4 pipeline binding; publish exact bound HEAD
#   AGENT_PUBLISH_EXPECT_HEAD   strict generic exact commit OID (40/64 lowercase hex)
#   AGENT_PUBLISH_SOURCE_ONLY   =1 при source: только определения функций (юнит-тесты)
#   HARNESS_PRIVATE_TMP_TEST_PAUSE   =1: STOP после temp allocation; network-config: после Gitdir seal;
#                               оба значения только для causal fixtures и требуют FD 9
set -euo pipefail
set -euo pipefail

# SELF_DIR is derived without Git. Production snapshots only the narrowly allowlisted global
# credential capability before the Git authority scrub, but that first Git process itself runs
# under env -i: caller trace/config/transport selectors never execute or receive credential bytes.
# Source-only unit mode has no authentication side effect.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
PRIVATE_TMP_HELPER="$SELF_DIR/private-temp-dir.pl"
# Close every caller-owned descriptor before any Git/local authority probe. Causal fixtures retain
# only their explicit control FD9; source-only mode stays inert for definition-level unit tests.
# Never trust an ambient "already clean" marker: decide from the kernel FD view on every process
# entry. The detector excludes only its own directory handle, so a forged environment name cannot
# suppress the descriptor-closing re-exec.
export -n AGENT_PUBLISH_FD_CLEAN 2>/dev/null || true
unset AGENT_PUBLISH_FD_CLEAN
if [ -z "${AGENT_PUBLISH_SOURCE_ONLY:-}" ]; then
  publish_keep_fds=-
  case "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" in 1|network-config) publish_keep_fds=9;; esac
  publish_extra_fd_rc=0
  PUBLISH_KEEP_FDS="$publish_keep_fds" perl -MPOSIX -e '
    use strict; use warnings;
    my %keep=(0=>1,1=>1,2=>1);
    if (($ENV{PUBLISH_KEEP_FDS}//q{-}) ne q{-}) {
      for my $fd (split /,/, $ENV{PUBLISH_KEEP_FDS}, -1) {
        exit 2 unless $fd =~ /\A[0-9]+\z/ && $fd > 2;
        $keep{$fd}=1;
      }
    }
    for my $root (q{/dev/fd},q{/proc/self/fd}) {
      next unless opendir(my $fds,$root);
      my $own=fileno($fds); my $extra=0;
      while (defined(my $fd=readdir($fds))) {
        next unless $fd =~ /\A[0-9]+\z/ && $fd > 2;
        $extra=1 if $fd != $own && !$keep{$fd};
      }
      closedir($fds) or exit 2; exit($extra ? 0 : 1);
    }
    exit 2;
  ' || publish_extra_fd_rc=$?
  case "$publish_extra_fd_rc" in
    0) exec perl "$PRIVATE_TMP_HELPER" fd-exec "$publish_keep_fds" -- \
         bash "$SELF_DIR/agent-publish-main.sh" "$@";;
    1) ;;
    *) printf 'agent-publish-main: caller FD boundary unavailable\n' >&2; exit 1;;
  esac
  unset publish_extra_fd_rc publish_keep_fds
fi
# An imported exported shell variable keeps its export attribute across a plain assignment. Remove
# both value and attribute before credential bytes ever enter this process; no child may receive the
# snapshot name or hex payload through its environment.
export -n PUBLISH_CREDENTIAL_CONFIG_HEX 2>/dev/null || true
unset PUBLISH_CREDENTIAL_CONFIG_HEX
export -n auth_hex 2>/dev/null || true
unset auth_hex
PUBLISH_CREDENTIAL_CONFIG_HEX=""
export -n PUBLISH_CREDENTIAL_CONFIG_HEX 2>/dev/null || true
if [ -z "${AGENT_PUBLISH_SOURCE_ONLY:-}" ]; then
  PUBLISH_SNAPSHOT_PATH="${PATH:-/usr/bin:/bin}"
  PUBLISH_SNAPSHOT_HOME="${HOME:-/}"
  PUBLISH_SNAPSHOT_LANG="${LANG:-C}"
  credential_snapshot_git() {
    local rc=0
    if [ "${XDG_CONFIG_HOME+x}" = x ]; then
      env -i PATH="$PUBLISH_SNAPSHOT_PATH" HOME="$PUBLISH_SNAPSHOT_HOME" \
        XDG_CONFIG_HOME="$XDG_CONFIG_HOME" LANG="$PUBLISH_SNAPSHOT_LANG" LC_ALL=C \
        GIT_CONFIG_COUNT=0 GIT_CONFIG_NOSYSTEM=1 \
        perl "$PRIVATE_TMP_HELPER" fd-exec - -- \
          git config --global --no-includes --null --get-regexp '^credential\.' \
        2>/dev/null || rc=$?
    else
      env -i PATH="$PUBLISH_SNAPSHOT_PATH" HOME="$PUBLISH_SNAPSHOT_HOME" \
        LANG="$PUBLISH_SNAPSHOT_LANG" LC_ALL=C \
        GIT_CONFIG_COUNT=0 GIT_CONFIG_NOSYSTEM=1 \
        perl "$PRIVATE_TMP_HELPER" fd-exec - -- \
          git config --global --no-includes --null --get-regexp '^credential\.' \
        2>/dev/null || rc=$?
    fi
    [ "$rc" -eq 0 ] || [ "$rc" -eq 1 ]
  }
  PUBLISH_CREDENTIAL_CONFIG_HEX="$(
    credential_snapshot_git \
      | env -i PATH="$PUBLISH_SNAPSHOT_PATH" LC_ALL=C \
          perl "$PRIVATE_TMP_HELPER" fd-exec - -- \
            perl "$PRIVATE_TMP_HELPER" credential-filter \
      | env -i PATH="$PUBLISH_SNAPSHOT_PATH" LC_ALL=C \
          perl "$PRIVATE_TMP_HELPER" fd-exec - -- \
            perl -0777 -ne 'print unpack(q{H*},$_)'
  )" || {
    printf 'agent-publish-main: explicit global credential capability malformed\n' >&2
    exit 1
  }
  export -n PUBLISH_CREDENTIAL_CONFIG_HEX 2>/dev/null || true
  unset -f credential_snapshot_git
  unset PUBLISH_SNAPSHOT_PATH PUBLISH_SNAPSHOT_HOME PUBLISH_SNAPSHOT_LANG
fi

# ── PR-режим (по умолчанию на feature-ветке): публикация = подготовка ветки к PR, НЕ push в main.
# Последовательность: clean-tree → fetch <remote> <branch> → rebase на свежую вершину → проверки
# `scripts/check.sh` (пропуск только AGENT_PUBLISH_SKIP_TESTS=1) → push --force-with-lease -u ветки →
# подсказка открыть PR (`gh pr create --fill`, если origin — GitHub). Merge жмёт человек.
# Гейты пути: нет strict exact-контрактов (PIPELINE_SPEC_DIR / AGENT_PUBLISH_EXPECT_HEAD — они
# всегда идут прямым exact-путём ниже), не source-only, текущая ветка ≠ целевой. Прямая публикация
# в целевую ветку с feature-ветки — только явным AGENT_PUBLISH_MODE=main.
if [ -z "${AGENT_PUBLISH_SOURCE_ONLY:-}" ]; then
  case "${AGENT_PUBLISH_MODE:-}" in
    ""|pr|main) ;;
    *) printf 'agent-publish-main: AGENT_PUBLISH_MODE ожидаю pr|main (или пусто)\n' >&2; exit 1;;
  esac
fi
if [ -z "${AGENT_PUBLISH_SOURCE_ONLY:-}" ] && [ -z "${PIPELINE_SPEC_DIR:-}" ] \
   && [ -z "${AGENT_PUBLISH_EXPECT_HEAD:-}" ] && [ "${AGENT_PUBLISH_MODE:-}" != "main" ]; then
  PR_TARGET="${2:-main}"
  PR_BRANCH="$(git branch --show-current 2>/dev/null || true)"
  if [ -z "$PR_BRANCH" ]; then
    printf 'agent-publish-main: FATAL: detached HEAD — переключись на ветку (PR-режим) или явно задай AGENT_PUBLISH_MODE=main (прямая публикация)\n' >&2
    exit 1
  fi
  if [ "${AGENT_PUBLISH_MODE:-}" = pr ] && [ "$PR_BRANCH" = "$PR_TARGET" ]; then
    printf 'agent-publish-main(pr): FATAL: PR-режим требует feature-ветку, а сейчас %s\n' "$PR_BRANCH" >&2
    exit 1
  fi
  if [ "$PR_BRANCH" != "$PR_TARGET" ]; then
    PR_REMOTE="${1:-origin}"
    PR_ROOT="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    pr_die() { printf 'agent-publish-main(pr): FATAL: %s\n' "$*" >&2; exit 1; }
    [ -n "$PR_ROOT" ] && cd "$PR_ROOT" || pr_die "не внутри git worktree"
    [ -z "$(git status --porcelain --untracked-files=no 2>/dev/null)" ] \
      || pr_die "рабочее дерево грязное (tracked-изменения) — закоммить или stash"
    git fetch --quiet "$PR_REMOTE" "$PR_TARGET" 2>/dev/null \
      || pr_die "git fetch $PR_REMOTE $PR_TARGET не прошёл (сеть или remote недоступен)"
    PR_BASE="$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null)" \
      || pr_die "не удалось прочитать вершину $PR_REMOTE/$PR_TARGET"
    if ! git rebase "$PR_BASE" >/dev/null 2>&1; then
      git rebase --abort >/dev/null 2>&1 || true
      pr_die "rebase на $PR_REMOTE/$PR_TARGET конфликтует — rebase --abort выполнен; разреши руками (git rebase → status → add → --continue) и повтори"
    fi
    printf 'agent-publish-main(pr): ✓ ветка %s перенесена на вершину %s/%s\n' "$PR_BRANCH" "$PR_REMOTE" "$PR_TARGET"
    if [ "$(git rev-parse HEAD)" = "$PR_BASE" ]; then
      printf 'agent-publish-main(pr): ветка %s не содержит коммитов поверх %s — PR не нужен, push не выполнялся\n' "$PR_BRANCH" "$PR_TARGET"
      exit 0
    fi
    if [ "${AGENT_PUBLISH_SKIP_TESTS:-0}" = 1 ]; then
      printf 'agent-publish-main(pr): WARN проверки пропущены (AGENT_PUBLISH_SKIP_TESTS=1) — PR уходит непроверенным\n' >&2
    elif [ -f scripts/check.sh ]; then
      bash scripts/check.sh \
        || pr_die "scripts/check.sh красный на перенесённых коммитах — чини до push (проверенное авторизует только себя)"
      printf 'agent-publish-main(pr): ✓ scripts/check.sh зелёный на перенесённых коммитах\n'
    else
      pr_die "scripts/check.sh не найден — нечем проверить ветку; AGENT_PUBLISH_SKIP_TESTS=1 только осознанно"
    fi
    git push --force-with-lease -u "$PR_REMOTE" "$PR_BRANCH" \
      || pr_die "push ветки не прошёл: --force-with-lease защитил чужую работу или сеть — git fetch и разберись"
    printf 'agent-publish-main(pr): ✓ ветка %s отправлена в %s; %s не тронут\n' "$PR_BRANCH" "$PR_REMOTE" "$PR_TARGET"
    case "$(git config --get "remote.$PR_REMOTE.url" 2>/dev/null || true)" in
      https://github.com/*|git@github.com:*|ssh://git@github.com/*)
        printf 'agent-publish-main(pr): открой PR: gh pr create --fill --base %s --head %s\n' "$PR_TARGET" "$PR_BRANCH";;
      *)
        printf 'agent-publish-main(pr): открой PR из ветки %s в %s в веб-интерфейсе хостинга\n' "$PR_BRANCH" "$PR_TARGET";;
    esac
    { [ -f "$SELF_DIR/ops-log.sh" ] \
      && bash "$SELF_DIR/ops-log.sh" "publish:pr" "branch=$PR_BRANCH sha=$(git rev-parse --short HEAD)" >/dev/null 2>&1; } || true
    exit 0
  fi
  unset PR_TARGET PR_BRANCH
fi

# A caller (including an orchestrator and a localized re-exec) may carry a complete foreign Git
# authority even when the command is launched from the right cwd.  `git -C` does not cancel
# repository/config/object namespaces.  Neutralize every selector before the first Git probe and
# let Git rediscover the repository from cwd. All ambient Git/AskPass/proxy/CA selectors are
# removed. Network children later receive a separate clean env containing only the sealed global
# credential config, SSH_AUTH_SOCK and minimal PATH/HOME/XDG/LANG.
scrub_ambient_git_authority() {
  local git_env_name
  for git_env_name in $(env | sed -n 's/^\(GIT_[A-Za-z0-9_][A-Za-z0-9_]*\)=.*/\1/p'); do
    unset "$git_env_name"
  done
  unset SSH_ASKPASS SSH_ASKPASS_REQUIRE \
    http_proxy https_proxy ftp_proxy all_proxy no_proxy \
    HTTP_PROXY HTTPS_PROXY FTP_PROXY ALL_PROXY NO_PROXY \
    SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE
  export GIT_CONFIG_COUNT=0 GIT_CONFIG_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null
  export GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 GIT_OPTIONAL_LOCKS=0
}
scrub_ambient_git_authority

remote="${1:-origin}"
branch="${2:-main}"
tracking_ref="refs/remotes/$remote/$branch"

die() {
  printf 'agent-publish-main: %s\n' "$*" >&2
  exit 1
}

remember_remote() {
  local sha="$1"
  publish_tmp_guard || die "private temp identity changed"
  publish_tmp_run git -c core.hooksPath=/dev/null update-ref "$tracking_ref" "$sha"
  if [ "$PUBLISH_CMD_RC" -eq 0 ]; then
    printf 'agent-publish-main: updated local %s=%s\n' "$tracking_ref" "$sha"
  else
    publish_tmp_guard || die "private temp identity changed"
    printf 'agent-publish-main: warning: could not update %s\n' "$tracking_ref" >&2
    publish_tmp_print_stderr
  fi
  publish_tmp_guard || die "private temp identity changed"
  return 0
}

# Source-only compatibility unit retained for the historical `net()` contract. Production
# network calls below use descriptor-bound `run-bounded` with an owned session/process-group.
NET_T="${AGENT_PUBLISH_NET_TIMEOUT:-30}"
case "$NET_T" in ''|*[!0-9]*) NET_T=30;; esac
net() { perl -e 'alarm shift; exec @ARGV' "$NET_T" "$@"; }

remote_branch_oid() { # $1 remote, $2 branch → exactly one canonical exact-ref OID
  local r="$1" b="$2" ref="refs/heads/$2" out
  publish_tmp_guard || return 1
  legacy_net_run ls-remote --refs -- "$r" "$ref"
  publish_tmp_guard || return 1
  if [ "$PUBLISH_CMD_RC" -ne 0 ]; then
    publish_tmp_print_stderr
    return "$PUBLISH_CMD_RC"
  fi
  out="$(publish_tmp_stdout)" || return 1
  REMOTE_EXACT_REF="$ref" perl -ne '
    BEGIN { @oids=() }
    chomp; my ($oid,$name)=split /\s+/, $_, 2;
    next unless defined($name) && $name eq $ENV{REMOTE_EXACT_REF};
    next unless defined($oid) && $oid =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/;
    push @oids, $oid;
    END { exit 1 unless @oids == 1; print $oids[0] }
  ' <<EOF
$out
EOF
}

# --- lease-чек публикации через coordination-lease.sh check-paths --------------------------
# Пути «что несёт публикация» = merge-base(remote,HEAD)..HEAD: после rebase это тождественно
# контрактному remote..HEAD, а ДО rebase (первый гейт при дивергенции) не даёт ложных срабатываний
# на чужих remote-коммитах (их файлы в диффе remote..HEAD — не наши правки). Merge-принесённые
# правки диапазон покрывает (содержимое-дифф). Конфликт → die c именем lease/владельца/пути;
# сбой самого чека → WARN + fail-open (I-8, зеркало pre-commit хука).
lease_gate() { # $1 remote-sha, $2 фаза, $3 candidate (default HEAD; exact mode передаёт OID)
  local ref="$1" phase="$2" candidate="${3:-HEAD}" base changed out rc oldifs
  [ -f "$SELF_DIR/coordination-lease.sh" ] || return 0
  base="$(git merge-base "$ref" "$candidate" 2>/dev/null || echo "$ref")"
  changed="$(git diff --name-only "$base".."$candidate" 2>/dev/null || true)"
  [ -n "$changed" ] || return 0
  oldifs="$IFS"; IFS=$'\n'; set -f
  rc=0
  # shellcheck disable=SC2086
  out="$(bash "$SELF_DIR/coordination-lease.sh" check-paths --ref "$ref" $changed 2>&1)" || rc=$?
  set +f; IFS="$oldifs"
  if [ "$rc" -eq 1 ]; then
    printf '%s\n' "$out" >&2
    die "$phase: пути публикации под чужим действующим lease — договорись с владельцем (конвенция docs/pipeline-rules.md) или дождись истечения TTL"
  elif [ "$rc" -ne 0 ]; then
    printf 'agent-publish-main: warning: lease-чек %s не отработал (exit %s) — fail-open (I-8), проверка пропущена\n' "$phase" "$rc" >&2
    if [ -n "$out" ]; then printf '%s\n' "$out" >&2; fi
  fi
  return 0
}

revalidation_required() { # stable exact-mode refusal; caller deliberately decides trap boundary
  printf 'agent-publish-main: REVALIDATION_REQUIRED: %s\n' "$*" >&2
  exit 3
}

full_oid_valid() { # exact full lowercase SHA-1/SHA-256 spelling, never an abbreviated rev
  LC_ALL=C printf '%s\n' "$1" | grep -Eq '^([0-9a-f]{40}|[0-9a-f]{64})$'
}

commit_oid_valid() { # exact object itself must be a commit (annotated tags are not accepted)
  full_oid_valid "$1" || return 1
  [ "$(git cat-file -t "$1" 2>/dev/null || true)" = commit ]
}

exact_index_flags_standard() { # assume-unchanged/skip-worktree must not hide generic exact drift
  git ls-files -v -z | perl -0e '
    use strict; use warnings; local $/; my $d=<STDIN>; $d=q{} unless defined $d;
    for my $r (split(/\0/, $d)) { next if $r eq q{}; exit 1 if $r =~ /\A(?:[a-z]|S) / }
    exit 0;
  '
}

exact_tracked_status() { # stdout nonempty iff staged/live bytes differ from captured commit
  local exact_git_dir exact_work_tree rc=0
  if ! GIT_OPTIONAL_LOCKS=0 git \
      -c core.trustctime=true -c core.checkStat=default -c core.fsmonitor=false \
      -c core.ignoreStat=false \
      diff --cached --quiet --no-ext-diff --no-textconv --ignore-submodules=none \
        "$expected_head" --; then
    printf 'staged\n'
    return 0
  fi
  # A previous weak `git status` can poison the real index stat cache while retaining the old
  # blob OID. Ignore that index entirely and compare the expected tree directly with raw live
  # tracked bytes/modes. The helper hashes raw
  # filesystem bytes and tree modes directly, bypassing attributes, clean filters, autocrlf,
  # core.fileMode/core.symlinks and every mutable index/stat-cache shortcut.
  exact_git_dir="$(git rev-parse --absolute-git-dir 2>/dev/null)" || return 1
  exact_work_tree="$(git rev-parse --show-toplevel 2>/dev/null)" || return 1
  publish_tmp_guard || return 1
  perl "$PRIVATE_TMP_HELPER" worktree-proof "$RUN_TMP" "$RUN_TMP_ID" \
    "$exact_git_dir" "$exact_work_tree" "$expected_head" clean >/dev/null 2>&1 || rc=$?
  publish_tmp_guard || return 1
  [ "$rc" -eq 0 ] || printf 'worktree\n'
}

physical_dir_from() { # $1 base, $2 absolute-or-base-relative directory
  local base="$1" path="$2"
  case "$path" in
    /*) (cd "$path" 2>/dev/null && pwd -P) ;;
    *)  (cd "$base/$path" 2>/dev/null && pwd -P) ;;
  esac
}

validate_localized_publish_context() { # $1 registered worktree root, $2 local gitdir
  local root="$1" local_dir="$2" top registered_common local_common
  local root_phys top_phys registered_common_phys local_common_phys registered_head local_head
  [ -d "$local_dir" ] && [ ! -L "$local_dir" ] \
    && [ -f "$local_dir/HEAD" ] && [ ! -L "$local_dir/HEAD" ] \
    || revalidation_required "localized gitdir malformed"
  top="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --show-toplevel 2>/dev/null
  )" || revalidation_required "localized gitdir does not define a worktree"
  registered_common="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git rev-parse --git-common-dir 2>/dev/null
  )" || revalidation_required "registered common repository unavailable"
  local_common="$(
    cd "$root" || exit 1
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --git-common-dir 2>/dev/null
  )" || revalidation_required "localized common repository unavailable"
  root_phys="$(cd "$root" 2>/dev/null && pwd -P)" \
    || revalidation_required "registered worktree unavailable"
  top_phys="$(cd "$top" 2>/dev/null && pwd -P)" \
    || revalidation_required "localized worktree unavailable"
  registered_common_phys="$(physical_dir_from "$root" "$registered_common")" \
    || revalidation_required "registered common repository path invalid"
  local_common_phys="$(physical_dir_from "$root" "$local_common")" \
    || revalidation_required "localized common repository path invalid"
  [ "$root_phys" = "$top_phys" ] && [ "$registered_common_phys" = "$local_common_phys" ] \
    || revalidation_required "localized gitdir is not bound to the registered worktree repository"
  registered_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || revalidation_required "registered HEAD is not a commit"
  local_head="$(
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git rev-parse --verify 'HEAD^{commit}' 2>/dev/null
  )" || revalidation_required "localized HEAD is not a commit"
  full_oid_valid "$registered_head" && full_oid_valid "$local_head" \
    || revalidation_required "registered/localized HEAD is not canonical"
  if [ "$registered_head" = "$local_head" ]; then return 0; fi
  if (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git merge-base --is-ancestor "$registered_head" "$local_head" 2>/dev/null
  ); then
    return 0
  fi
  if (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
    GIT_NO_REPLACE_OBJECTS=1 GIT_DIR="$local_dir" GIT_WORK_TREE="$root" \
      git merge-base --is-ancestor "$local_head" "$registered_head" 2>/dev/null
  ); then
    revalidation_required "registered HEAD advanced beyond stale localized HEAD; relocalize/retest"
  fi
  revalidation_required "registered and localized HEAD histories diverged; explicit recovery/retest required"
}

exact_outbound_commit_metadata_safe() { # $1 pinned remote R, $2 exact B
  local base="$1" head="$2" policy
  policy="$(git show "$head:scripts/secret-patterns.sh" 2>/dev/null | perl -ne '
    if (/\ASECRET_RE='"'"'([^'"'"']+)'"'"'\s*\z/) { print $1; $n++ }
    END { exit 1 unless ($n//0)==1 }
  ')" || return 1
  [ -n "$policy" ] || return 1
  {
    git rev-list --reverse --topo-order "$base..$head" 2>/dev/null \
      | while IFS= read -r oid; do
          full_oid_valid "$oid" || exit 1
          printf '%s\0' "$oid"
          git cat-file commit "$oid" 2>/dev/null || exit 1
          printf '\0'
        done
  } | OUTBOUND_SECRET_RE="$policy" perl -0ne '
        BEGIN {
          my $raw=$ENV{OUTBOUND_SECRET_RE}//q{}; exit 1 unless length($raw);
          $secret=eval { qr/$raw/ }; exit 1 unless defined($secret) && !$@;
          $field=0;
        }
        chomp;
        if (($field++ % 2)==0) { exit 1 unless /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/; next }
        exit 1 unless /\Atree (?:[0-9a-f]{40}|[0-9a-f]{64})\n/;
        exit 1 if /$secret/;
        exit 1 if m{/Users/(?!x/|you/|username/|\.\.\./)[A-Za-z0-9._-]+/}
          || m{/home/(?!x/|you/|username/)[A-Za-z0-9._-]+/};
        END { exit 1 if $field % 2 }
      '
}

# --- юнит-режим: source c AGENT_PUBLISH_SOURCE_ONLY=1 — только определения ----------------
if [ -n "${AGENT_PUBLISH_SOURCE_ONLY:-}" ]; then
  return 0 2>/dev/null || die "AGENT_PUBLISH_SOURCE_ONLY — режим source для юнит-тестов; исполняемый запуск публикации с ним запрещён"
fi

repo_probe="$(
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  git rev-parse --show-toplevel 2>/dev/null
)" || die "not inside a registered git worktree"
local_gitdir="$repo_probe/.codex-worktree-git"
if [ -e "$local_gitdir" ]; then
  validate_localized_publish_context "$repo_probe" "$local_gitdir"
  # The selected namespace is authoritative as a complete tuple. Never retain a caller-provided
  # index/common override across validation or the localized re-exec boundary.
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  export GIT_DIR="$local_gitdir"
  export GIT_WORK_TREE="$repo_probe"
  if [ -z "${AGENT_PUBLISH_LOCALIZED:-}" ]; then
    export AGENT_PUBLISH_LOCALIZED=1
    exec "$0" "$@"
  fi
  current_gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null || true)"
  current_gitdir_phys="$(cd "$current_gitdir" 2>/dev/null && pwd -P || true)"
  local_gitdir_phys="$(cd "$local_gitdir" 2>/dev/null && pwd -P || true)"
  [ -n "$current_gitdir_phys" ] && [ "$current_gitdir_phys" = "$local_gitdir_phys" ] \
    || revalidation_required "localized recursion marker does not match effective gitdir"
  cd "$repo_probe" || die "localized worktree unavailable"
else
  [ -z "${AGENT_PUBLISH_LOCALIZED:-}" ] \
    || revalidation_required "localized recursion marker present without local gitdir"
  unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
  cd "$repo_probe" || die "registered worktree unavailable"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git worktree"

# Все диагностические bytes одного запуска живут в private tempdir, а не в предсказуемых
# /tmp-файлах (symlink/cross-run collision). EXIT-cleanup действует и для pre-DORA отказов;
# после установки DORA trap cleanup выполняется им с сохранением исходного exit status.
tmp_base="$(cd "${TMPDIR:-/tmp}" 2>/dev/null && pwd -P)" \
  || die "private temp unavailable"
[ -r "$PRIVATE_TMP_HELPER" ] || die "private temp helper unavailable"
case "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" in
  0|'') ;;
  1|network-config) { : >&9; } 2>/dev/null || die "private temp test gate unavailable";;
  *) die "private temp test gate mode unsupported";;
esac
RUN_TMP="$(umask 077; mktemp -d "$tmp_base/agent-publish-main.XXXXXX" 2>/dev/null)" \
  || die "private temp unavailable"
chmod 0700 "$RUN_TMP" >/dev/null 2>&1 \
  || { rmdir "$RUN_TMP" >/dev/null 2>&1 || true; die "private temp unavailable"; }
run_tmp_canonical="$(cd "$RUN_TMP" 2>/dev/null && pwd -P)" \
  || { rmdir "$RUN_TMP" >/dev/null 2>&1 || true; die "private temp unavailable"; }
RUN_TMP="$run_tmp_canonical"
unset run_tmp_canonical
RUN_TMP_ID="$(perl "$PRIVATE_TMP_HELPER" id "$RUN_TMP" 2>/dev/null)" \
  || { rmdir "$RUN_TMP" >/dev/null 2>&1 || true; die "private temp unavailable"; }
PUBLISH_AUTH_CONFIG=""
PUBLISH_AUTH_CONFIG_RECORD=""
PUBLISH_NET_GITDIR=""
PUBLISH_NET_GITDIR_ID=""
PUBLISH_NET_CONFIG_RECORD=""
PUBLISH_NET_CONFIG_PAUSED=0
PUBLISH_SOURCE_GITDIR=""
PUBLISH_SOURCE_OBJECTS=""
PUBLISH_OBJECT_FORMAT=""
PUBLISH_DEPLOY_ENDPOINT=""
PUBLISH_DEPLOY_REF=""
PUBLISH_CMD_RC=0
PUBLISH_STDOUT_LEAF=""
PUBLISH_STDOUT_RECORD=""
PUBLISH_STDERR_LEAF=""
PUBLISH_STDERR_RECORD=""
publish_tmp_guard() {
  perl "$PRIVATE_TMP_HELPER" guard "$RUN_TMP" "$RUN_TMP_ID" >/dev/null 2>&1
}
publish_tmp_capture() { # helper mode + argv; streams → bounded O_EXCL identity/digest records
  local helper_mode="$1" meta extra
  shift
  publish_tmp_guard || die "private temp identity changed"
  if [ "$helper_mode" = run-bounded ]; then
    meta="$(perl "$PRIVATE_TMP_HELPER" run-bounded "$RUN_TMP" "$RUN_TMP_ID" \
      "$NET_T" - - -- "$@")" \
      || die "descriptor-bound command capture failed"
  else
    meta="$(perl "$PRIVATE_TMP_HELPER" run "$RUN_TMP" "$RUN_TMP_ID" \
      - - -- "$@")" \
      || die "descriptor-bound command capture failed"
  fi
  IFS=$'\t' read -r PUBLISH_CMD_RC PUBLISH_STDOUT_LEAF PUBLISH_STDOUT_RECORD \
    PUBLISH_STDERR_LEAF PUBLISH_STDERR_RECORD extra <<EOF
$meta
EOF
  [ -z "${extra:-}" ] && case "$PUBLISH_CMD_RC" in ''|*[!0-9]*) false;; *) true;; esac \
    && printf '%s\n' "$PUBLISH_STDOUT_RECORD" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    && printf '%s\n' "$PUBLISH_STDERR_RECORD" | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    || die "descriptor-bound command record malformed"
  publish_tmp_guard || die "private temp identity changed"
}
publish_tmp_run() {
  publish_tmp_capture run "$@"
}
publish_tmp_stdout() {
  perl "$PRIVATE_TMP_HELPER" read "$RUN_TMP" "$RUN_TMP_ID" \
    "$PUBLISH_STDOUT_LEAF" "$PUBLISH_STDOUT_RECORD"
}
publish_tmp_print_stdout() {
  publish_tmp_stdout >&2 || die "descriptor-bound stdout unreadable"
}
publish_tmp_stderr() {
  perl "$PRIVATE_TMP_HELPER" read "$RUN_TMP" "$RUN_TMP_ID" \
    "$PUBLISH_STDERR_LEAF" "$PUBLISH_STDERR_RECORD"
}
publish_tmp_print_stderr() {
  publish_tmp_stderr >&2 || die "descriptor-bound stderr unreadable"
}
publish_tmp_run_net() {
  publish_tmp_capture run-bounded "$@"
}

pin_exact_deployment_endpoint() { # configured remote name -> one raw URL, push URL equal/absent
  local endpoint_hex
  case "$remote" in
    ''|*[!A-Za-z0-9._-]*|[.-]*) revalidation_required "exact publish требует canonical configured remote name";;
  esac
  git check-ref-format "refs/heads/$branch" >/dev/null 2>&1 \
    || revalidation_required "target branch не является canonical refs/heads ref"
  endpoint_hex="$(
    git config --local --no-includes --null --get-regexp '^remote\..*\.(url|pushurl)$' 2>/dev/null \
      | PUBLISH_REMOTE_NAME="$remote" perl -0777 -e '
          use strict; use warnings; my $want=q{remote.}.$ENV{PUBLISH_REMOTE_NAME};
          my (@url,@push);
          for my $r (split(/\0/,<STDIN>//q{},-1)) {
            next if $r eq q{}; my ($k,$v)=split(/\n/,$r,2); exit 1 unless defined($v);
            push(@url,$v) if $k eq "$want.url";
            push(@push,$v) if $k eq "$want.pushurl";
          }
          exit 1 unless @url==1 && @push<=1;
          exit 1 if @push && $push[0] ne $url[0];
          my $v=$url[0]; exit 1 if length($v)>8192 || $v eq q{} || $v=~/[\x00-\x1f\x7f]/
            || $v=~/\A-/ || $v=~m{\Ahttps?://[^/]*\@}i;
          print unpack(q{H*},$v);
        '
  )" || revalidation_required "remote URL не единственен, pushurl отличается или endpoint содержит inline credentials"
  PUBLISH_DEPLOY_ENDPOINT="$(printf '%s' "$endpoint_hex" \
    | perl -ne 'chomp; exit 1 unless /\A(?:[0-9a-f]{2})+\z/; print pack(q{H*},$_)')" \
    || revalidation_required "deployment endpoint decode failed"
  [ -n "$PUBLISH_DEPLOY_ENDPOINT" ] || revalidation_required "deployment endpoint empty"
  PUBLISH_DEPLOY_REF="refs/heads/$branch"
}

initialize_publish_network_context() {
  local common_raw common_phys auth_hex source_gitdir
  publish_tmp_guard || die "private temp identity changed"
  PUBLISH_AUTH_CONFIG="$RUN_TMP/credential.config"
  auth_hex="$PUBLISH_CREDENTIAL_CONFIG_HEX"
  PUBLISH_AUTH_CONFIG_RECORD="$(printf '%s' "$auth_hex" \
    | perl -ne 'chomp; exit 1 if /[^0-9a-f]/ || length($_)%2; print pack(q{H*},$_)' \
    | perl "$PRIVATE_TMP_HELPER" write "$RUN_TMP" "$RUN_TMP_ID" credential.config)" \
    || revalidation_required "credential capability snapshot could not be sealed"
  printf '%s\n' "$PUBLISH_AUTH_CONFIG_RECORD" \
    | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
    || revalidation_required "credential capability record malformed"

  PUBLISH_OBJECT_FORMAT="$(git rev-parse --show-object-format 2>/dev/null)" \
    || revalidation_required "repository object format unavailable"
  case "$PUBLISH_OBJECT_FORMAT" in sha1|sha256) ;; *) revalidation_required "unsupported object format";; esac
  source_gitdir="$(git rev-parse --absolute-git-dir 2>/dev/null)" \
    || revalidation_required "source Gitdir unavailable"
  PUBLISH_SOURCE_GITDIR="$(cd "$source_gitdir" 2>/dev/null && pwd -P)" \
    || revalidation_required "source Gitdir path invalid"
  common_raw="$(git rev-parse --git-common-dir 2>/dev/null)" \
    || revalidation_required "common Gitdir unavailable"
  common_phys="$(physical_dir_from "$repo_probe" "$common_raw")" \
    || revalidation_required "common Gitdir path invalid"
  PUBLISH_SOURCE_OBJECTS="$(cd "$common_phys/objects" 2>/dev/null && pwd -P)" \
    || revalidation_required "canonical object directory unavailable"
  publish_tmp_guard || die "private temp identity changed"
}

prepare_fresh_exact_gitdir() {
  local meta leaf record extra
  publish_tmp_guard || die "private temp identity changed"
  meta="$(perl "$PRIVATE_TMP_HELPER" make-random-dir "$RUN_TMP" "$RUN_TMP_ID" network-git)" \
    || revalidation_required "fresh isolated network Gitdir unavailable"
  IFS=$'\t' read -r leaf record extra <<EOF
$meta
EOF
  [ -z "${extra:-}" ] && printf '%s\n' "$leaf" \
      | grep -Eq '^network-git\.[0-9a-f]{24}$' \
    && printf '%s\n' "$record" \
      | grep -Eq '^[0-9]+:[0-9]+\|[0-9]+:[0-9]+$' \
    || revalidation_required "fresh isolated network Gitdir record malformed"
  PUBLISH_NET_GITDIR="$RUN_TMP/$leaf"
  PUBLISH_NET_GITDIR_ID="$record"
  # Empty --template prevents HOME/system templates from becoming executable/config authority.
  # The helper then removes local config for SHA-1 or replaces it with one sealed minimal
  # repository-format-only leaf for SHA-256 before any exact transport can run.
  publish_tmp_run env -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR -u GIT_INDEX_FILE \
    git init -q --bare --template= \
    --object-format="$PUBLISH_OBJECT_FORMAT" "$PUBLISH_NET_GITDIR"
  [ "$PUBLISH_CMD_RC" -eq 0 ] || revalidation_required "isolated network Gitdir initialization failed"
  PUBLISH_NET_CONFIG_RECORD="$(perl "$PRIVATE_TMP_HELPER" seal-gitdir-config \
    "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" "$PUBLISH_OBJECT_FORMAT")" \
    || revalidation_required "isolated network Gitdir config could not be sealed"
  if [ "$PUBLISH_OBJECT_FORMAT" = sha1 ]; then
    [ "$PUBLISH_NET_CONFIG_RECORD" = - ] \
      || revalidation_required "SHA-1 network Gitdir retained local config authority"
  else
    printf '%s\n' "$PUBLISH_NET_CONFIG_RECORD" \
      | grep -Eq '^[0-9]+:[0-9]+\|[0-9a-f]{64}\|[0-9]+$' \
      || revalidation_required "SHA-256 network Gitdir config record malformed"
  fi
  if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = network-config ] \
      && [ "$PUBLISH_NET_CONFIG_PAUSED" -eq 0 ]; then
    # Bash 3.2 keeps $$ equal to the top shell inside command substitution. A tiny trusted child
    # reports/stops its actual Bash parent, so the causal gate pauses the exact consumer process.
    perl -e '
      open(my $gate,q{>&=9}) or exit 1;
      my $parent=getppid(); print {$gate} qq{network-config-ready $parent\n} or exit 1;
      close($gate) or exit 1; kill(q{STOP},$parent) or exit 1;
    ' || die "private temp test gate unavailable"
    PUBLISH_NET_CONFIG_PAUSED=1
    publish_tmp_guard || die "private temp identity changed"
  fi
  perl "$PRIVATE_TMP_HELPER" verify-gitdir-config "$PUBLISH_NET_GITDIR" \
    "$PUBLISH_NET_GITDIR_ID" "$PUBLISH_OBJECT_FORMAT" "$PUBLISH_NET_CONFIG_RECORD" \
    >/dev/null 2>&1 || revalidation_required "isolated network Gitdir config authority changed"
  perl "$PRIVATE_TMP_HELPER" guard "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" \
    >/dev/null 2>&1 || revalidation_required "isolated network Gitdir identity changed"
  publish_tmp_guard || die "private temp identity changed"
}

exact_net_run() {
  prepare_fresh_exact_gitdir
  publish_tmp_run perl "$PRIVATE_TMP_HELPER" config-gitdir-exec-clean "$RUN_TMP" "$RUN_TMP_ID" \
    credential.config "$PUBLISH_AUTH_CONFIG_RECORD" \
    "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" "$PUBLISH_OBJECT_FORMAT" \
    "$PUBLISH_NET_CONFIG_RECORD" "$PUBLISH_SOURCE_OBJECTS" -- git "$@"
  perl "$PRIVATE_TMP_HELPER" guard "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" \
    >/dev/null 2>&1 || revalidation_required "isolated network Gitdir identity changed"
}

exact_net_run_network() {
  prepare_fresh_exact_gitdir
  publish_tmp_run_net perl "$PRIVATE_TMP_HELPER" config-gitdir-exec-clean "$RUN_TMP" "$RUN_TMP_ID" \
    credential.config "$PUBLISH_AUTH_CONFIG_RECORD" \
    "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" "$PUBLISH_OBJECT_FORMAT" \
    "$PUBLISH_NET_CONFIG_RECORD" "$PUBLISH_SOURCE_OBJECTS" -- git "$@"
  perl "$PRIVATE_TMP_HELPER" guard "$PUBLISH_NET_GITDIR" "$PUBLISH_NET_GITDIR_ID" \
    >/dev/null 2>&1 || revalidation_required "isolated network Gitdir identity changed"
}

legacy_net_run() {
  publish_tmp_run_net perl "$PRIVATE_TMP_HELPER" config-exec-clean "$RUN_TMP" "$RUN_TMP_ID" \
    credential.config "$PUBLISH_AUTH_CONFIG_RECORD" -- \
    env GIT_DIR="$PUBLISH_SOURCE_GITDIR" GIT_WORK_TREE="$repo_probe" git "$@"
}

exact_deployment_oid() {
  local out
  exact_net_run_network ls-remote --refs -- "$PUBLISH_DEPLOY_ENDPOINT" "$PUBLISH_DEPLOY_REF"
  if [ "$PUBLISH_CMD_RC" -ne 0 ]; then
    publish_tmp_print_stderr
    return "$PUBLISH_CMD_RC"
  fi
  out="$(publish_tmp_stdout)" || return 1
  REMOTE_EXACT_REF="$PUBLISH_DEPLOY_REF" perl -ne '
    BEGIN { @oids=() } chomp; my ($oid,$name)=split /\s+/, $_, 2;
    push @oids,$oid if defined($name) && $name eq $ENV{REMOTE_EXACT_REF}
      && defined($oid) && $oid =~ /\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/;
    END { exit 1 unless @oids==1; print $oids[0] }
  ' <<EOF
$out
EOF
}
cleanup_run_tmp() {
  local cleanup_rc=0
  [ -n "${RUN_TMP:-}" ] || return 0
  perl "$PRIVATE_TMP_HELPER" cleanup "$RUN_TMP" "$RUN_TMP_ID" >/dev/null 2>&1 || cleanup_rc=1
  RUN_TMP=""
  RUN_TMP_ID=""
  PUBLISH_AUTH_CONFIG=""
  PUBLISH_AUTH_CONFIG_RECORD=""
  PUBLISH_NET_GITDIR=""
  PUBLISH_NET_GITDIR_ID=""
  PUBLISH_NET_CONFIG_RECORD=""
  PUBLISH_SOURCE_GITDIR=""
  PUBLISH_SOURCE_OBJECTS=""
  PUBLISH_OBJECT_FORMAT=""
  PUBLISH_DEPLOY_ENDPOINT=""
  PUBLISH_DEPLOY_REF=""
  return "$cleanup_rc"
}
pre_dora_exit() {
  rc=$?
  trap - EXIT
  if ! cleanup_run_tmp; then
    printf 'agent-publish-main: private temp cleanup failed\n' >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  exit "$rc"
}
trap pre_dora_exit EXIT

if [ "${HARNESS_PRIVATE_TMP_TEST_PAUSE:-0}" = 1 ]; then
  printf 'ready\n' >&9 || die "private temp test gate unavailable"
  kill -STOP "$$" 2>/dev/null || die "private temp test gate unavailable"
  publish_tmp_guard || die "private temp identity changed"
fi

# Seal the same explicit global credential capability once for both exact and legacy network
# children. No later Git process reopens HOME/XDG config by pathname.
initialize_publish_network_context

# Replace refs подменяют смысл rev-parse/cat-file/merge-base при неизменном написании OID. Exact
# contract доказывает identity реальных objects, поэтому отключает replacements ДО первого
# pipeline/generic proof и передаёт guard всем дочерним git/pipeline процессам.
if [ -n "${PIPELINE_SPEC_DIR:-}" ] || [ -n "${AGENT_PUBLISH_EXPECT_HEAD:-}" ]; then
  export GIT_NO_REPLACE_OBJECTS=1
fi

# --- exact-SHA selector: весь initial gate ДО DORA trap -----------------------------------
# `check ... publish` сам валидирует canonical V3 state, immutable H→B envelope и per-worktree
# binding ref; успешный check гарантирует, что canonical HEAD = bound B. stdout не парсится:
# сохраняем human-readable `check OK`, а immutable OID захватываем сразу после предиката.
exact_mode=""
pipeline_exact=""
pipeline_bound=""
generic_expected="${AGENT_PUBLISH_EXPECT_HEAD:-}"
expected_head=""
exact_action=""
remote_sha=""

if [ -n "${PIPELINE_SPEC_DIR:-}" ]; then
  if ! bash "$SELF_DIR/pipeline-state.sh" check "$PIPELINE_SPEC_DIR" publish; then
    die "publish BLOCKED: strict pipeline binding для '$PIPELINE_SPEC_DIR' не прошёл"
  fi
  pipeline_bound="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  commit_oid_valid "$pipeline_bound" \
    || revalidation_required "pipeline binding не дал canonical full commit OID"
  pipeline_exact=1
  exact_mode=1
  expected_head="$pipeline_bound"
fi

if [ -n "$generic_expected" ]; then
  commit_oid_valid "$generic_expected" \
    || revalidation_required "AGENT_PUBLISH_EXPECT_HEAD должен быть full lowercase 40/64-hex commit OID"
  if [ -n "$expected_head" ] && [ "$expected_head" != "$generic_expected" ]; then
    revalidation_required "pipeline binding и AGENT_PUBLISH_EXPECT_HEAD не совпадают"
  fi
  expected_head="$generic_expected"
  exact_mode=1
fi

exact_binding_recheck() { # $1 phase; safe both before and after DORA trap
  local phase="$1" live rebound tracked_status
  if [ -e "$local_gitdir" ]; then
    validate_localized_publish_context "$repo_probe" "$local_gitdir"
  fi
  live="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
  [ "$live" = "$expected_head" ] \
    || revalidation_required "$phase: HEAD изменился после проверки exact commit"
  commit_oid_valid "$expected_head" \
    || revalidation_required "$phase: expected commit object больше не доступен"
  if [ -n "$pipeline_exact" ]; then
    if ! bash "$SELF_DIR/pipeline-state.sh" check "$PIPELINE_SPEC_DIR" publish; then
      revalidation_required "$phase: pipeline binding/state больше не проходит strict check"
    fi
    rebound="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null || true)"
    [ "$rebound" = "$expected_head" ] \
      || revalidation_required "$phase: повторный pipeline binding дал иной commit"
  fi
  tracked_status="$(exact_tracked_status 2>/dev/null)" \
    || revalidation_required "$phase: не удалось доказать clean tracked worktree/index"
  [ -z "$tracked_status" ] \
    || revalidation_required "$phase: tracked worktree/index изменён после проверки"
  exact_index_flags_standard \
    || revalidation_required "$phase: index содержит assume-unchanged/skip-worktree flags"
}

exact_outbound_range_recheck() { # $1 phase; strict pipeline only, remote_sha already pinned
  local phase="$1"
  [ -n "$pipeline_exact" ] || return 0
  bash "$SELF_DIR/pipeline-state.sh" publish-base "$PIPELINE_SPEC_DIR" "$remote_sha" \
    >/dev/null \
    || revalidation_required "$phase: outbound graph обязан быть exact R→C→H→B без pre-C history"
  exact_outbound_commit_metadata_safe "$remote_sha" "$expected_head" \
    || revalidation_required "$phase: outbound commit metadata нарушает canonical secret/path policy"
}

exact_outbound_noop_recheck() { # $1 phase; remote already equals B, recover immutable R=B^^^
  local phase="$1" base
  [ -n "$pipeline_exact" ] || return 0
  base="$(git rev-parse --verify "$expected_head^^^" 2>/dev/null || true)"
  full_oid_valid "$base" \
    || revalidation_required "$phase: exact noop не восстановил canonical R из B^^^"
  bash "$SELF_DIR/pipeline-state.sh" publish-base "$PIPELINE_SPEC_DIR" "$base" \
    >/dev/null \
    || revalidation_required "$phase: exact noop обязан сохранять graph R→C→H→B"
  exact_outbound_commit_metadata_safe "$base" "$expected_head" \
    || revalidation_required "$phase: exact noop commit metadata нарушает canonical secret/path policy"
}

if [ -n "$exact_mode" ]; then
  exact_binding_recheck "initial"

  # Exact mode pins one raw deployment URL, then creates a fresh isolated config-free Gitdir for
  # each command. A transport can mutate its current disposable config but cannot influence the
  # later push/verify command. No fetch writes source repository state.
  pin_exact_deployment_endpoint
  if ! remote_sha="$(exact_deployment_oid)"; then
    die "cannot read pinned deployment branch for exact publish (timeout ${NET_T}s)"
  fi
  commit_oid_valid "$remote_sha" \
    || revalidation_required "deployment base object is not locally available; fetch, retest and rebind"
  exact_binding_recheck "after-remote-read"
  if [ "$remote_sha" = "$expected_head" ]; then
    exact_action=noop
  else
    exact_net_run merge-base --is-ancestor "$remote_sha" "$expected_head"
    if [ "$PUBLISH_CMD_RC" -eq 0 ]; then
      exact_action=push
    elif [ "$PUBLISH_CMD_RC" -eq 1 ]; then
      revalidation_required "deployment branch is not an ancestor of exact commit; fetch/retest/rebind required"
    else
      revalidation_required "could not prove deployment-base ancestry in isolated Git context"
    fi
  fi
  if [ "$exact_action" = push ]; then
    exact_outbound_range_recheck "after-remote-read"
  else
    exact_outbound_noop_recheck "after-remote-read-noop"
  fi
  lease_gate "$remote_sha" "lease-exact" "$expected_head"
else
  # Прямая публикация: advisory lease preflight; retry loop ниже делает обязательный fresh fetch.
  gate_sha=""
  publish_tmp_guard || die "private temp identity changed"
  legacy_net_run fetch "$remote" "$branch"
  fetch_rc="$PUBLISH_CMD_RC"
  publish_tmp_guard || die "private temp identity changed"
  if [ "$fetch_rc" -eq 0 ]; then
    gate_sha="$(git rev-parse FETCH_HEAD 2>/dev/null || true)"
  else
    printf 'agent-publish-main: warning: fetch %s %s не прошёл (сеть/таймаут %sс) — предварительный lease-гейт пропущен (advisory), повторный в retry-цикле остаётся\n' "$remote" "$branch" "$NET_T" >&2
  fi
  if [ -n "$gate_sha" ]; then
    lease_gate "$gate_sha" "lease-preflight"
  fi
fi

# --- dirty-guard ДО trap -------------------------------------------------------------------
# rebase требует чистого дерева; untracked не мешают (журналы/артефакты) — только tracked-изменения.
if [ -n "$(git status --porcelain --untracked-files=no 2>/dev/null)" ]; then
  die "рабочее дерево грязное (незакоммиченные tracked-изменения) — commit или stash перед публикацией: retry-rebase требует чистого дерева; untracked-файлы не мешают"
fi

# --- DORA-события публикации ---------------------------------------------------------------
# Trap ставится строго ПОСЛЕ self-relocation (exec не переживает замену процесса — двойной
# записи нет), worktree-проверки и до-trap-гейтов (lease/dirty): их провал — не публикация,
# события не пишет (осознанная слепая зона).
publish_outcome=""   # "" | "noop" — различает исходы при rc=0 (флаг, не голый $?)
rebased_from=""      # исходный короткий sha ДО rebase — в detail publish:done
dora_sha="$expected_head" # exact mode: immutable captured OID; legacy: empty → late live HEAD
on_exit() {
  local rc=$? sha detail
  trap - EXIT
  if ! cleanup_run_tmp; then
    printf 'agent-publish-main: private temp cleanup failed\n' >&2
    [ "$rc" -ne 0 ] || rc=1
  fi
  if [ -n "$dora_sha" ]; then sha="$dora_sha"
  else sha="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
  fi
  detail="sha=$sha rc=$rc"
  if [ -n "$rebased_from" ]; then detail="$detail rebased-from=$rebased_from"; fi
  # || true везде: сбой журнала НИКОГДА не меняет exit-код публикации (I-8).
  # Известное ограничение: сбой сети между push и verify + агентский ретрай даёт пару
  # publish:failed + publish:noop на одну логическую публикацию; автодедупликации нет.
  # Публикация — НЕ деплой: deploy:* пишет только деплой-скрипт проекта (без двойного счёта DORA).
  if [ "$rc" -eq 0 ] && [ "$publish_outcome" = "noop" ]; then
    bash "$SELF_DIR/ops-log.sh" publish:noop "$detail" || true
  elif [ "$rc" -eq 0 ]; then
    bash "$SELF_DIR/ops-log.sh" publish:done "$detail" || true
  else
    bash "$SELF_DIR/ops-log.sh" publish:failed "$detail" || true
  fi
  exit "$rc"
}
trap on_exit EXIT
# --------------------------------------------------------------------------------------------

# --- exact-SHA single-attempt path ---------------------------------------------------------
# После этой точки отказ честно относится к начавшейся publish-попытке и попадает в DORA.
# Никаких rebase, autocommit, publish:retry или символического HEAD-refspec здесь нет.
if [ -n "$exact_mode" ]; then
  exact_binding_recheck "pre-push"

  if [ "$exact_action" = noop ]; then
    lease_gate "$remote_sha" "lease-exact-noop" "$expected_head"
    # The same pinned literal endpoint is read again; repo-local pushurl/url rewrites cannot enter.
    if ! verify_sha="$(exact_deployment_oid)"; then
      die "exact noop remote verification failed"
    fi
    [ "$verify_sha" = "$expected_head" ] \
      || revalidation_required "remote изменился после exact noop preflight"
    # Last authority proof follows lease and the pinned remote read, immediately before the only
    # noop mutations (tracking ref + outcome/DORA classification).
    exact_binding_recheck "pre-noop-final"
    exact_outbound_noop_recheck "pre-noop-final"
    remember_remote "$expected_head"
    publish_outcome=noop
    printf 'agent-publish-main: exact remote already equals %s; revalidated noop\n' "$expected_head"
    exit 0
  fi

  lease_gate "$remote_sha" "lease-exact-final" "$expected_head"
  # Lease helper has run; repeat proof immediately before the one-ref CAS push.
  exact_binding_recheck "pre-push-final"
  exact_outbound_range_recheck "pre-push-final"
  printf 'agent-publish-main: pushing exact %s:refs/heads/%s to %s\n' \
    "$expected_head" "$branch" "$remote"
  publish_tmp_guard || die "private temp identity changed"
  exact_net_run_network push --no-verify --no-follow-tags --recurse-submodules=no \
    --force-with-lease="${PUBLISH_DEPLOY_REF}:${remote_sha}" -- \
    "$PUBLISH_DEPLOY_ENDPOINT" "${expected_head}:${PUBLISH_DEPLOY_REF}"
  push_rc="$PUBLISH_CMD_RC"
  publish_tmp_guard || die "private temp identity changed"
  if [ "$push_rc" -ne 0 ]; then
    publish_tmp_print_stderr
    die "exact push failed; commit не изменён и retry/rebase не выполнялись"
  fi
  if ! verify_sha="$(exact_deployment_oid)"; then
    die "exact push returned, but remote verification failed"
  fi
  printf 'agent-publish-main: verified remote %s/%s=%s\n' "$remote" "$branch" "$verify_sha"
  [ "$verify_sha" = "$expected_head" ] \
    || die "remote verification mismatch; expected captured exact commit $expected_head"
  remember_remote "$expected_head"
  printf 'agent-publish-main: exact commit published successfully\n'
  exit 0
fi

# --- retry-цикл ≤3 — свежий fetch КАЖДОЙ итерации (закрывает TOCTOU) ----------------------
backoff="${AGENT_PUBLISH_BACKOFF_BASE:-2}"
case "$backoff" in ''|*[!0-9]*) backoff=2;; esac
orig_head="$(git rev-parse HEAD)"
attempt=1
published=""
while [ "$attempt" -le 3 ]; do
  publish_tmp_guard || die "private temp identity changed"
  legacy_net_run fetch "$remote" "$branch"
  fetch_rc="$PUBLISH_CMD_RC"
  publish_tmp_guard || die "private temp identity changed"
  if [ "$fetch_rc" -ne 0 ]; then
    publish_tmp_print_stderr
    die "cannot read $remote/$branch (fetch не прошёл: remote недоступен или сеть молчит, таймаут ${NET_T}с); do not close issues until GitHub access is restored"
  fi
  remote_sha="$(git rev-parse FETCH_HEAD)"
  head_sha="$(git rev-parse HEAD)"
  if [ -e "$local_gitdir" ]; then
    validate_localized_publish_context "$repo_probe" "$local_gitdir"
  fi
  printf 'agent-publish-main: attempt %s/3: HEAD=%s remote %s/%s=%s\n' "$attempt" "$head_sha" "$remote" "$branch" "$remote_sha"

  if [ "$remote_sha" = "$head_sha" ]; then
    printf 'agent-publish-main: remote already matches HEAD; nothing to push\n'
    remember_remote "$head_sha"
    publish_outcome="noop"   # no-op — НЕ публикация; trap запишет publish:noop, не publish:done
    exit 0
  fi

  if ! git merge-base --is-ancestor "$remote_sha" "$head_sha" 2>/dev/null; then
    printf 'agent-publish-main: дивергенция — rebase HEAD на %s\n' "$remote_sha"
    # --autostash: между итерациями best-effort publish:retry дописывает tracked ops-journal —
    # самонанесённая телеметрия легитимна (вход был чист по dirty-guard), autostash проносит её
    # сквозь rebase; union-атрибут журнала (.gitattributes) разруливает совпадающие аппенды.
    publish_tmp_guard || die "private temp identity changed"
    publish_tmp_run git rebase --autostash "$remote_sha"
    rebase_rc="$PUBLISH_CMD_RC"
    publish_tmp_guard || die "private temp identity changed"
    if [ "$rebase_rc" -ne 0 ]; then
      publish_tmp_print_stdout
      publish_tmp_print_stderr
      git rebase --abort >/dev/null 2>&1 || true
      die "rebase на $remote/$branch конфликтует — git rebase --abort выполнен автоматически (репо НЕ оставлено в mid-rebase); разреши конфликт руками (fetch + rebase $remote_sha) и повтори публикацию"
    fi
    head_sha="$(git rev-parse HEAD)"
    if [ "$head_sha" != "$orig_head" ] && [ -z "$rebased_from" ]; then
      rebased_from="$(git rev-parse --short "$orig_head")"
    fi
  fi

  # повторный lease-чек на свежем диффе — отказ здесь уже под trap,
  # легитимный publish:failed (публикация реально не состоялась из-за чужого lease)
  lease_gate "$remote_sha" "lease-final"

  if [ -e "$local_gitdir" ]; then
    validate_localized_publish_context "$repo_probe" "$local_gitdir"
  fi

  printf 'agent-publish-main: pushing HEAD:%s to %s\n' "$branch" "$remote"
  publish_tmp_guard || die "private temp identity changed"
  legacy_net_run push "$remote" "HEAD:$branch"
  push_rc="$PUBLISH_CMD_RC"
  publish_tmp_guard || die "private temp identity changed"
  if [ "$push_rc" -eq 0 ]; then
    if ! verify_sha="$(remote_branch_oid "$remote" "$branch")"; then
      die "push returned, but remote verification failed"
    fi
    printf 'agent-publish-main: verified remote %s/%s=%s\n' "$remote" "$branch" "$verify_sha"
    if [ "$verify_sha" != "$head_sha" ]; then
      die "remote verification mismatch; expected $head_sha"
    fi
    remember_remote "$head_sha"
    published=1
    break
  fi
  publish_tmp_print_stderr
  printf 'agent-publish-main: retry %s/3 (diverged)\n' "$attempt" >&2
  bash "$SELF_DIR/ops-log.sh" "publish:retry" "attempt=$attempt" || true
  if [ "$attempt" -lt 3 ]; then
    sleep $((backoff * attempt))
  fi
  attempt=$((attempt + 1))
done

# --- исчерпание попыток → честный die (livelock при плотном потоке публикаций) -------------
if [ -z "$published" ]; then
  die "3 попытки публикации исчерпаны (плотный поток публикаций — livelock); повтори позже или договорись с активными сессиями (конвенция docs/pipeline-rules.md)"
fi
printf 'agent-publish-main: published successfully\n'
