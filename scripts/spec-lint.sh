#!/usr/bin/env bash
# spec-lint.sh — детерминированный линт структуры spec.md (сенсор этапа требований).
#
# Контракт REQUIRED-секций — шаблоны /pipeline-stage1 и speckit.specify;
# «Authentication & Access» обязательна всегда (docs/guides/AUTH_GUIDE.md §3: контент или явное «N/A»).
# Промпт-проверки модель может пропустить — этот линт возвращает exit-код и зовётся
# в конце stage-1 и на входе stage-2 (см. .claude/commands/pipeline-stage{1,2}.md).
#
# Usage: bash scripts/spec-lint.sh <SPEC_DIR | путь/к/spec.md>
# Exit:  0 = OK (warn допустимы) · 1 = нет REQUIRED-секции / пустая Authentication & Access /
#        >3 маркеров NEEDS CLARIFICATION (speckit-лимит) · 2 = spec.md не найден
set -euo pipefail

ARG="${1:?usage: spec-lint.sh <SPEC_DIR|path/to/spec.md>}"
SPEC="$ARG"; [ -d "$ARG" ] && SPEC="$ARG/spec.md"
[ -f "$SPEC" ] || { echo "spec-lint: FATAL: не найден $SPEC" >&2; exit 2; }

fail=0
req() { # секция обязана существовать (матч по префиксу заголовка — суффиксы в скобках допустимы)
  if grep -q "^## $1" "$SPEC"; then echo "spec-lint: ok    ## $1"
  else echo "spec-lint: FAIL  нет секции '## $1' (REQUIRED)"; fail=1; fi
}
rec() { # рекомендованная секция — только warn
  if grep -q "^## $1" "$SPEC"; then echo "spec-lint: ok    ## $1"
  else echo "spec-lint: warn  нет секции '## $1' (RECOMMENDED)"; fi
}

req "Overview"
req "User Stories"
req "Functional Requirements"
req "Non-Functional Requirements"
req "Authentication & Access"
req "Out of Scope"
req "Affected Services"
rec "Edge Cases"
rec "Assumptions"
rec "Success Criteria"

# Authentication & Access: тело секции не пустое (контент или явное «N/A ...») — молчание запрещено
if grep -q "^## Authentication & Access" "$SPEC"; then
  auth_lines="$(awk '/^## Authentication & Access/{f=1;next} /^## /{f=0} f && NF' "$SPEC" | wc -l | tr -d ' ')"
  if [ "$auth_lines" -eq 0 ]; then
    echo "spec-lint: FAIL  секция Authentication & Access пуста — заполни по docs/guides/AUTH_GUIDE.md §3 или явное «N/A (не затрагивает вход/роли/доступ)»"
    fail=1
  fi
fi

# NFR-квантификация (docs/guides/NFR_GUIDE.md §1): секция NFR без единого числа = все требования vague —
# эвристика-сигнал (warn, не гейт: «быстро/надёжно» без метрики ловит stage-2 аудит по гайду)
if grep -q "^## Non-Functional Requirements" "$SPEC"; then
  # ID требований (NFR-001) сами содержат цифры — вырезаем их ДО подсчёта, иначе эвристика слепа
  nfr_digits="$(awk '/^## Non-Functional Requirements/{f=1;next} /^## /{f=0} f' "$SPEC" \
    | sed -E 's/N?FR-[0-9]+//g' | { grep -c '[0-9]' || true; })"
  if [ "$nfr_digits" -eq 0 ]; then
    echo "spec-lint: warn  NFR-секция без единого числа (кроме ID) — квантифицируй по docs/guides/NFR_GUIDE.md §1 (или явные N/A per категория)"
  fi
fi

# Тикет-источник: warn-связка spec.md ↔ state.md — ТОЛЬКО при входе-каталоге
# (рядом доступен state.md); вызов на голый путь к файлу — проверка молча пропускается.
# Маркер — необязательная строка шапки «Источник: тикет <KEY>» (KEY вида #123).
# Всё advisory: только warn, exit-код не меняется.
if [ -d "$ARG" ]; then
  STATE_F="$ARG/state.md"
  KEY_RE='([A-Za-z][A-Za-z0-9_]*-[0-9]+|#[0-9]+)'
  src_line="$(grep -m1 -E '^[-*>]?[[:space:]]*Источник:.*[Тт]икет' "$SPEC" || true)"
  state_ticket=""
  if [ -f "$STATE_F" ]; then state_ticket="$(sed -n 's/^- Ticket: //p' "$STATE_F" | head -1)"; fi
  if [ "$state_ticket" = "—" ]; then state_ticket=""; fi
  if [ -n "$src_line" ]; then
    src_key="$(printf '%s' "$src_line" | { grep -oE "$KEY_RE" || true; } | head -1)"
    if [ -z "$src_key" ]; then
      echo "spec-lint: warn  маркер «Источник: тикет» без KEY (ожидаю вида #123) — допиши ключ тикета"
    elif [ -z "$state_ticket" ]; then
      echo "spec-lint: warn  фича из тикет-источника ($src_key) без ссылки в state.md — привяжи: pipeline-state.sh link-ticket $ARG $src_key"
    fi
  fi
  if [ -n "$state_ticket" ] && ! grep -qF "$state_ticket" "$SPEC"; then
    echo "spec-lint: warn  state.md несёт Ticket: $state_ticket, а spec.md его не упоминает — добавь строку «Источник: тикет ${state_ticket}» в шапку"
  fi
fi

# NEEDS CLARIFICATION: ≤3 допустимо (правило speckit.specify), больше — спека не готова к аудиту
# (grep -o: считаем ВХОЖДЕНИЯ, не строки — несколько маркеров на строке не сливаются в один)
nc="$( { grep -o 'NEEDS CLARIFICATION' "$SPEC" || true; } | wc -l | tr -d ' ')"
if [ "$nc" -gt 3 ]; then
  echo "spec-lint: FAIL  маркеров NEEDS CLARIFICATION: $nc (>3 — спека не готова; сними через /speckit.clarify)"
  fail=1
elif [ "$nc" -gt 0 ]; then
  echo "spec-lint: warn  маркеров NEEDS CLARIFICATION: $nc (снять до stage-3)"
fi

if [ "$fail" -eq 0 ]; then echo "spec-lint: OK ($SPEC)"; else echo "spec-lint: FAILED ($SPEC)"; fi
exit "$fail"
