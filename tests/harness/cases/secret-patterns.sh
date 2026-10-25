#!/usr/bin/env bash
# tests/harness/cases/secret-patterns.sh — единый источник SECRET_RE (scripts/secret-patterns.sh).
# Инвариант I-7: один canonical ERE для всех секрет-границ (pre-commit hook, preflight, intake,
# publish). Контракт поведенческий:
#   1) sourceable-константа: source НИЧЕГО не исполняет и не печатает, определяет непустой SECRET_RE;
#   2) POSITIVE corpus — каждый known-secret shape ловится;
#   3) NEGATIVE corpus — benign строки НЕ ловятся (точный regex, без ложных срабатываний).
# NB: все secret-подобные литералы здесь СОБРАНЫ конкатенацией фрагментов, чтобы этот файл сам
# не срабатывал на pre-commit секрет-скане (тот же SECRET_RE). Раны-заполнители — рантайм-переменные.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
section "secret-patterns (SECRET_RE · единый источник)"

# SECRET_RE в текущий shell — нужен матчерам корпуса ниже.
. "$ROOT/scripts/secret-patterns.sh"

# rep <n> <char> — n копий символа (рантайм-заполнитель; в исходнике длинных ранов НЕТ).
rep() { printf "%${1}s" '' | tr ' ' "$2"; }
A16="$(rep 16 A)"; A20="$(rep 20 A)"; A36="$(rep 36 A)"

# ── data-driven корпуса: имя + кандидат (все литералы расщеплены) ──
POS_NAME=(); POS_CAND=()
add_pos() { POS_NAME+=("$1"); POS_CAND+=("$2"); }
NEG_NAME=(); NEG_CAND=()
add_neg() { NEG_NAME+=("$1"); NEG_CAND+=("$2"); }

# POSITIVE: каждый shape, который SECRET_RE обязан ловить.
add_pos "Stripe live-ключ (sk-live-…)"              'sk-''live-'"A"
add_pos "AWS access key id (AKIA + 16)"             'AKI''A'"$A16"
add_pos "PEM RSA private-key header"                'BEG''IN'" RSA PRIVATE KEY"
add_pos "PEM OPENSSH private-key header"            'BEG''IN'" OPENSSH PRIVATE KEY"
add_pos "Anthropic API key (sk-ant-api03-…)"        'sk-ant-''api03-'"$A20"
add_pos "Anthropic admin key (sk-ant-admin01-…)"    'sk-ant-''admin01-'"$A20"
add_pos "OpenAI project key (sk-proj-…)"            'sk-''proj-'"$A20"
add_pos "GitHub classic PAT (ghp_ + 36)"            'ghp''_'"$A36"
add_pos "GitHub fine-grained PAT (github_pat_…)"    'github''_pat_'"$A20"
add_pos "URL с паролем в userinfo (u:p@)"           'https:/''/user:pass@host.example'

# NEGATIVE: benign строки — точный regex НЕ должен срабатывать (эти литералы не матчатся,
# поэтому безопасны как есть; их же проверяем на отсутствие ложного срабатывания).
add_neg "bare sk- без suffix"                       'sk-'
add_neg "обычное слово с дефисом"                   'hello-world'
add_neg "https без userinfo"                        'https://example.com/path'
add_neg "https host:port без пароля"                'https://host.example:8443/status'
add_neg "AKIA слишком короткий"                     'AKIA1234'
add_neg "git sha (40 hex)"                          'da39a3ee5e6b4b0d3255bfef95601890afd80709'
add_neg "ssh://git@ без пароля (допустим)"          'ssh://git@host.example'

# ── матчеры (исполняются в текущем shell, видят $SECRET_RE и массивы) ──
pos_match()  { printf '%s' "${POS_CAND[$1]}" | grep -Eq "$SECRET_RE"; }
neg_reject() { ! printf '%s' "${NEG_CAND[$1]}" | grep -Eq "$SECRET_RE"; }

# source-проверка: изолированный subshell, чтобы не мутировать текущий SECRET_RE.
src_defines() { ( unset SECRET_RE; . "$ROOT/scripts/secret-patterns.sh"; [ -n "${SECRET_RE:-}" ]; ); }
src_silent()  { [ -z "$(. "$ROOT/scripts/secret-patterns.sh" 2>&1)" ]; }

# ── SOURCE: sourceable-константа без побочек ──
t "source: определяет непустой SECRET_RE" 0 src_defines
t "source: не печатает ничего в stdout/stderr" 0 src_silent

# ── POSITIVE corpus: каждый секрет ловится ──
i=0
while [ "$i" -lt "${#POS_CAND[@]}" ]; do
  t "match: ${POS_NAME[$i]}" 0 pos_match "$i"
  i=$((i + 1))
done

# ── NEGATIVE corpus: ни одна benign строка не ловится ──
j=0
while [ "$j" -lt "${#NEG_CAND[@]}" ]; do
  t "reject: ${NEG_NAME[$j]}" 0 neg_reject "$j"
  j=$((j + 1))
done

harness_exit
