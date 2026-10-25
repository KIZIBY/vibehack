#!/usr/bin/env bash
# tests/harness/cases/preflight.sh — agent-preflight.sh.
# Контракт: exit строго 0|1 (классы различаются WARN-маркером, не кодом); dirty-рабочка —
# NOTE, а не провал (регресс-guard); publish_state-матрица против локального bare-origin;
# правило ISSUE_BACKEND (env → PROJECT.md → none, неизвестное → fail closed); GitHub-репозиторий
# только из origin (GH_REPO лишь повторяет); root-hygiene allowlist. Сеть не нужна: origin —
# file://-bare (для GitHub-ветки — через url.insteadOf), gh — PATH-стаб.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "preflight (0|1-контракт · publish_state · ISSUE_BACKEND · hygiene)"

SUT="$ROOT/scripts/agent-preflight.sh"
export AGENT_PREFLIGHT_NET_TIMEOUT=5

BARE="$TMP/origin.git"; R="$TMP/wt"; BIN="$TMP/bin"
mk_bare "$BARE"
mk_repo "$R"
mk_commit "$R" README.md "readme"
git -C "$R" remote add origin "$BARE"
git -C "$R" push -q origin HEAD:main

# gh-стаб: auth/list/api отвечают успехом; лог argv — доказательство, КАК preflight зовёт gh.
mkdir -p "$BIN"
cat >"$BIN/gh" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >>"${0%/*}/gh.argv"
case "$1 ${2:-}" in
  "auth status") exit 0 ;;
  "issue list") printf '[]\n'; exit 0 ;;
  "api "*) printf 'true\n'; exit 0 ;;
esac
exit 0
EOF
chmod +x "$BIN/gh"

pf() { ( cd "$R" && env -u ISSUE_BACKEND -u GH_REPO PATH="$BIN:$PATH" bash "$SUT" origin main ) </dev/null; }
pf_env() { ( cd "$R" && env -u GH_REPO PATH="$BIN:$PATH" ISSUE_BACKEND="$1" bash "$SUT" origin main ) </dev/null; }
project_md() { printf '# PROJECT.md\n\n```\n%s\n```\n' "$1" >"$R/PROJECT.md"; }

# ── герметичный PASS: remote==HEAD, backend по умолчанию none, hygiene clean ──
t "чистый прогон (нет PROJECT.md) → exit 0" 0 pf
t_out "publish_state=remote_matches_head" 'publish_state=remote_matches_head'
t_out "ISSUE_BACKEND по умолчанию = none" 'issue_backend=none'
t_out "issue-пробы пропущены при none" 'issue_checks=skipped'
t_out "root_hygiene=clean" 'root_hygiene=clean'
t "none → gh не вызывался" 1 test -e "$BIN/gh.argv"

# ── dirty-рабочка = NOTE, не провал (регресс-guard: dirty не должен стать WARN) ──
printf '# локальная правка\n' >>"$R/README.md"
t "dirty-рабочка → ПО-ПРЕЖНЕМУ exit 0" 0 pf
t_out "dirty отражён информационной NOTE dirty_entries=N" 'dirty_entries=[1-9]'
git -C "$R" checkout -q -- README.md

# ── HEAD впереди remote → note fast-forward, exit 0 ──
git -C "$R" commit -q --allow-empty -m ahead
t "HEAD впереди remote → exit 0 (публикация возможна)" 0 pf
t_out "publish_state=head_can_fast_forward_remote" 'publish_state=head_can_fast_forward_remote'
git -C "$R" push -q origin HEAD:main

# ── PROJECT.md (в allowlist корня) + правило ISSUE_BACKEND ──
project_md 'ISSUE_BACKEND=none'
t "PROJECT.md ISSUE_BACKEND=none → exit 0 (PROJECT.md в корне — не нарушение гигиены)" 0 pf
t_out "PROJECT.md none → issue_backend=none" 'issue_backend=none'
project_md 'ISSUE_BACKEND=gihub'
t "PROJECT.md ISSUE_BACKEND=gihub → exit 1 (fail closed)" 1 pf
t_out "WARN issue_contract=invalid-backend" 'issue_contract=invalid-backend'
t "env ISSUE_BACKEND=tracker (не поддерживается) → exit 1" 1 pf_env tracker
t_out "env неизвестный backend → invalid-backend" 'issue_contract=invalid-backend'
t "env ISSUE_BACKEND=none побеждает некорректный PROJECT.md → exit 0" 0 pf_env none
t_out "env none → issue_backend=none" 'issue_backend=none'

