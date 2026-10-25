#!/bin/bash
# migrate.sh — миграции БД (Alembic). Без аргументов — `upgrade head`; иначе аргументы уходят в alembic.
# Exit: 1 = миграций ещё нет (нет backend/alembic.ini) · иначе код alembic
set -uo pipefail
. "$(dirname "$0")/lib/project-env.sh"

if [ ! -f backend/alembic.ini ]; then
  echo "migrate: миграций нет: backend/alembic.ini отсутствует (схема БД — задача T012)" >&2
  exit 1
fi
[ $# -gt 0 ] || set -- upgrade head
cd backend && "$PY" -m alembic "$@"
