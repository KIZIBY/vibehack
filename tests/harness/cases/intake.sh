#!/usr/bin/env bash
# tests/harness/cases/intake.sh — детерминированная привязка ticket↔SPEC_DIR. Инвариант: I-17.
#
# Поведенческий контракт scripts/intake.sh: ровно-одна-строка stdout-исход
# (created:<KEY> | deferred:<reason>[ KEY=<key>] | skipped:issue-backend-none | error:<reason>),
# правило выбора backend (env ISSUE_BACKEND → строка PROJECT.md → none; неизвестное → fail closed),
# репозиторий GitHub только из origin (GH_REPO может лишь повторять), стабильная и идемпотентная
# привязка SPEC_DIR→ticket на повтор и redaction fixture-токена провайдера при деградации.
# Провайдер — ТОЛЬКО двойник из $FIX (fake-gh-intake.sh на PATH); настоящий gh не участвует.
# Fixture-контролы (FAKE_GH_DOWN и т.п.) доходят до двойника лишь при ISSUE_PROVIDER_TEST_ENABLED=1 —
# интеграционная копия SUT с этим одним литералом.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "intake (ровно-одна-строка stdout · ISSUE_BACKEND · ticket↔SPEC_DIR)"

# ── Герметичный стенд под $TMP ────────────────────────────────────────────────────────────────
# Механическая копия SUT: единственный литерал ISSUE_PROVIDER_TEST_ENABLED=0→1 пускает fixture-env
# сквозь provider-env.pl; production-копия по-прежнему их вырезает.
RT="$TMP/rt"; mkdir -p "$RT"
for s in intake.sh provider-env.pl private-temp-dir.pl secret-patterns.sh; do
  cp "$ROOT/scripts/$s" "$RT/$s"
done
perl -pi -e 's/^ISSUE_PROVIDER_TEST_ENABLED=0$/ISSUE_PROVIDER_TEST_ENABLED=1/' "$RT/intake.sh"
SUT="$RT/intake.sh"

# Репозиторий-цель: GitHub-origin + runtime, который intake резолвит от корня repo (scripts/*).
REPO="$TMP/repo"; BIN="$TMP/bin"; ART="$TMP/gh-art"
mkdir -p "$REPO/scripts/lib" "$BIN" "$ART"
git -C "$REPO" init -q
git -C "$REPO" remote add origin https://github.com/o/r.git
cp "$ROOT/scripts/pipeline-state.sh" "$REPO/scripts/pipeline-state.sh"
cp "$ROOT/scripts/private-temp-dir.pl" "$REPO/scripts/private-temp-dir.pl"
cp "$ROOT/scripts/lib/pipeline-state-reader-v4.pl" "$REPO/scripts/lib/pipeline-state-reader-v4.pl"
cp "$FIX/fake-gh-intake.sh" "$BIN/gh"; chmod +x "$BIN/gh"

ps_ init "$REPO/specs/001-gh"  "intake github"  >/dev/null 2>&1
ps_ init "$REPO/specs/002-def" "intake deferred" >/dev/null 2>&1
ps_ init "$REPO/specs/003-non" "intake none" >/dev/null 2>&1

project_md() { printf '# PROJECT.md\n\n```\n%s\n```\n' "$1" >"$REPO/PROJECT.md"; }
one_line() { [ "$(wc -l < "$1" | tr -d ' ')" -eq 1 ]; }

