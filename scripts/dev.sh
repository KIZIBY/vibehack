#!/bin/bash
# dev.sh — локальный запуск: backend (:8000) и frontend (:5173). fake-шлюз агентов добавляет T014.
# Exit: 1 = нечего запускать (нет backend/app/main.py) · иначе код последнего завершённого процесса
set -o pipefail
set -m   # у каждого фонового задания своя группа процессов: гасим вместе с потомками (npm → node)
. "$(dirname "$0")/lib/project-env.sh"

if [ ! -f backend/app/main.py ]; then
  echo "dev: нечего запускать: backend/app/main.py нет (backend — задача T020)" >&2
  exit 1
fi

pids=""
trap 'for p in $pids; do kill -- -"$p" 2>/dev/null; done' EXIT INT TERM
"$PY" -m uvicorn app.main:app --app-dir backend --host 127.0.0.1 --port 8000 --reload & pids="$pids $!"
if [ -f frontend/package.json ]; then
  (cd frontend && npm run dev -- --host 127.0.0.1 --port 5173) & pids="$pids $!"
fi
# bash 3.2 (macOS) без `wait -n`: опрашиваем процессы; ушёл любой — гасим остальные и отдаём его код
while :; do
  for pid in $pids; do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid"; rc=$?
      echo "dev: процесс $pid завершился (код $rc) — останавливаю остальные" >&2
      exit "$rc"
    fi
  done
  sleep 1
done
