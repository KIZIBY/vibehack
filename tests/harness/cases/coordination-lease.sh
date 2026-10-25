#!/usr/bin/env bash
# tests/harness/cases/coordination-lease.sh — координационные лизы. Инвариант: I-3.
#
# Поведенческий контракт scripts/coordination-lease.sh: lease —
# ЖИВЫЕ инстанс-данные, писать/снимать их можно ТОЛЬКО хелпером; чужой действующий lease
# не перетирается молча. Всё герметично: свежий `git init` под $TMP, id сессии = имя
# worktree-ветки; реальный coordination/leases/ не трогаем — оперируем только в $TMP.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "coordination-lease (take · release · list · чужой лиз)"

CL="$ROOT/scripts/coordination-lease.sh"
REPO="$TMP/repo"; LEASES="$REPO/coordination/leases"

# Герметичный репо: id сессии хелпер берёт из git branch --show-current.
git -C "$REPO" init -q 2>/dev/null || { mkdir -p "$REPO"; git -C "$REPO" init -q; }
git -C "$REPO" checkout -q -b sess-a
# lease <args…> — SUT с cwd=репо (он резолвит coordination/leases от git-toplevel).
lease() { ( cd "$REPO" && bash "$CL" "$@" ); }

# ── TAKE: взять свой lease → well-formed файл + виден в list ──
t "take: свой lease → exit 0" 0 lease take w1 spec-dir 8 specs/017-x/plan.md docs/a.md
well_formed() {
  local f="$LEASES/w1.lease"
  [ -f "$f" ] \
    && grep -qxF 'session: sess-a' "$f" \
    && grep -qx  'scope: spec-dir' "$f" \
    && grep -qx  'ttl_hours: 8' "$f" \
    && grep -qxF 'path: docs/a.md' "$f" \
    && grep -qE  '^created: [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$' "$f"
}
t "take: lease-файл well-formed (session/scope/ttl/path/created)" 0 well_formed
t "list: активный lease → exit 0" 0 lease list
t_out "list: несёт slug w1 и владельца sess-a" 'w1.*sess-a'

# ── RELEASE: снять свой lease → файла нет, list его больше не показывает ──
t "release: свой lease → exit 0" 0 lease release w1
gone() { [ ! -f "$LEASES/w1.lease" ]; }
t "release: lease-файл снят" 0 gone
t "list: после release → exit 0" 0 lease list
t_out_absent "list: больше не содержит w1" 'w1'

# ── IDEMPOTENCE: повторный take своих же параметров → no-op, файл без чурна (I-2) ──
t "re-take: первый take w2 → exit 0" 0 lease take w2 file 8 docs/b.md
cp "$LEASES/w2.lease" "$TMP/w2.snap"
t "re-take: повтор тех же параметров → no-op exit 0" 0 lease take w2 file 8 docs/b.md
t_out "re-take: no-op назван в выводе" 'no-op'
t "re-take: файл не изменился (без чурна)" 0 cmp "$TMP/w2.snap" "$LEASES/w2.lease"

# ── FOREIGN/ACTIVE: чужой действующий lease не перетирается молча (I-3) ──
# planted напрямую (хелпер пишет только СВОЮ session): чужой владелец, created=now, ttl=9999 → действует.
mkdir -p "$LEASES"
printf 'session: sess-other\nscope: file\npath: y.md\ncreated: %s\nttl_hours: 9999\n' \
  "$(date -u +%FT%TZ)" > "$LEASES/busy.lease"
cp "$LEASES/busy.lease" "$TMP/busy.snap"
t "foreign: take чужого действующего → отказ (nonzero)" 2 lease take busy file 4 y.md
t_out "foreign: отказ называет владельца sess-other" 'sess-other'
t "foreign: байты чужого lease неизменны после take (I-3)" 0 cmp "$TMP/busy.snap" "$LEASES/busy.lease"
t "foreign: release чужого действующего → отказ (nonzero, I-2)" 2 lease release busy
t "foreign: байты чужого lease неизменны после release (I-3)" 0 cmp "$TMP/busy.snap" "$LEASES/busy.lease"

harness_exit
