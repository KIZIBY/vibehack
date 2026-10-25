#!/usr/bin/env bash
# tests/harness/cases/project-scripts.sh — проектные bash-обёртки scripts/{setup,build,lint,test-unit,
# test-integration,test-e2e,dev,migrate}.sh, каталоги backend/ intake/ frontend/, requirements-dev.txt и
# подключение lint/test-unit к блоку проекта в scripts/check.sh (задача T010, спека 001-ai-judge-platform).
# Инварианты: I-17 (check.sh исполним и честен), «skip ≠ pass» (SKIP печатается явно), fail-closed
# (нет pytest при наличии тестов → exit 2, а не молчаливый pass).
# Поведение скриптов проверяется на КОПИИ проекта под $TMP; интерпретаторы (.venv/bin/python, python3,
# python) и npm подменены заглушками, пишущими argv в $STUB_LOG: тест не зависит от установленного
# pytest/npm/pip и сети.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "project-scripts (scripts/*.sh проекта · каталоги · requirements-dev · check.sh)"

# ── хелперы ──
mode_of() { perl -e 'printf "%o\n", ((stat $ARGV[0])[2] // 0) & 07777' "$1"; }
mode755() { [ "$(mode_of "$1")" = 755 ]; }
shebang_ok() { [ "$(head -n 1 "$1" 2>/dev/null)" = '#!/bin/bash' ]; }
tracked_dir() { [ -d "$ROOT/$1" ] && [ -n "$(git -C "$ROOT" ls-files --cached --others --exclude-standard -- "$1" | head -n 1)" ]; }
# «упал по-настоящему»: ненулевой код, но не 127 (скрипта нет) и не 126 (не исполняется)
real_nonzero() { local rc=0; "$@" || rc=$?; [ "$rc" -ne 0 ] && [ "$rc" -ne 127 ] && [ "$rc" -ne 126 ]; }

# ── 1. каталоги компонентов существуют и отслеживаются git ──
for d in backend intake frontend; do
  t "каталог $d/ существует и содержит отслеживаемый файл" 0 tracked_dir "$d"
done

# ── 2. исполняемые bash-обёртки (mode 755, shebang ровно #!/bin/bash) ──
for s in setup build lint test-unit test-integration test-e2e dev migrate; do
  t "scripts/$s.sh: mode 755" 0 mode755 "$ROOT/scripts/$s.sh"
  t "scripts/$s.sh: shebang ровно #!/bin/bash" 0 shebang_ok "$ROOT/scripts/$s.sh"
done

# ── 5a. requirements-dev.txt: минимальный набор dev-зависимостей ──
REQ="$ROOT/requirements-dev.txt"
for pkg in pytest jsonschema pyyaml openapi-spec-validator ruff; do
  t "requirements-dev.txt содержит $pkg" 0 grep -iqE "^${pkg}(\$|[^A-Za-z0-9_-])" "$REQ"
done

# ── 4a. check.sh: блок проекта подключает lint и test-unit ──
CHECK="$ROOT/scripts/check.sh"
t "check.sh: PROJECT_CHECKS=1" 0 grep -qx 'PROJECT_CHECKS=1' "$CHECK"
sed -n '/# --- начало блока проекта ---/,/# --- конец блока проекта ---/p' "$CHECK" > "$TMP/block.txt"
t "check.sh: блок проекта вызывает lint.sh с || exit \$?" 0 \
  grep -qE 'bash scripts/lint\.sh[[:space:]]*\|\|[[:space:]]*exit[[:space:]]+\$\?' "$TMP/block.txt"
t "check.sh: блок проекта вызывает test-unit.sh all с || exit \$?" 0 \
  grep -qE 'bash scripts/test-unit\.sh all[[:space:]]*\|\|[[:space:]]*exit[[:space:]]+\$\?' "$TMP/block.txt"

