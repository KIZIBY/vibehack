#!/usr/bin/env bash
# review-cross.sh — /ship, шаг 4: ревью моделью другого вендора (Codex) со структурированным вердиктом.
#
# Модель-судья склонна хвалить ответы, похожие на свои (Chain-of-Models): код пишет Claude — ревьюит
# Codex. Diff = `git diff <BASE>` (коммиты после + рабочее дерево) + неотслеживаемые файлы; ревьюер
# запускается read-only и отвечает JSON по схеме; валидный вердикт пишется в телеметрию (`log review`,
# bugs = P0+P1).
#
# Ревьюер получает доказательства: тест из коммита BASE (RED), вывод ship-guard.sh и файл с выводом
# проверок. Любая P0/P1 — BLOCK, что бы ни ответила модель; BASE-коммит типа `test` (RED) с изменённым
# после него тестом (ship-guard exit 1) — тоже BLOCK. Символические ссылки не читаются (их цель
# может быть вне репозитория); материал больше лимита — отказ, а не молчаливая обрезка.
#
# Usage: bash scripts/review-cross.sh <BASE_SHA> [EVIDENCE_FILE]   (из корня git-репозитория; BASE = RED_SHA)
# ENV:   HARNESS_REVIEW_CMD — команда ревьюера (по умолчанию codex)
#        HARNESS_REVIEW_MAX_BYTES — лимит материала для ревью (по умолчанию 300000)
# Exit:  0 = APPROVE · 1 = BLOCK · 2 = нет аргумента / sha не коммит / ревьюера нет или он упал / ответ
#        не по схеме / материал больше лимита — тогда ревью делает code-reviewer (ship.md, шаг 4)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "$0")" && pwd)"
die() { echo "review-cross: $*" >&2; exit 2; }

BASE="${1:-}"
[ -n "$BASE" ] || die "usage: bash scripts/review-cross.sh <BASE_SHA>"
git rev-parse -q --verify "$BASE^{commit}" >/dev/null 2>&1 || die "'$BASE' не резолвится в коммит"
EVIDENCE="${2:-}"
if [ -n "$EVIDENCE" ]; then
  [ ! -L "$EVIDENCE" ] || die "файл доказательств '$EVIDENCE' — символическая ссылка; передай обычный файл"
  [ -f "$EVIDENCE" ] || die "файл доказательств '$EVIDENCE' не найден"
fi
MAX_BYTES="${HARNESS_REVIEW_MAX_BYTES:-300000}"
CMD="${HARNESS_REVIEW_CMD:-codex}"
command -v "$CMD" >/dev/null 2>&1 || die "ревьюер '$CMD' не найден — ревью через code-reviewer (ship.md, шаг 4)"

TMPD="$(mktemp -d "${TMPDIR:-/tmp}/review-cross.XXXXXX")" || die "mktemp не удался"
trap 'rm -rf "$TMPD"' EXIT

cat >"$TMPD/schema.json" <<'JSON'
{"type": "object", "additionalProperties": false, "required": ["verdict", "findings"],
 "properties": {
  "verdict": {"type": "string", "enum": ["APPROVE", "BLOCK"]},
  "findings": {"type": "array", "items": {"type": "object", "additionalProperties": false,
   "required": ["priority", "text"],
   "properties": {"priority": {"type": "string", "enum": ["P0", "P1", "P2"]}, "text": {"type": "string"}}}}}}
JSON

# материал для ревью: тест из RED, ship-guard, доказательства, diff, новые файлы (ссылки — без чтения);
# каждый шаг проверяется — неполный материал не уходит на ревью (fail-closed)
M="$TMPD/material.txt"
printf '=== ТЕСТ ИЗ КОММИТА BASE (RED) ===\n' >"$M"
git show --format='%h %s' "$BASE" >>"$M" || die "git show $BASE упал"
GUARD_RC=0
# ship-guard — только если BASE это RED-коммит /ship (тип `test`: «test(<scope>): RED …»); для иного
# BASE «файлы из BASE» — код, и их изменение — норма, а не ослабленный тест
if [ -f "$SELF_DIR/ship-guard.sh" ] && git log -1 --format=%s "$BASE" | grep -qiE '^test(\([^)]*\))?!?:'; then
  printf '\n=== ship-guard.sh %s ===\n' "${BASE:0:12}" >>"$M"
  bash "$SELF_DIR/ship-guard.sh" "$BASE" >>"$M" 2>&1 || GUARD_RC=$?
  [ "$GUARD_RC" -le 1 ] || die "ship-guard.sh упал (exit $GUARD_RC)"
fi
if [ -n "$EVIDENCE" ]; then
  printf '\n=== ДОКАЗАТЕЛЬСТВА ИСПОЛНИТЕЛЯ ===\n' >>"$M"
  cat "$EVIDENCE" >>"$M" || die "не прочитать файл доказательств"
fi
printf '\n=== DIFF от %s (коммиты после + рабочее дерево) ===\n' "${BASE:0:12}" >>"$M"
git diff "$BASE" >>"$M" || die "git diff $BASE упал"
git ls-files --others --exclude-standard -z >"$TMPD/untracked" || die "git ls-files упал"
while IFS= read -r -d '' f; do
  if [ -L "$f" ]; then
    printf '\n=== НОВАЯ СИМВОЛИЧЕСКАЯ ССЫЛКА: %s (содержимое не читается) ===\n' "$f" >>"$M"
  elif [ -f "$f" ]; then
    printf '\n=== НОВЫЙ ФАЙЛ: %s ===\n' "$f" >>"$M"
    cat "$f" >>"$M" || die "не прочитать новый файл $f"
  fi