# ── ISSUE_BACKEND по умолчанию (нет env, нет PROJECT.md) = none: ни одного вызова gh ────────────
MARK="$TMP/gh-marker"
default_none() {
  rm -f "$MARK"
  ( cd "$REPO" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" FAKE_GH_MARKER="$MARK" \
      bash "$SUT" ticket specs/003-non 'none phrase' ) >"$TMP/none.out" 2>"$TMP/none.err"
}
t "нет PROJECT.md и env → exit 0" 0 default_none
t "default none → РОВНО одна строка skipped:issue-backend-none" 0 \
  sh -c 'grep -qx "skipped:issue-backend-none" "$1" && [ "$(wc -l < "$1" | tr -d " ")" -eq 1 ]' _ "$TMP/none.out"
t "default none → gh не вызывался" 1 test -e "$MARK"
t "default none → Ticket в state.md не тронут" 0 grep -qx -- '- Ticket: —' "$REPO/specs/003-non/state.md"
t "default none → stderr указывает очередь docs/backlog.md" 0 grep -q 'docs/backlog.md' "$TMP/none.err"

# ── PROJECT.md: ISSUE_BACKEND=none явно ─────────────────────────────────────────────────────────
project_md 'ISSUE_BACKEND=none'
md_none() { ( cd "$REPO" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" bash "$SUT" ticket specs/003-non 'x' ); }
t "PROJECT.md ISSUE_BACKEND=none → exit 0" 0 md_none
t_out "PROJECT.md none → skipped:issue-backend-none" '^skipped:issue-backend-none$'

# ── PROJECT.md: неизвестное значение → fail closed (опечатка не становится none) ───────────────
project_md 'ISSUE_BACKEND=gihub'
md_bad() { ( cd "$REPO" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" bash "$SUT" ticket specs/003-non 'x' ); }
t "PROJECT.md ISSUE_BACKEND=gihub → exit 1" 1 md_bad
t_out "PROJECT.md опечатка → error:invalid-issue-backend" '^error:invalid-issue-backend$'

# ── env ISSUE_BACKEND имеет приоритет над PROJECT.md (в обе стороны) ────────────────────────────
project_md 'ISSUE_BACKEND=github'
env_none_wins() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=none bash "$SUT" ticket specs/003-non 'x' ); }
t "env none поверх PROJECT.md github → exit 0" 0 env_none_wins
t_out "env none побеждает → skipped" '^skipped:issue-backend-none$'
bad_backend() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=jira bash "$SUT" ticket specs/001-gh 'x' ); }
t "env ISSUE_BACKEND=jira → exit 1" 1 bad_backend
t_out "исход error:invalid-issue-backend" '^error:invalid-issue-backend'
removed_backend() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=tracker bash "$SUT" ticket specs/001-gh 'x' ); }
t "env ISSUE_BACKEND=tracker (не поддерживается) → exit 1" 1 removed_backend
empty_backend() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND= bash "$SUT" ticket specs/001-gh 'x' ); }
t "env ISSUE_BACKEND='' (задан пустым) → exit 1" 1 empty_backend

# ── GitHub happy path (backend из PROJECT.md): created:<KEY>, привязка в state.md ──────────────
project_md 'ISSUE_BACKEND=github'
gh_ok_run() {
  ( cd "$REPO" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" FAKE_GH_DIR="$ART" \
      bash "$SUT" ticket specs/001-gh 'dashboard wish phrase' ) >"$TMP/gh.out" 2>"$TMP/gh.err"
}
gh_ok_contract() { one_line "$TMP/gh.out" && grep -Eqx 'created:#[1-9][0-9]*' "$TMP/gh.out"; }
gh_ok_linked()   { grep -q -- '- Ticket: #[1-9][0-9]*' "$REPO/specs/001-gh/state.md"; }
t "github ok → exit 0" 0 gh_ok_run
t "github ok → РОВНО одна строка stdout вида created:#<n>" 0 gh_ok_contract
t "github ok → SPEC_DIR привязан к тикету в state.md" 0 gh_ok_linked
t "github ok → репозиторий взят из origin (github.com/o/r)" 0 grep -q -- '--repo github.com/o/r' "$ART/gh-calls.txt"

# ── Идемпотентность: повтор той же SPEC → та же привязка (тот же KEY), без дубля тикета ──────────
gh_again_run() {
  rm -f "$ART/gh-create-called"
  ( cd "$REPO" && env -u ISSUE_BACKEND PATH="$BIN:$PATH" FAKE_GH_DIR="$ART" \
      bash "$SUT" ticket specs/001-gh 'dashboard wish phrase' ) >"$TMP/gh2.out" 2>"$TMP/gh2.err"
}
gh_again_contract() { one_line "$TMP/gh2.out" && grep -Eqx 'deferred:spec-already-linked KEY=#[1-9][0-9]*' "$TMP/gh2.out"; }
gh_no_recreate()    { [ ! -e "$ART/gh-create-called" ]; }
gh_binding_stable() {
  local created linked
  created="$(sed -n 's/^created:\(.*\)$/\1/p' "$TMP/gh.out")"
  linked="$(sed -n 's/^deferred:spec-already-linked KEY=\(.*\)$/\1/p' "$TMP/gh2.out")"
  [ -n "$created" ] && [ "$created" = "$linked" ]
}
t "github повтор → exit 0 (идемпотентно)" 0 gh_again_run
t "github повтор → одна строка deferred:spec-already-linked KEY=#<n>" 0 gh_again_contract
t "github повтор → тот же KEY, что при create (детерминированная привязка)" 0 gh_binding_stable
t "github повтор → дубль-тикет не создаётся (create не вызван)" 0 gh_no_recreate

# ── Деградация провайдера (FAKE_GH_DOWN): контракт держится, fixture-токен не утекает ───────────
# FAKE_GH_DOWN двойник роняет каждый gh-вызов, НАМЕРЕННО печатая fake «Bearer»-токен в свой stderr;
# intake обязан деградировать одной строкой и не отразить токен ни в stdout, ни в stderr.
gh_down_run() {
  local rc=0
  ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github FAKE_GH_DOWN=1 \
      bash "$SUT" ticket specs/002-def 'provider down phrase' ) >"$TMP/down.out" 2>"$TMP/down.err" || rc=$?
  cat "$TMP/down.out"; cat "$TMP/down.err" >&2
  return "$rc"
}
t "github down → exit 0 (deferred)" 0 gh_down_run
t_out "github down → исход deferred:* на stdout" '^deferred:'
t_out_absent "github down → fake-токен провайдера не отражён (redaction)" 'FAKEGHTOKENSECRET'
t "github down → stdout ровно одна строка" 0 one_line "$TMP/down.out"