# ── заглушки интерпретаторов и npm ──
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"
write_py_stub() { # <путь> <тег в логе>
  cat > "$1" <<EOF
#!/bin/bash
printf '%s %s\n' "$2" "\$*" >> "\$STUB_LOG"
if [ "\${1:-}" = "-m" ] && [ "\${2:-}" = "pytest" ] && [ "\${3:-}" = "--version" ]; then
  exit "\${STUB_PYTEST_VERSION_RC:-0}"
fi
exit "\${STUB_RC:-0}"
EOF
  chmod +x "$1"
}
write_py_stub "$STUBBIN/python3" py3
write_py_stub "$STUBBIN/python" py3
cat > "$STUBBIN/npm" <<'EOF'
#!/bin/bash
printf 'npm %s cwd=%s\n' "$*" "$PWD" >> "$STUB_LOG"
exit "${STUB_NPM_RC:-0}"
EOF
chmod +x "$STUBBIN/npm"
export STUB_LOG
export PATH="$STUBBIN:$PATH"
unset STUB_RC STUB_PYTEST_VERSION_RC STUB_NPM_RC SETUP_DRY_RUN

mkproj() { # <каталог> [novenv] — копия scripts/ + заглушка .venv/bin/python
  mkdir -p "$1"; cp -R "$ROOT/scripts" "$1/scripts"
  if [ "${2:-}" != novenv ]; then
    mkdir -p "$1/.venv/bin"; write_py_stub "$1/.venv/bin/python" venv
  fi
}
mktest() { mkdir -p "$1/$(dirname "$2")"; printf 'def test_x():\n    assert True\n' > "$1/$2"; }
ut() { : > "$STUB_LOG"; env "$@"; }   # сброс лога + запуск с env-присваиваниями
loggrep() { grep -qE -- "$1" "$STUB_LOG"; }
lognot() { ! grep -qE -- "$1" "$STUB_LOG"; }

# ── 3. scripts/test-unit.sh [зона] ──
P="$TMP/proj"; mkproj "$P"
UT="$P/scripts/test-unit.sh"

t "test-unit: неизвестная зона → exit 2" 2 ut bash "$UT" bogus
t_out "test-unit: неизвестная зона → сообщение" 'bogus|зон|zone|[Uu]sage'
t "test-unit: неизвестная зона не запускает интерпретатор" 0 lognot '.'

# зоны без тестов → SKIP и 0 (skip ≠ pass: слово SKIP обязано быть в выводе)
t "test-unit backend без тестов → exit 0" 0 ut bash "$UT" backend
t_out "test-unit backend без тестов → SKIP backend: тестов нет" 'SKIP backend: тестов нет'
t "test-unit backend без тестов → pytest не запускался" 0 lognot 'pytest .*tests'
t "test-unit intake без тестов → exit 0" 0 ut bash "$UT" intake
t_out "test-unit intake без тестов → SKIP intake: тестов нет" 'SKIP intake: тестов нет'
t "test-unit frontend без package.json → exit 0" 0 ut bash "$UT" frontend
t_out "test-unit frontend без package.json → SKIP frontend: тестов нет" 'SKIP frontend: тестов нет'
t "test-unit frontend без package.json → npm не запускался" 0 lognot '^npm '
t "test-unit без аргумента (= all), тестов нет → exit 0" 0 ut bash "$UT"
t_out "test-unit all: SKIP по backend" 'SKIP backend: тестов нет'
t_out "test-unit all: SKIP по intake" 'SKIP intake: тестов нет'
t_out "test-unit all: SKIP по frontend" 'SKIP frontend: тестов нет'

# python-зоны: pytest через .venv/bin/python
mktest "$P" tests/backend/test_a.py
mktest "$P" tests/intake/test_b.py
t "test-unit backend с тестами → exit 0" 0 ut bash "$UT" backend
t "test-unit backend: pytest на tests/backend через .venv/bin/python" 0 loggrep '^venv .*-m pytest.*tests/backend'
t "test-unit backend: системный python3 не использован при наличии .venv" 0 lognot '^py3 '
t "test-unit backend не гоняет intake" 0 lognot 'tests/intake'
t "test-unit intake с тестами → exit 0" 0 ut bash "$UT" intake
t "test-unit intake: pytest на tests/intake через .venv/bin/python" 0 loggrep '^venv .*-m pytest.*tests/intake'
t "test-unit intake не гоняет backend" 0 lognot 'tests/backend'

