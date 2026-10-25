#!/usr/bin/env bash
# tests/harness/cases/check-entrypoint.sh — единая точка проверок scripts/check.sh и CLI раннера
# tests/harness/run-tests.sh. Инвариант: I-17 (конвенция «перед коммитом — check.sh» исполнима).
# Контракт check.sh: исполняемый bash-wrapper; при наличии tests/harness/ зовёт раннер с
# `--tier fast` и наследует его красный код; без tests/harness/ — одна строка SKIP, exit 0;
# пустой блок проверок проекта честно помечен NOTE. Контракт раннера: позиционные `fast|full` —
# алиасы `--tier`, неизвестный флаг → exit 2. Всё на копиях под $TMP (без рекурсии в реальный сьют).
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "check-entrypoint (scripts/check.sh · run-tests CLI)"

CHECK="$ROOT/scripts/check.sh"
t "check.sh исполняемый (mode 100755)" 0 test -x "$CHECK"
t "check.sh — bash-wrapper (shebang /bin/bash)" 0 sh -c 'head -1 "$1" | grep -qx "#!/bin/bash"' _ "$CHECK"

# ── проект без tests/harness/: SKIP + NOTE, exit 0 ──
# После T010 реальный check.sh вызывает lint.sh/test-unit.sh из блока проекта; здесь проверяется
# именно контракт обёртки, поэтому берём шаблон «пустого блока»: реальный check.sh, из которого
# вырезано всё между маркерами блока проекта, и PROJECT_CHECKS=0.
P="$TMP/proj"; mkdir -p "$P/scripts"
empty_block_template() {
  awk '/# --- начало блока проекта ---/ { print; skip = 1; next }
       /# --- конец блока проекта ---/ { skip = 0 }
       !skip { print }' "$CHECK" | sed 's/^PROJECT_CHECKS=.*/PROJECT_CHECKS=0/' > "$P/scripts/check.sh"
}
t "шаблон пустого блока собран из реального check.sh" 0 empty_block_template
t "шаблон: PROJECT_CHECKS=0 и маркеры блока на месте" 0 sh -c \
  'grep -qx "PROJECT_CHECKS=0" "$1" && grep -q "начало блока проекта" "$1" && grep -q "конец блока проекта" "$1"' _ "$P/scripts/check.sh"
t "без tests/harness/ → exit 0" 0 bash "$P/scripts/check.sh"
t_out "без tests/harness/ → одна строка SKIP" '^check: SKIP self-test'
t_out "пустой блок проекта честно помечен NOTE" '^check: NOTE проверки проекта не настроены'

# ── tests/harness/ есть: раннер зовётся с --tier fast, его красный код наследуется ──
mkdir -p "$P/tests/harness"
printf '#!/bin/bash\nprintf "%%s\\n" "$*" > "%s/runner.argv"\nexit "${FAKE_RUNNER_RC:-0}"\n' "$TMP" \
  > "$P/tests/harness/run-tests.sh"
t "зелёный раннер → exit 0" 0 bash "$P/scripts/check.sh"
t "раннер вызван ровно с --tier fast" 0 grep -qx -- '--tier fast' "$TMP/runner.argv"
red_runner() { FAKE_RUNNER_RC=1 bash "$P/scripts/check.sh"; }
t "красный раннер → check.sh красный (exit 1)" 1 red_runner
t_out "красный раннер назван" 'self-test харнесса красный'

# ── CLI раннера на изолированной копии: позиционный tier = --tier ──
RR="$TMP/runner"; mkdir -p "$RR/tests/harness/cases" "$RR/tests/harness/lib"
cp "$ROOT/tests/harness/run-tests.sh" "$RR/tests/harness/run-tests.sh"
printf 'a.sh fast 1\nb.sh full 1\n' > "$RR/tests/harness/tiers.tsv"
printf 'echo "── a ──"; echo "ok    a"\n' > "$RR/tests/harness/cases/a.sh"
printf 'echo "── b ──"; echo "ok    b"\n' > "$RR/tests/harness/cases/b.sh"
rt() { RT_SUITE_HARD_CAP=0 bash "$RR/tests/harness/run-tests.sh" "$@" </dev/null; }
t "runner: позиционный fast → exit 0" 0 rt fast
t_out "runner: fast = только fast-кейсы" 'ИТОГ: pass=1 fail=0 cases=1 tier=fast'
t "runner: --tier fast → exit 0" 0 rt --tier fast
t_out "runner: --tier fast эквивалентен позиционному" 'cases=1 tier=fast'
t "runner: позиционный full → exit 0" 0 rt full
t_out "runner: full = fast + full" 'ИТОГ: pass=2 fail=0 cases=2 tier=full'
t "runner: неизвестный флаг → exit 2" 2 rt --bogus

harness_exit
