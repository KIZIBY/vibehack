#!/usr/bin/env bash
# Рабочая копия с одним неопубликованным коммитом и герметичным bare-origin (file://).
set -uo pipefail
H="${HARNESS_EVAL_ROOT:-$(cd "$(dirname "$0")/../../.." && pwd)}"
printf '%s\n' "$H" > .harness-root
git init -q
git config user.email eval@example.invalid
git config user.name "Harness Eval"
printf '.origin.git/\n.harness-root\n.expected-oid\n' > .gitignore
printf 'base\n' > f.txt
git add -A
git commit -qm c1
git init -q --bare .origin.git
git remote add origin "file://$PWD/.origin.git"
git push -q origin HEAD:main
printf 'next\n' >> f.txt
git add f.txt
git commit -qm c2
git rev-parse HEAD > .expected-oid