# красный раннер зоны → 1 и имя зоны в выводе
t "test-unit backend: красный pytest → exit 1" 1 ut STUB_RC=1 bash "$UT" backend
t_out "test-unit backend: красная зона названа" 'backend'
t "test-unit intake: красный pytest → exit 1" 1 ut STUB_RC=1 bash "$UT" intake
t_out "test-unit intake: красная зона названа" 'intake'

# pytest недоступен при наличии тестов → fail-closed, exit 2 + подсказка setup.sh
t "test-unit backend: pytest недоступен → exit 2 (fail-closed)" 2 ut STUB_PYTEST_VERSION_RC=1 bash "$UT" backend
t_out "test-unit backend: подсказка bash scripts/setup.sh" 'bash scripts/setup\.sh'
t_out_absent "test-unit backend: недоступный pytest не выдан за SKIP" 'SKIP backend'
t "test-unit intake: pytest недоступен → exit 2 (fail-closed)" 2 ut STUB_PYTEST_VERSION_RC=1 bash "$UT" intake

# код 5 pytest (тесты не собраны) при наличии файлов тестов — ошибка, не SKIP
t "test-unit backend: pytest exit 5 при наличии тестов → exit 1" 1 ut STUB_RC=5 bash "$UT" backend
t_out_absent "test-unit backend: pytest exit 5 не выдан за SKIP" 'SKIP backend'

# нет .venv → системный python3
mkproj "$TMP/novenv" novenv; mktest "$TMP/novenv" tests/backend/test_a.py
t "test-unit backend без .venv → python3, exit 0" 0 ut bash "$TMP/novenv/scripts/test-unit.sh" backend
t "test-unit backend без .venv: pytest через python3" 0 loggrep '^py3 .*-m pytest.*tests/backend'

# hermes: unittest discover
mktest "$P" hermes/tests/test_h.py
t "test-unit hermes → exit 0" 0 ut bash "$UT" hermes
t "test-unit hermes: -m unittest discover -s hermes/tests" 0 loggrep '-m unittest discover -s hermes/tests'
t "test-unit hermes: красный раннер → exit 1" 1 ut STUB_RC=1 bash "$UT" hermes
t_out "test-unit hermes: красная зона названа" 'hermes'

# frontend: npm test в frontend/ только при наличии package.json
mkdir -p "$P/frontend"; printf '{"name":"x","scripts":{"test":"true"}}\n' > "$P/frontend/package.json"
t "test-unit frontend с package.json → exit 0" 0 ut bash "$UT" frontend
t "test-unit frontend: npm test в каталоге frontend/" 0 loggrep '^npm test cwd=.*/frontend$'
t "test-unit frontend: красный npm → exit 1" 1 ut STUB_NPM_RC=1 bash "$UT" frontend
t_out "test-unit frontend: красная зона названа" 'frontend'

# all: все зоны запускаются; красная зона → красный итог
t "test-unit all (без аргумента), все зоны с тестами → exit 0" 0 ut bash "$UT"
t "test-unit all: запущены backend, intake, hermes, frontend" 0 sh -c \
  'grep -qE "tests/backend" "$1" && grep -qE "tests/intake" "$1" && grep -qE "unittest discover" "$1" && grep -qE "^npm test" "$1"' _ "$STUB_LOG"
t "test-unit all: красная зона → exit 1" 1 ut STUB_RC=1 bash "$UT" all
t_out "test-unit all: красная зона названа" 'backend|intake|hermes'

