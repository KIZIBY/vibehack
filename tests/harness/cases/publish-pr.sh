#!/usr/bin/env bash
# tests/harness/cases/publish-pr.sh — PR-режим agent-publish-main.sh (режим по умолчанию на
# feature-ветке; устав I-10). Контракт: публикация = подготовка ветки к PR (fetch → rebase на
# origin/main → scripts/check.sh → push --force-with-lease -u ветки → подсказка открыть PR), main
# НЕ трогается, DORA-событие publish:pr (не deploy:*). Негативы: грязное tracked-дерево → отказ;
# красный check.sh → отказ без push; нет check.sh → отказ (AGENT_PUBLISH_SKIP_TESTS=1 — осознанный
# обход с WARN); rebase-конфликт → abort + отказ (дерево восстановлено); AGENT_PUBLISH_MODE=pr на
# main → отказ. Фикстура герметична: bare-origin + два клона (второй двигает main).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "publish PR-режим (rebase → check.sh → push ветки · main не трогается)"

PUB="$ROOT/scripts/agent-publish-main.sh"
unset AGENT_PUBLISH_MODE AGENT_PUBLISH_SKIP_TESTS

ORIGIN="$TMP/origin.git"; W1="$TMP/w1"; W2="$TMP/w2"
git init -q --bare -b main "$ORIGIN"
setup_clone() { # $1 dir
  git init -q -b main "$1"
  git -C "$1" config user.email fixture@example.invalid
  git -C "$1" config user.name fixture
  git -C "$1" config commit.gpgsign false
  git -C "$1" remote add origin "$ORIGIN"
}
setup_clone "$W1"
echo base > "$W1/README.md"
# check.sh фикстуры: пишет маркер (доказательство запуска) и падает, если есть файл FAIL_CHECK.
mkdir -p "$W1/scripts"
cat > "$W1/scripts/check.sh" <<'EOF'
#!/bin/bash
echo ran >> "$(git rev-parse --git-dir)/check-ran"
[ ! -e FAIL_CHECK ]
EOF
printf 'FAIL_CHECK\ncheck-ran\n' > "$W1/.gitignore"
git -C "$W1" add README.md scripts/check.sh .gitignore
git -C "$W1" commit -qm init && git -C "$W1" push -qu origin main 2>/dev/null

git init -q "$W2"; git -C "$W2" remote add origin "$ORIGIN"
git -C "$W2" fetch -q origin && git -C "$W2" config user.email other@example.invalid && git -C "$W2" config user.name other
git -C "$W2" checkout -q -b main origin/main

# feature-ветка в W1 с одним коммитом
git -C "$W1" checkout -q -b feature/x
mkdir -p "$W1/src"; echo one > "$W1/src/f.txt"
git -C "$W1" add src/f.txt && git -C "$W1" commit -qm "feat: one"

main_before="$(git -C "$ORIGIN" rev-parse main)"
run_pub() { (cd "$W1" && bash "$PUB"); }
check_runs() { [ -f "$W1/.git/check-ran" ] && wc -l < "$W1/.git/check-ran" | tr -d ' ' || echo 0; }
same_main() { [ "$(git -C "$ORIGIN" rev-parse main)" = "$main_before" ]; }
journal_rows() { grep -c "^| [^|]* | $1 |" "$W1/docs/ops-journal.md" 2>/dev/null || true; }

# ── happy path: ветка запушена, main не тронут, check.sh отработал ──
t "pr: feature-ветка → exit 0" 0 run_pub
t_out "pr: отчитался о push ветки" 'ветка feature/x отправлена'
t_out "pr: подсказка открыть PR" 'открой PR'
t "pr: ветка появилась в origin" 0 git -C "$ORIGIN" rev-parse --verify refs/heads/feature/x
t "pr: main в origin НЕ изменился" 0 same_main
t "pr: scripts/check.sh выполнен ровно один раз" 0 test "$(check_runs)" = 1
t "pr: DORA-событие publish:pr записано" 0 test "$(journal_rows publish:pr)" = 1
t "pr: deploy:* и publish:done НЕ пишутся" 0 sh -c '! grep -Eq "^\| [^|]* \| (deploy:|publish:done)" "$1"' _ "$W1/docs/ops-journal.md"
git -C "$W1" checkout -q -- . 2>/dev/null; rm -rf "$W1/docs"

# ── повторный прогон — идемпотентно ok ──
t "pr: повторный прогон без изменений → exit 0" 0 run_pub

# ── rebase: main ушёл вперёд (W2), PR-режим переносит ветку ──
echo w2 > "$W2/other.txt"; git -C "$W2" add other.txt && git -C "$W2" commit -qm "feat: w2" && git -C "$W2" push -q origin main
echo two > "$W1/src/g.txt"; git -C "$W1" add src/g.txt && git -C "$W1" commit -qm "feat: two"
rm -rf "$W1/docs"
t "pr: main ушёл вперёд → rebase + push, exit 0" 0 run_pub
descends() { # HEAD ветки построен от свежей вершины main (fast-forward возможен)
  git -C "$W1" fetch -q origin
  [ "$(git -C "$W1" merge-base origin/main HEAD)" = "$(git -C "$W1" rev-parse origin/main)" ]
}
t "pr: после rebase ветка сидит на вершине main (FF возможен)" 0 descends
pushed_is_head() { [ "$(git -C "$ORIGIN" rev-parse refs/heads/feature/x)" = "$(git -C "$W1" rev-parse HEAD)" ]; }
t "pr: в origin ровно перенесённый HEAD ветки" 0 pushed_is_head
rm -rf "$W1/docs"