# ── GH_REPO может только повторять origin ──────────────────────────────────────────────────────
ps_ init "$REPO/specs/004-pin" "intake pin" >/dev/null 2>&1
pin_mismatch() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github GH_REPO=evil/other FAKE_GH_DIR="$ART" \
    bash "$SUT" ticket specs/004-pin 'pin phrase' ); }
t "GH_REPO ≠ origin → exit 1" 1 pin_mismatch
t_out "исход error:github-repo-mismatch" '^error:github-repo-mismatch$'
pin_match() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github GH_REPO=github.com/o/r FAKE_GH_DIR="$ART" \
    bash "$SUT" ticket specs/004-pin 'pin phrase' ); }
t "GH_REPO = github.com/<origin> → тикет создан" 0 pin_match
t_out "исход created:#<n>" '^created:#[1-9]'

# ── не-GitHub origin при backend github → error без похода в провайдер ──────────────────────────
REPO2="$TMP/repo-nongh"
mkdir -p "$REPO2/scripts/lib"
git -C "$REPO2" init -q
git -C "$REPO2" remote add origin https://example.invalid/o/r.git
cp "$REPO/scripts/pipeline-state.sh" "$REPO/scripts/private-temp-dir.pl" "$REPO2/scripts/"
cp "$REPO/scripts/lib/pipeline-state-reader-v4.pl" "$REPO2/scripts/lib/"
ps_ init "$REPO2/specs/001-x" "non github" >/dev/null 2>&1
non_gh_origin() { ( cd "$REPO2" && PATH="$BIN:$PATH" ISSUE_BACKEND=github bash "$SUT" ticket specs/001-x 'x' ); }
t "origin не github.com → exit 1" 1 non_gh_origin
t_out "исход error:github-origin-unavailable" '^error:github-origin-unavailable$'

# ── error-контракты: машиночитаемая строка + exit 1 ─────────────────────────────────────────────
usage_run() { ( cd "$REPO" && PATH="$BIN:$PATH" bash "$SUT" ticket ); }
t "неверное число аргументов → exit 1" 1 usage_run
t_out "исход error:usage" '^error:usage'
bad_spec() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github bash "$SUT" ticket specs/BADCAPS 'x' ); }
t "SPEC_DIR вне грамматики specs/NNN-slug → exit 1" 1 bad_spec
t_out "исход error:invalid-spec-dir" '^error:invalid-spec-dir'

# ── public-репо: guard без allow, проходной с INTAKE_ALLOW_PUBLIC=1 ─────────────────────────────
ps_ init "$REPO/specs/006-pub" "intake public" >/dev/null 2>&1
pub_run() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github FAKE_GH_DIR="$ART" FAKE_GH_VISIBILITY=PUBLIC \
    bash "$SUT" ticket specs/006-pub 'public phrase' ); }
t "PUBLIC-репо без allow → exit 0 (деградация, не крэш)" 0 pub_run
t_out "исход deferred:public-repo" '^deferred:public-repo'
pub_allow() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github FAKE_GH_DIR="$ART" FAKE_GH_VISIBILITY=PUBLIC \
    INTAKE_ALLOW_PUBLIC=1 bash "$SUT" ticket specs/006-pub 'public phrase' ); }
t "PUBLIC-репо с INTAKE_ALLOW_PUBLIC=1 → тикет создан" 0 pub_allow
t_out "исход created:#<n>" '^created:#[1-9]'

# ── Scope живёт в state.md (пишет pipeline-state init), intake scope-агностичен ─────────────────
ps_ init "$REPO/specs/009-bug" "bugfix phrase" bugfix >/dev/null 2>&1
t "init bugfix → '- Scope: bugfix' в state.md" 0 grep -qx -- '- Scope: bugfix' "$REPO/specs/009-bug/state.md"
bug_bind() { ( cd "$REPO" && PATH="$BIN:$PATH" ISSUE_BACKEND=github FAKE_GH_DIR="$ART" bash "$SUT" ticket specs/009-bug 'bugfix phrase' ); }
t "bugfix-спека биндится идентично feature (scope-агностичность)" 0 bug_bind
t_out "исход created:#<n>" '^created:#[1-9]'

harness_exit