# ── github: не-GitHub origin → fail closed без похода в gh ──
project_md 'ISSUE_BACKEND=github'
t "github при file://-origin → exit 1" 1 pf
t_out "WARN github_repo=origin_unavailable" 'github_repo=origin_unavailable'
t "github без GitHub-origin → gh не вызывался" 1 test -e "$BIN/gh.argv"

# ── github: GitHub-origin (транспорт перенаправлен на bare через insteadOf) ──
git -C "$R" remote set-url origin https://github.com/o/r.git
git -C "$R" config "url.$BARE.insteadOf" https://github.com/o/r.git
t "github: origin github.com/o/r + gh ok → exit 0" 0 pf
t_out "github: issue_backend=github" 'issue_backend=github'
t_out "github: репозиторий разрешён из origin" 'github_repo=resolved'
t_out "github: gh_issues_read=ok" 'gh_issues_read=ok'
t "github: gh получил репозиторий из origin" 0 grep -q -- '--repo github.com/o/r' "$BIN/gh.argv"
t "env ISSUE_BACKEND=none поверх PROJECT.md github → exit 0" 0 pf_env none
t_out "env побеждает PROJECT.md" 'issue_backend=none'
pf_pin() { ( cd "$R" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" GH_REPO="$1" bash "$SUT" origin main ) </dev/null; }
t "GH_REPO = origin → exit 0" 0 pf_pin github.com/o/r
t "GH_REPO ≠ origin → exit 1" 1 pf_pin evil/other
t_out "WARN issue_contract=github-repo-mismatch" 'issue_contract=github-repo-mismatch'
git -C "$R" config --unset "url.$BARE.insteadOf"
git -C "$R" remote set-url origin "$BARE"
rm -f "$R/PROJECT.md"

# ── root hygiene: посторонний md в корне ──
printf 'stray\n' >"$R/stray-notes.md"
t "посторонний .md в корне → exit 1" 1 pf
t_out "WARN root_hygiene=violations" 'root_hygiene=violations'
rm -f "$R/stray-notes.md"

# ── remote недостижим → WARN cannot read ──
git -C "$R" remote set-url origin "$TMP/nonexistent.git"
t "недостижимый origin → exit 1" 1 pf
t_out "WARN cannot read origin/main" 'cannot read origin/main'
git -C "$R" remote set-url origin "$BARE"

# ── дивергенция: remote не предок HEAD → blocked ──
git -C "$R" commit -q --allow-empty -m tobe && git -C "$R" push -q origin HEAD:main
git -C "$R" commit -q --allow-empty --amend -m diverged
t "remote не предок HEAD → exit 1" 1 pf
t_out "publish_state=blocked_remote_not_ancestor_of_head" 'blocked_remote_not_ancestor_of_head'

# ── контрактные отказы ──
bad_selector() { ( cd "$R" && bash "$SUT" 'bad name' main ) </dev/null; }
t "невалидный git-селектор → exit 1" 1 bad_selector
t_out "WARN git selector is invalid" 'git selector is invalid'
outside() { ( cd "$TMP" && bash "$SUT" ) </dev/null; }
t "вне git-worktree → exit 1" 1 outside
t_out "WARN not inside a git worktree" 'not inside a git worktree'
R2="$TMP/norem"; mk_repo "$R2"; mk_commit "$R2" a.txt a
no_remote() { ( cd "$R2" && env -u ISSUE_BACKEND bash "$SUT" ) </dev/null; }
t "нет origin → exit 1" 1 no_remote
t_out "WARN remote origin is missing" 'remote origin is missing'

harness_exit