# ── 3a. единое соглашение об именах: тестом считается только test_*.py (pytest и unittest discover) ──
N="$TMP/naming"; mkproj "$N"; NU="$N/scripts/test-unit.sh"
mktest "$N" tests/backend/x_test.py
t "test-unit backend: только x_test.py (нет test_*.py) → exit 0" 0 ut bash "$NU" backend
t_out "test-unit backend: только x_test.py → SKIP backend: тестов нет" 'SKIP backend: тестов нет'
t "test-unit backend: только x_test.py → интерпретатор не вызывался" 0 lognot '.'
mktest "$N" hermes/tests/x_test.py
t "test-unit hermes: только x_test.py (нет test_*.py) → exit 0" 0 ut bash "$NU" hermes
t_out "test-unit hermes: только x_test.py → SKIP hermes: тестов нет" 'SKIP hermes: тестов нет'
t "test-unit hermes: только x_test.py → unittest не вызывался" 0 lognot '.'
mktest "$N" tests/backend/test_ok.py
mktest "$N" hermes/tests/test_ok.py
t "test-unit backend: test_ok.py рядом с x_test.py → exit 0" 0 ut bash "$NU" backend
t "test-unit backend: test_ok.py рядом с x_test.py → pytest запущен" 0 loggrep '^venv .*-m pytest.*tests/backend'
t "test-unit hermes: test_ok.py рядом с x_test.py → exit 0" 0 ut bash "$NU" hermes
t "test-unit hermes: test_ok.py рядом с x_test.py → unittest запущен" 0 loggrep '-m unittest discover -s hermes/tests'

# ── 3b. ошибка чтения каталога тестов ≠ «тестов нет» (fail-closed) ──
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
Q="$TMP/perm"; mkproj "$Q"
mktest "$Q" tests/backend/test_a.py
mktest "$Q" tests/integration/test_a.py
unreadable() { # <каталог> <команда…> — запуск при chmod 000, права возвращаются всегда
  local d="$1" rc=0; shift
  chmod 000 "$d"; ut "$@" || rc=$?; chmod 755 "$d"
  return "$rc"
}
if [ "$(id -u)" -eq 0 ]; then
  for what in "backend: exit 2" "backend: tests/backend в выводе" "backend: не удалось прочитать" "backend: нет SKIP" \
              "integration: exit 2" "integration: tests/integration в выводе" "integration: не удалось прочитать" "integration: нет SKIP"; do
    ok "пропуск: запуск от root (chmod 000 не ограничивает чтение) — $what"
  done
else
  t "test-unit backend: tests/backend нечитаем → exit 2" 2 unreadable "$Q/tests/backend" bash "$Q/scripts/test-unit.sh" backend
  t_out "test-unit backend: нечитаемый каталог назван (tests/backend)" 'tests/backend'
  t_out "test-unit backend: сообщение «не удалось прочитать»" 'не удалось прочитать'
  t_out_absent "test-unit backend: нечитаемый каталог не выдан за SKIP" 'SKIP backend'
  t "test-integration: tests/integration нечитаем → exit 2" 2 unreadable "$Q/tests/integration" bash "$Q/scripts/test-integration.sh"
  t_out "test-integration: нечитаемый каталог назван (tests/integration)" 'tests/integration'
  t_out "test-integration: сообщение «не удалось прочитать»" 'не удалось прочитать'
  t_out_absent "test-integration: нечитаемый каталог не выдан за SKIP" 'SKIP integration'
fi

# ── 4b. check.sh на копии: lint + test-unit в составе, красное красит check.sh ──
C="$TMP/chk"; mkproj "$C"
t "check.sh (копия, зоны без тестов) → exit 0" 0 ut bash "$C/scripts/check.sh"
t_out "check.sh: итог OK" '^check: OK'
t_out_absent "check.sh: строки NOTE про ненастроенные проверки больше нет" 'проверки проекта не настроены'
mktest "$C" tests/backend/test_a.py
t "check.sh: красная зона → check.sh красный (exit 1)" 1 ut STUB_RC=1 bash "$C/scripts/check.sh"
t_out "check.sh: красная зона и шаг названы" 'backend'
t "check.sh: зелёные зоны с тестами → exit 0" 0 ut bash "$C/scripts/check.sh"
t "check.sh: pytest реально вызван из блока проекта" 0 loggrep '-m pytest.*tests/backend'
printf '#!/bin/bash\necho "lint: красный"\nexit 3\n' > "$C/scripts/lint.sh"
t "check.sh: красный lint → check.sh красный (код lint.sh = 3)" 3 ut bash "$C/scripts/check.sh"
t_out "check.sh: красный lint назван" 'lint'

