#!/usr/bin/env bash
# Репозиторий с State V4 спекой без тикета; провайдер — fake-gh на PATH (без сети).
set -uo pipefail
H="${HARNESS_EVAL_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
printf '%s\n' "$H" > .harness-root
git init -q
git config user.email eval@example.invalid
git config user.name "Harness Eval"
git remote add origin https://github.com/example/eval-intake.git
mkdir -p scripts/lib bin bin-sut
cp "$H/scripts/pipeline-state.sh" scripts/
cp "$H/scripts/private-temp-dir.pl" scripts/
cp "$H/scripts/lib/pipeline-state-reader-v4.pl" scripts/lib/
for s in intake.sh provider-env.pl private-temp-dir.pl secret-patterns.sh; do
  cp "$H/scripts/$s" bin-sut/
done
cp "$H/tests/harness/fixtures/fake-gh-intake.sh" bin/gh
chmod 0755 bin/gh
bash scripts/pipeline-state.sh init specs/001-int "intake eval wish" >/dev/null 2>&1
printf 'x\n' > README.md
printf '# PROJECT.md\n\nISSUE_BACKEND=github\n' > PROJECT.md
git add -A
git commit -qm base
