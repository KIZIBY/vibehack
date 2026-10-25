# coordination/ — lease-реестр параллельных локальных сессий

Несколько агентских сессий (worktree-ветки на одной машине или у разных людей) могут править один
репозиторий одновременно. Сессия объявляет занятые пути tracked-файлом `leases/<slug>.lease`.
Enforcement — `.githooks/pre-commit` (коммит в путь под чужим действующим lease блокируется) и
lease-чек публикации в `scripts/agent-publish-main.sh`; этот каталог — данные, не код.
Lease-файлы — живые данные проекта: скрипты их не переписывают молча (I-2).

## Формат lease-файла (key:value; пишет ТОЛЬКО scripts/coordination-lease.sh)

    session: <имя worktree-ветки>              # идентификатор сессии; поля host НЕТ (I-1)
    scope: spec-dir|file|subsystem
    path: <repo-relative путь или bash-глоб>   # по строке на путь; ≤32 строк
    created: 2026-01-15T12:00:00Z              # ISO-8601 UTC (Z)
    ttl_hours: 8                               # целое; created+ttl < now = lease не действует

Лимиты-guard: файл ≤2048 байт, paths ≤32, пути только repo-relative (абсолютный путь — отказ,
периметр I-1), slug — только `[A-Za-z0-9._-]`. Глобы: `*` не проходит через `/`, `**` проходит,
`?` — один не-`/` символ, завершающий `/` — префикс каталога.

## Usage

    bash scripts/coordination-lease.sh take <slug> <scope> <ttl_hours> <path>...
    bash scripts/coordination-lease.sh release <slug>
    bash scripts/coordination-lease.sh list [--json]

Перед удалением worktree `scripts/agent-worktree-memory-check.sh` напоминает о непогашенных
собственных лизах ветки (вместе с проверкой незакоммиченной памяти агентов).

## Честная семантика: best-effort, НЕ распределённый лок

Git не даёт атомарного лока — lease виден другим сессиям только после commit+push и их
fetch. Обязательный первый шаг перед take: fetch + уведомление активных сессий (конвенция —
`docs/pipeline-rules.md`). Просроченный lease не действует: хук пропускает, take перезаписывает.
Битый lease не считается действующим (WARN + fail-open per-file). Take/release идемпотентны (I-2);
события `lease:take` / `lease:release` пишутся в `docs/ops-journal.md` best-effort (I-8).