# ── 5b. scripts/setup.sh ──
S="$TMP/setup"; mkproj "$S" novenv
printf 'pytest\n' > "$S/requirements-dev.txt"
t "setup.sh SETUP_DRY_RUN=1 → exit 0" 0 ut SETUP_DRY_RUN=1 bash "$S/scripts/setup.sh"
t_out "setup.sh dry-run: печатает создание .venv" '\.venv'
t_out "setup.sh dry-run: печатает установку requirements-dev.txt" 'requirements-dev\.txt'
t_out_absent "setup.sh dry-run: без frontend/package.json нет npm install" 'npm install'
t "setup.sh dry-run: .venv не создан" 0 test ! -e "$S/.venv"
t "setup.sh dry-run: pip/venv/npm install не запускались" 0 lognot 'pip|-m venv|install'
mkdir -p "$S/frontend"; printf '{"name":"x"}\n' > "$S/frontend/package.json"
t "setup.sh dry-run с frontend/package.json → exit 0" 0 ut SETUP_DRY_RUN=1 bash "$S/scripts/setup.sh"
t_out "setup.sh dry-run с package.json: печатает npm install" 'npm install'
t "setup.sh dry-run с package.json: npm не запускался" 0 lognot '^npm '
t "setup.sh dry-run: node_modules не создан" 0 test ! -e "$S/frontend/node_modules"
t "setup.sh в настоящем режиме падает при ошибке установки" 0 real_nonzero ut STUB_RC=1 STUB_NPM_RC=1 bash "$S/scripts/setup.sh"

# ── 5c. backend/requirements.txt (T012): setup.sh ставит его, если файл есть ──
S2="$TMP/setup2"; mkproj "$S2" novenv
printf 'pytest\n' > "$S2/requirements-dev.txt"
t "setup.sh dry-run без backend/requirements.txt → exit 0" 0 ut SETUP_DRY_RUN=1 bash "$S2/scripts/setup.sh"
t_out_absent "setup.sh dry-run без backend/requirements.txt: про него ничего не печатается" 'backend/requirements\.txt'
mkdir -p "$S2/backend"; printf 'alembic\nsqlalchemy\n' > "$S2/backend/requirements.txt"
t "setup.sh dry-run с backend/requirements.txt → exit 0" 0 ut SETUP_DRY_RUN=1 bash "$S2/scripts/setup.sh"
t_out "setup.sh dry-run с backend/requirements.txt: печатает его установку" 'backend/requirements\.txt'
t "setup.sh dry-run с backend/requirements.txt: pip не запускался" 0 lognot 'pip|-m venv|install'
BREQ="$ROOT/backend/requirements.txt"
t "backend/requirements.txt содержит alembic" 0 grep -iqE '^alembic($|[^A-Za-z0-9_-])' "$BREQ"
t "backend/requirements.txt содержит sqlalchemy" 0 grep -iqE '^sqlalchemy($|[^A-Za-z0-9_-])' "$BREQ"

# ── 6. dev.sh / migrate.sh без компонентов; остальные обёртки — SKIP и 0 ──
B="$TMP/bare"; mkproj "$B"
t "dev.sh без backend/app/main.py → exit 1" 1 ut bash "$B/scripts/dev.sh"
t_out "dev.sh: сообщение с номером задачи T020" 'T020'
t "migrate.sh без backend/alembic.ini → exit 1" 1 ut bash "$B/scripts/migrate.sh"
t_out "migrate.sh: сообщение с номером задачи T012" 'T012'
for s in build lint test-integration test-e2e; do
  t "$s.sh без компонентов → exit 0" 0 ut bash "$B/scripts/$s.sh"
  t_out "$s.sh без компонентов → SKIP" 'SKIP'
done

harness_exit