done <"$TMPD/untracked"
size="$(wc -c <"$TMPD/material.txt" | tr -d ' ')"
[ "$size" -le "$MAX_BYTES" ] \
  || die "материал для ревью ${size} байт > лимита ${MAX_BYTES} — раздели задачу или ревью через code-reviewer"

# секрет-гард ДО отправки вовне: pre-commit сработает позже, чем diff уйдёт ревьюеру (канон паттернов —
# scripts/secret-patterns.sh; без канона — отказ, fail-closed)
[ -f "$SELF_DIR/secret-patterns.sh" ] || die "нет scripts/secret-patterns.sh — без секрет-гарда вовне не отправляю"
# shellcheck source=secret-patterns.sh
. "$SELF_DIR/secret-patterns.sh"
if LC_ALL=C grep -qE "$SECRET_RE" "$TMPD/material.txt"; then
  die "в материале для ревью найден секрет (scripts/secret-patterns.sh) — убери его; ревьюеру ничего не отправлено"
fi

# окружение ревьюера без переменных-секретов (OPENAI_API_KEY и CODEX_* нужны самому Codex)
UNSET=()
while IFS= read -r v; do
  case "$v" in OPENAI_API_KEY|CODEX_*) continue ;; esac
  printf '%s' "$v" | grep -qiE 'KEY|TOKEN|SECRET|PASS|CREDENTIAL|AUTH|COOKIE' && UNSET+=(-u "$v")
done < <(compgen -e)

{
  cat <<'PROMPT'
Ты — независимый ревьюер кода (код писала другая модель). Ниже: тест из RED-коммита (написан до
кода отдельным агентом), вывод ship-guard (тест не изменён после RED), доказательства исполнителя,
diff и новые файлы. Найди дефекты: корректность, безопасность (инъекции, секреты, права, чтение вне
репозитория), потеря данных, гонки, края (пустой ввод, пробелы в именах, ошибки внешних команд),
ослабленные тесты, расхождение кода с тестом. Полные файлы можно читать в репозитории (read-only).
Приоритеты: P0 — ломает корректность, безопасность или данные; P1 — вероятный баг или непроверенное
ключевое поведение; P2 — улучшение. Вердикт BLOCK, если есть хотя бы одна P0 или P1, иначе APPROVE.
Ничего не меняй в репозитории. Ответ — строго JSON по схеме; каждая находка — одной строкой с файлом.
PROMPT
  cat "$TMPD/material.txt"
} >"$TMPD/prompt.txt"

env ${UNSET[@]+"${UNSET[@]}"} "$CMD" exec -s read-only --skip-git-repo-check --output-schema "$TMPD/schema.json" \
  -o "$TMPD/answer.json" - <"$TMPD/prompt.txt" >"$TMPD/reviewer.log" 2>&1 \
  || die "ревьюер упал (exit $?): $(tail -n 3 "$TMPD/reviewer.log" | tr '\n' ' ')"

parsed="$(python3 - "$TMPD/answer.json" <<'PY'
import json, sys
try:
    d = json.load(open(sys.argv[1], encoding="utf-8"))
    v, f = d["verdict"], d["findings"]
    assert v in ("APPROVE", "BLOCK") and isinstance(f, list)
    assert all(isinstance(x, dict) and x.get("priority") in ("P0", "P1", "P2")
               and isinstance(x.get("text"), str) for x in f)
except Exception as e:  # noqa: BLE001 — любой сбой разбора = ответ не по схеме
    print("%s: %s" % (type(e).__name__, e))
    sys.exit(1)
print("%s %d %d" % (v, len(f), sum(1 for x in f if x["priority"] in ("P0", "P1"))))
for x in f:
    print("- %s %s" % (x["priority"], " ".join(x["text"].split())))
PY
)" || die "ответ ревьюера не по схеме: $parsed"

read -r VERDICT NFIND NBUGS <<<"$(printf '%s\n' "$parsed" | head -n 1)"
GUARD_LINE=""
if [ "$GUARD_RC" -eq 1 ]; then  # тест из RED изменён — не одобрение, что бы ни сказала модель
  GUARD_LINE="- P0 ship-guard: тест из RED-коммита ${BASE:0:8} изменён после RED"
  NFIND=$((NFIND + 1)); NBUGS=$((NBUGS + 1))
fi
[ "$NBUGS" -eq 0 ] || VERDICT=BLOCK   # «APPROVE» с P0/P1 — не одобрение
echo "Вердикт: $VERDICT"
[ -z "$GUARD_LINE" ] || echo "$GUARD_LINE"
printf '%s\n' "$parsed" | tail -n +2
# телеметрия best-effort (I-8): сбой не меняет вердикт, но и не глушится молча
bash "$SELF_DIR/telemetry.sh" log review verdict="$VERDICT" findings="$NFIND" bugs="$NBUGS" \
  reviewer=codex >/dev/null 2>&1 \
  || echo "review-cross: WARN — вердикт не записан в телеметрию (scripts/telemetry.sh log review)" >&2
[ "$VERDICT" = "APPROVE" ]