# ── GitHub-origin → подсказка gh pr create (транспорт перенаправлен на bare через insteadOf) ──
git -C "$W1" remote set-url origin https://github.com/acme/repo.git
git -C "$W1" config "url.$ORIGIN.insteadOf" https://github.com/acme/repo.git
echo gh > "$W1/src/gh.txt"; git -C "$W1" add src/gh.txt && git -C "$W1" commit -qm "feat: gh"
t "pr: GitHub-origin → exit 0" 0 run_pub
t_out "pr: подсказка gh pr create --fill" 'gh pr create --fill --base main --head feature/x'
git -C "$W1" config --unset "url.$ORIGIN.insteadOf"
git -C "$W1" remote set-url origin "$ORIGIN"
rm -rf "$W1/docs"

# ── красный check.sh → отказ без push ──
echo three > "$W1/src/h.txt"; git -C "$W1" add src/h.txt && git -C "$W1" commit -qm "feat: three"
touch "$W1/FAIL_CHECK"
branch_before="$(git -C "$ORIGIN" rev-parse refs/heads/feature/x)"
t "pr: красный scripts/check.sh → отказ (exit 1)" 1 run_pub
t_out "pr: отказ называет check.sh" 'check.sh'
branch_same() { [ "$(git -C "$ORIGIN" rev-parse refs/heads/feature/x)" = "$branch_before" ]; }
t "pr: красные проверки → ветка в origin не сдвинулась" 0 branch_same
skip_pub() { (cd "$W1" && AGENT_PUBLISH_SKIP_TESTS=1 bash "$PUB"); }
t "pr: AGENT_PUBLISH_SKIP_TESTS=1 → осознанный обход, exit 0" 0 skip_pub
t_out "pr: обход проверок честно предупреждает" 'WARN проверки пропущены'
rm -f "$W1/FAIL_CHECK"; rm -rf "$W1/docs"

# ── нет scripts/check.sh → отказ (нечем проверить) ──
git -C "$W1" rm -q scripts/check.sh && git -C "$W1" commit -qm "chore: drop check"
t "pr: нет scripts/check.sh → отказ (exit 1)" 1 run_pub
t_out "pr: отказ объясняет отсутствие check.sh" 'scripts/check.sh не найден'
git -C "$W1" revert --no-edit -q HEAD >/dev/null 2>&1

# ── ветка без коммитов поверх main → PR не нужен, push не выполняется ──
git -C "$W1" fetch -q origin
git -C "$W1" checkout -q -b feature/empty origin/main
run_pub_empty() { (cd "$W1" && bash "$PUB"); }
t "pr: пустая ветка → exit 0 без push" 0 run_pub_empty
t_out "pr: пустая ветка — PR не нужен" 'PR не нужен'
t "pr: пустая ветка не появилась в origin" 1 git -C "$ORIGIN" rev-parse --verify -q refs/heads/feature/empty
git -C "$W1" checkout -q feature/x

# ── AGENT_PUBLISH_MODE=pr на main → отказ ──
pr_on_main() { (cd "$W2" && AGENT_PUBLISH_MODE=pr bash "$PUB"); }
t "pr: AGENT_PUBLISH_MODE=pr на main → отказ (exit 1)" 1 pr_on_main
t_out "pr: отказ требует feature-ветку" 'требует feature-ветку'

# ── негатив: грязное tracked-дерево ──
echo dirty >> "$W1/src/f.txt"
t "pr: грязное tracked-дерево → отказ (exit 1)" 1 run_pub
git -C "$W1" checkout -q -- src/f.txt

# ── негатив: rebase-конфликт → abort + честный отказ, дерево восстановлено ──
git -C "$W2" fetch -q origin
git -C "$W2" reset -q --hard origin/main
mkdir -p "$W2/src"; echo conflict-main > "$W2/src/f.txt"
git -C "$W2" add src/f.txt && git -C "$W2" commit -qm "feat: conflict" && git -C "$W2" push -q origin main
echo conflict-branch > "$W1/src/f.txt"
git -C "$W1" add src/f.txt && git -C "$W1" commit -qm "feat: mine"
head_before="$(git -C "$W1" rev-parse HEAD)"
t "pr: rebase-конфликт → отказ (exit 1)" 1 run_pub
t_out "pr: отказ называет rebase" 'rebase'
no_rebase_state() { [ ! -d "$W1/.git/rebase-merge" ] && [ ! -d "$W1/.git/rebase-apply" ]; }
t "pr: rebase abort — состояния rebase нет" 0 no_rebase_state
head_intact() { [ "$(git -C "$W1" rev-parse HEAD)" = "$head_before" ]; }
t "pr: HEAD ветки не изменён (abort вернул как было)" 0 head_intact

harness_exit
