# scripts/lib/project-env.sh — общие помощники проектных обёрток (source из scripts/*.sh).
# Интерпретатор: .venv/bin/python (его создаёт scripts/setup.sh), иначе системный python3.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT" || { echo "FATAL: корень репозитория недоступен" >&2; exit 2; }

if [ -x "$ROOT/.venv/bin/python" ]; then PY="$ROOT/.venv/bin/python"; else PY=python3; fi

# scan_tests <каталог> — ищет файлы тестов test_*.py (соглашение проекта: его видят и pytest, и unittest).
# 0 — тесты есть · 1 — нет каталога или в нём нет тестов · 2 — каталог не удалось прочитать (сообщение в stderr)
scan_tests() {
  [ -d "$1" ] || return 1
  local found rc=0
  found="$(find "$1" -name 'test_*.py' -print -quit 2>/dev/null)" || rc=$?
  [ -n "$found" ] && return 0
  if [ "$rc" -ne 0 ]; then
    echo "test: не удалось прочитать каталог тестов $1" >&2
    return 2
  fi
  return 1
}

# run_pytest <метка> <каталог> — pytest на каталоге тестов.
# 0 — зелёный или тестов нет (печатается SKIP: skip ≠ pass); 1 — красный; 2 — нет pytest (fail-closed).
run_pytest() {
  local label="$1" dir="$2" rc=0 scan=0
  scan_tests "$dir" || scan=$?
  if [ "$scan" -eq 2 ]; then return 2; fi
  if [ "$scan" -eq 1 ]; then
    echo "SKIP $label: тестов нет"
    return 0
  fi
  if ! "$PY" -m pytest --version >/dev/null 2>&1; then
    echo "test: pytest недоступен для $label — выполни: bash scripts/setup.sh" >&2
    return 2
  fi
  "$PY" -m pytest -q "$dir" || rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "FAIL $label: pytest завершился с кодом $rc" >&2
    return 1
  fi
}
