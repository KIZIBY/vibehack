#!/usr/bin/env bash
# tests/harness/cases/dev-env.sh — общий том и окружение разработки (задача T014, спека 001-ai-judge-platform):
# том workspaces в hermes/docker-compose.yml, корневой .env.example (девять имён, без секретов),
# .gitignore (.env, data/), поведение scripts/dev.sh: подхват .env, создание JUDGE_DATA_DIR, запуск fake-шлюза.
# dev.sh проверяется на КОПИИ проекта под $TMP; интерпретатор (.venv/bin/python) подменён заглушкой,
# пишущей argv, cwd и переменные окружения в $STUB_LOG — тест не зависит от uvicorn/сети.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "dev-env (общий том · .env.example · .gitignore · scripts/dev.sh)"

# ── 1. hermes/docker-compose.yml: общий том материалов ──
COMPOSE="$ROOT/hermes/docker-compose.yml"
t "compose: том \${JUDGE_DATA_DIR:-./data} → /opt/data/workspaces" 0 \
  grep -qE '^[[:space:]]*-[[:space:]]*"?\$\{JUDGE_DATA_DIR:-\./data\}:/opt/data/workspaces"?[[:space:]]*(#.*)?$' "$COMPOSE"
t "compose: том workspaces смонтирован один раз" 0 test "$(grep -c ':/opt/data/workspaces' "$COMPOSE")" -eq 1
t "compose: том workspaces не read-only (backend пишет, Hermes читает — права на уровне ФС)" 1 \
  grep -qE ':/opt/data/workspaces:ro' "$COMPOSE"
t "compose: прежний том данных Hermes сохранён" 0 grep -qF '${HERMES_DATA_DIR:-~/.hermes}:/opt/data' "$COMPOSE"
t "compose: порт 8642 только на 127.0.0.1" 0 grep -qE '"127\.0\.0\.1:8642:8642"' "$COMPOSE"
t "compose: порт 9119 только на 127.0.0.1" 0 grep -qE '"127\.0\.0\.1:9119:9119"' "$COMPOSE"
t "compose: нет портов без привязки к 127.0.0.1" 1 \
  grep -E '^[[:space:]]*-[[:space:]]*"?[0-9]+:[0-9]+' "$COMPOSE"
t "compose: плагин и навыки по-прежнему read-only" 0 \
  test "$(grep -cE '^[[:space:]]*-[[:space:]]*\./(plugins|skills)/ai-judge:/opt/data/.*:ro' "$COMPOSE")" -eq 2

# ── 2. корневой .env.example ──
EX="$ROOT/.env.example"
t ".env.example существует в корне" 0 test -f "$EX"
NAMES="JUDGE_DEMO_USER JUDGE_DEMO_PASSWORD JUDGE_DATA_DIR JUDGE_SESSION_SECRET JUDGE_DATABASE_URL HERMES_API_URL API_SERVER_KEY JUDGE_MAX_PARALLEL_SUBMISSIONS JUDGE_RETENTION_DAYS"
has_name() { grep -qE "^$1=" "$EX"; }
once_name() { test "$(grep -cE "^$1=" "$EX")" -eq 1; }
has_comment_before() { # у переменной непосредственно выше строка-комментарий
  awk -v n="$1" 'BEGIN{FS="="} $0 ~ "^"n"=" {exit !(prev ~ /^#.*[^[:space:]#]/)} {prev=$0}' "$EX"
}
for n in $NAMES; do
  t ".env.example: есть $n" 0 has_name "$n"
  t ".env.example: $n объявлена один раз" 0 once_name "$n"
  t ".env.example: у $n комментарий строкой выше" 0 has_comment_before "$n"
done
for n in API_SERVER_KEY JUDGE_DEMO_PASSWORD JUDGE_SESSION_SECRET; do
  t ".env.example: $n пустая" 0 grep -qE "^$n=[[:space:]]*$" "$EX"
done
# значения-кандидаты: всё после первого «=» у не-комментариев
values() { grep -vE '^[[:space:]]*(#|$)' "$EX" | sed -E 's/^[^=]*=//'; }
secretish_value() { # длинная случайная строка, префиксы ключей, URL с логином:паролем
  values | grep -E '(sk-|AKIA|ghp_|xox[bp]-|BEGIN [A-Z ]*PRIVATE)|[A-Za-z0-9+/_=-]{24,}|://[^/@[:space:]]+:[^@[:space:]]+@'
}
t ".env.example: нет значений, похожих на секрет" 1 secretish_value
secret_names_nonempty() { grep -E '^[A-Z0-9_]*(PASSWORD|SECRET|KEY|TOKEN)[A-Z0-9_]*=[^[:space:]]' "$EX"; }
t ".env.example: переменные PASSWORD/SECRET/KEY/TOKEN не имеют значений" 1 secret_names_nonempty
t ".env.example: не-комментарии — только NAME=значение" 0 \
  bash -c '! grep -vE "^[[:space:]]*(#|\$)" "$1" | grep -vqE "^[A-Z][A-Z0-9_]*="' _ "$EX"
t ".env.example: нет export и кавычечных подстановок \$(…)" 1 grep -E '^export |\$\(|`' "$EX"
t ".env.example: JUDGE_DATA_DIR по умолчанию ./data" 0 grep -qE '^JUDGE_DATA_DIR=(\./)?data/?[[:space:]]*$' "$EX"
t ".env.example: HERMES_API_URL — loopback :8642" 0 grep -qE '^HERMES_API_URL=http://(127\.0\.0\.1|localhost):8642[[:space:]]*$' "$EX"
t ".env.example: JUDGE_MAX_PARALLEL_SUBMISSIONS по умолчанию 5" 0 grep -qE '^JUDGE_MAX_PARALLEL_SUBMISSIONS=5[[:space:]]*$' "$EX"
t ".env.example: JUDGE_RETENTION_DAYS — целое" 0 grep -qE '^JUDGE_RETENTION_DAYS=[0-9]+[[:space:]]*$' "$EX"
t ".env.example: ровно девять переменных" 0 \
  test "$(grep -cE '^[A-Z][A-Z0-9_]*=' "$EX")" -eq 9

# ── 3. .gitignore ──
GI="$TMP/gi"; mkdir -p "$GI"; git -C "$GI" init -q
cp "$ROOT/.gitignore" "$GI/.gitignore"
ignored() { git -C "$GI" check-ignore -q "$1"; }
t ".gitignore игнорирует .env" 0 ignored .env
t ".gitignore игнорирует data/ (каталог материалов)" 0 ignored data/file.txt
t ".gitignore игнорирует вложенное содержимое data/" 0 ignored data/projects/p1/submissions/s1/a.md
t ".gitignore НЕ игнорирует .env.example" 1 ignored .env.example
t ".gitignore НЕ игнорирует исходники backend/" 1 ignored backend/app/main.py

# ── 4. scripts/dev.sh: окружение и fake-шлюз ──
STUB_LOG="$TMP/stub.log"; : > "$STUB_LOG"; export STUB_LOG
write_py_stub() { # <путь>
  cat > "$1" <<'EOF'
#!/bin/bash
printf 'py %s cwd=%s probe=%s datadir=%s\n' "$*" "$PWD" "${JUDGE_PROBE:-}" "${JUDGE_DATA_DIR:-}" >> "$STUB_LOG"
case "$*" in
  *app.fake_gateway*) [ -n "${STUB_GW_RC:-}" ] && exit "$STUB_GW_RC" ;;
esac
sleep "${STUB_SLEEP:-1}"
printf 'finished %s\n' "$*" >> "$STUB_LOG"
exit "${STUB_RC:-0}"
EOF
  chmod +x "$1"
}
unset STUB_GW_RC STUB_SLEEP STUB_RC JUDGE_PROBE JUDGE_DATA_DIR
mkdev() { # <каталог> [gateway] — копия scripts/ + backend/app/main.py + заглушка интерпретатора
  mkdir -p "$1/backend/app" "$1/.venv/bin"; cp -R "$ROOT/scripts" "$1/scripts"
  : > "$1/backend/app/main.py"; write_py_stub "$1/.venv/bin/python"
  if [ "${2:-}" = gateway ]; then : > "$1/backend/app/fake_gateway.py"; fi
}
rundev() { : > "$STUB_LOG"; ( cd "$1" && shift && env "$@" ); }
loggrep() { grep -qE -- "$1" "$STUB_LOG"; }
lognot() { ! grep -qE -- "$1" "$STUB_LOG"; }

# 4a. без fake_gateway.py и без .env: один сервер, одна строка-пропуск, каталог ./data создан
D1="$TMP/d1"; mkdev "$D1"
t "dev.sh без fake_gateway.py и .env → exit 0" 0 rundev "$D1" bash scripts/dev.sh
t_out "dev.sh без fake_gateway.py: строка о пропуске" '^dev: fake-шлюз не запущен \(backend/app/fake_gateway\.py нет\)$'
t "dev.sh без fake_gateway.py: строка о пропуске ровно одна" 0 \
  test "$(grep -c 'fake-шлюз не запущен' "$TMP/last.out")" -eq 1
t "dev.sh без fake_gateway.py: uvicorn запущен" 0 loggrep 'py -m uvicorn app\.main:app'
t "dev.sh без fake_gateway.py: fake-шлюз не запускался" 0 lognot 'fake_gateway'
t "dev.sh без .env: ./data создан" 0 test -d "$D1/data"
t "dev.sh: JUDGE_DATA_DIR по умолчанию виден процессам (./data)" 0 loggrep 'datadir=(\./data|'"$D1"'/data)$'

# 4b. с fake_gateway.py: запускается python -m app.fake_gateway из backend/
D2="$TMP/d2"; mkdev "$D2" gateway
t "dev.sh с fake_gateway.py → exit 0" 0 rundev "$D2" bash scripts/dev.sh
t "dev.sh с fake_gateway.py: запущен python -m app.fake_gateway" 0 loggrep '^py -m app\.fake_gateway '
t "dev.sh с fake_gateway.py: cwd = backend/" 0 loggrep '^py -m app\.fake_gateway cwd=.*/d2/backend '
t "dev.sh с fake_gateway.py: uvicorn тоже запущен" 0 loggrep 'py -m uvicorn app\.main:app'
t "dev.sh с fake_gateway.py: строки о пропуске нет" 1 grep -q 'fake-шлюз не запущен' "$TMP/last.out"
# порядок в тексте скрипта: fake-шлюз ПОСЛЕ uvicorn (и после frontend)
DEVSH="$ROOT/scripts/dev.sh"
line_of() { grep -n "$1" "$DEVSH" | head -n 1 | cut -d: -f1; }
gw_after() { [ -n "$(line_of fake_gateway)" ] && [ "$(line_of fake_gateway)" -gt "$(line_of 'app.main:app')" ] \
  && [ "$(line_of fake_gateway)" -gt "$(line_of 'npm run dev')" ]; }
t "dev.sh: блок fake-шлюза идёт после backend и frontend" 0 gw_after

# 4c. .env подхватывается и виден процессам; JUDGE_DATA_DIR из .env создаётся
D3="$TMP/d3"; mkdev "$D3" gateway
printf '# комментарий\nJUDGE_PROBE=from-dotenv\nJUDGE_DATA_DIR=%s\n' "$TMP/custom data" > "$D3/.env"
t "dev.sh с .env → exit 0" 0 rundev "$D3" bash scripts/dev.sh
t "dev.sh: переменная из .env видна процессу backend" 0 loggrep '^py -m uvicorn .*probe=from-dotenv'
t "dev.sh: переменная из .env видна fake-шлюзу" 0 loggrep '^py -m app\.fake_gateway .*probe=from-dotenv'
t "dev.sh: каталог из JUDGE_DATA_DIR (.env) создан" 0 test -d "$TMP/custom data"
t "dev.sh: JUDGE_DATA_DIR из .env передан процессам" 0 loggrep 'datadir='"$TMP"'/custom data$'
t "dev.sh: при JUDGE_DATA_DIR из .env ./data не создаётся" 0 test ! -e "$D3/data"

# 4d. переменная окружения вызывающего тоже работает (без .env) и каталог создаётся рекурсивно
D4="$TMP/d4"; mkdev "$D4"
t "dev.sh с JUDGE_DATA_DIR из окружения → exit 0" 0 rundev "$D4" env JUDGE_DATA_DIR="$TMP/deep/a/b" bash scripts/dev.sh
t "dev.sh: вложенный JUDGE_DATA_DIR создан рекурсивно" 0 test -d "$TMP/deep/a/b"

# 4e. сохранённое поведение: нет main.py → exit 1, T020, ничего не запущено и не создано
D5="$TMP/d5"; mkdev "$D5" gateway; rm "$D5/backend/app/main.py"
t "dev.sh без main.py → exit 1" 1 rundev "$D5" bash scripts/dev.sh
t_out "dev.sh без main.py: номер задачи T020" 'T020'
t "dev.sh без main.py: ничего не запущено" 0 lognot '.'
t "dev.sh без main.py: fake-шлюз не запущен даже при наличии файла" 0 lognot 'fake_gateway'

# 4f. падение fake-шлюза гасит остальных и отдаёт его код
D6="$TMP/d6"; mkdev "$D6" gateway
t "dev.sh: падение fake-шлюза (код 7) → exit 7" 7 rundev "$D6" env STUB_GW_RC=7 STUB_SLEEP=2 bash scripts/dev.sh
t_out "dev.sh: сообщение об остановке остальных" 'останавливаю остальные'
sleep 3
t "dev.sh: после падения шлюза uvicorn убит (не дожил до конца)" 0 lognot '^finished -m uvicorn'

# 4g. падение backend гасит fake-шлюз
D7="$TMP/d7"; mkdev "$D7" gateway
cat > "$D7/.venv/bin/python" <<'EOF'
#!/bin/bash
printf 'py %s\n' "$*" >> "$STUB_LOG"
case "$*" in
  *uvicorn*) sleep 0.2; exit 5 ;;
  *) sleep 2; printf 'finished %s\n' "$*" >> "$STUB_LOG" ;;
esac
EOF
t "dev.sh: падение backend (код 5) → exit 5" 5 rundev "$D7" bash scripts/dev.sh
sleep 3
t "dev.sh: после падения backend fake-шлюз убит" 0 lognot '^finished -m app\.fake_gateway'

harness_exit
