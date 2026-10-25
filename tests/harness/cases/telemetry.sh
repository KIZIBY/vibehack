#!/usr/bin/env bash
# tests/harness/cases/telemetry.sh — телеметрия агентов: hook-лог → метрики → дашборд.
# Контракты: hook никогда не роняет сессию (exit 0 на мусоре); секреты редактируются ДО записи;
# токены/стоимость из транскрипта с дедупом message.id и разбивкой по моделям × ролям; строки
# кода из structuredPatch; тесты red→green; круги ревью и first-pass; вмешательства человека
# по причинам; MAST закрыт правилом; прогноз vs факт; рост плейбука по git; HTML без путей машины.
set -uo pipefail
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/harness.sh"
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../lib" && pwd)/fixtures.sh"
section "telemetry (agent metrics)"

TL="$ROOT/scripts/telemetry.sh"
HOOK="$ROOT/.claude/hooks/telemetry.sh"
export HARNESS_TELEMETRY_DIR="$TMP/tel"
EV="$HARNESS_TELEMETRY_DIR/events.jsonl"

R="$TMP/repo"; mk_repo "$R"
mk_commit "$R" docs/pipeline-rules.md $'# rules\n- **r1** a\n- **r2** b' "docs: rules" >/dev/null
printf -- '- **r3** c\n' >> "$R/docs/pipeline-rules.md"
git -C "$R" add -A && git -C "$R" commit -qm $'docs: rule r3\n\nCo-Authored-By: Claude <noreply@anthropic.com>'

# ── фикстура транскрипта: main (opus, дубль message.id, interrupt, turn_duration) + субагент-ревьюер
P="$TMP/proj"; mkdir -p "$P/S1/subagents"
NOW="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
A1='{"type":"assistant","timestamp":"'"$NOW"'","message":{"id":"m1","model":"claude-opus-5-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_read_input_tokens":10000,"cache_creation_input_tokens":2000,"cache_creation":{"ephemeral_1h_input_tokens":2000,"ephemeral_5m_input_tokens":0}}}}'
{
  printf '%s\n%s\n' "$A1" "$A1"
  printf '%s\n' '{"type":"user","timestamp":"'"$NOW"'","message":{"role":"user","content":[{"type":"text","text":"[Request interrupted by user]"}]}}'
  printf '%s\n' '{"type":"system","subtype":"turn_duration","durationMs":60000,"timestamp":"'"$NOW"'"}'
} > "$P/S1.jsonl"
printf '%s\n' '{"type":"assistant","timestamp":"'"$NOW"'","message":{"id":"m2","model":"claude-sonnet-5-5","usage":{"input_tokens":100,"output_tokens":50}}}' > "$P/S1/subagents/agent-r1.jsonl"
printf '%s\n' '{"agentType":"code-reviewer"}' > "$P/S1/subagents/agent-r1.meta.json"

hook() { (cd "$R" && printf '%s' "$1" | bash "$HOOK"); }
B='"session_id":"S1","transcript_path":"'"$P/S1.jsonl"'","cwd":"'"$R"'"'
TOKEN="ghp_$(printf 'a%.0s' $(seq 1 36))"

# ── hook: мусор и пустой stdin не роняют сессию
t "hook: мусорный stdin → exit 0" 0 hook 'not json {'
t "hook: пустой stdin → exit 0" 0 hook ''

hook '{'"$B"',"hook_event_name":"SessionStart","source":"startup"}'
t "task start с прогнозом → exit 0" 0 bash -c "cd '$R' && bash '$TL' task start T1 --title 'фича' --estimate 30"
t "status показывает активную задачу и прогноз" 0 bash -c "cd '$R' && bash '$TL' status"
t_out "status: T1 · прогноз 30м" 'T1.*30'
hook '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"сделай фичу"}'
hook '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"нет, не так — переделай, токен '"$TOKEN"'"}'
hook '{'"$B"',"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"u1","tool_input":{"command":"bash scripts/check.sh"},"error":"Exit code 1\n2 failed, 3 passed"}'
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Edit","tool_use_id":"u2","tool_input":{"file_path":"'"$R"'/a.py"},"tool_response":{"filePath":"'"$R"'/a.py","structuredPatch":[{"lines":["+a","+b","-c"," d"]}],"userModified":false}}'
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Write","tool_use_id":"u3","tool_input":{"file_path":"'"$R"'/b.py"},"tool_response":{"type":"create","filePath":"'"$R"'/b.py","content":"x\ny\nz\n","structuredPatch":[]}}'
hook '{'"$B"',"hook_event_name":"SubagentStop","agent_id":"r1","agent_type":"code-reviewer","last_assistant_message":"Вердикт: BLOCK\n- P1 инъекция в запросе\n- P2 нет таймаута"}'
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"u4","tool_input":{"command":"bash scripts/check.sh"},"tool_response":{"stdout":"5 passed","stderr":""}}'
hook '{'"$B"',"hook_event_name":"SubagentStop","agent_id":"r2","agent_type":"code-reviewer","last_assistant_message":"Вердикт: APPROVE"}'
for i in 1 2 3; do
  hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"l'"$i"'","tool_input":{"command":"ls"},"tool_response":{"stdout":"","stderr":""}}'
done
t "log mast → exit 0" 0 bash -c "cd '$R' && bash '$TL' log mast code=FM-2.2 note='не спросил уточнение'"
t "log rule closes=FM-2.2 → exit 0" 0 bash -c "cd '$R' && bash '$TL' log rule ref=pipeline-rules closes=FM-2.2"
t "log mast с неизвестным кодом → exit 2" 2 bash -c "cd '$R' && bash '$TL' log mast code=FM-9.9"
bash -c "cd '$R' && bash '$TL' log eval name=rag score=0.7 && bash '$TL' log eval name=rag score=0.85" >/dev/null
t "task done → exit 0" 0 bash -c "cd '$R' && bash '$TL' task done T1"

# ── сырой лог: есть, секрет отредактирован до записи
assert_file_contains "events.jsonl пишется" "$EV" '"ev": ?"PostToolUse"'
assert_file_absent "секрет не попал в лог" "$EV" 'ghp_a{36}'
assert_file_contains "секрет заменён маркером" "$EV" 'REDACTED'

# ── отчёт JSON
t "report --json → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --json > '$TMP/r.json'"
J="$TMP/r.json"
assert_json "токены: дубль message.id посчитан один раз" "$J" 'data["tokens"]["total"]["output"] == 550'
assert_json "токены: разбивка по моделям" "$J" 'data["tokens"]["by_model"]["claude-opus-5-5"]["output"] == 500'
assert_json "токены: роль субагента из meta.json" "$J" 'data["tokens"]["by_role"]["code-reviewer"]["output"] == 50'
assert_json "стоимость: прайс + кэш 1h ×2" "$J" 'abs(data["cost"]["total_usd"] - 0.0327) < 1e-6'
assert_json "активное время из turn_duration" "$J" 'data["active_time"]["minutes"] == 1.0'
assert_json "строки кода AI: +5 −1 из structuredPatch/create" "$J" 'data["loc"]["ai_tools"] == {"added": 5, "removed": 1, "files": 2}'
assert_json "тесты: 1 красный → 1 зелёный" "$J" 'data["tests"]["red"] == 1 and data["tests"]["green"] == 1'
assert_json "тесты по задаче: красный до кода, зелёный в итоге" "$J" 'data["tests"]["tasks_red_before_code"] == 1 and data["tests"]["tasks_green_final"] == 1'
assert_json "ревью: 2 круга, first-pass 0%" "$J" 'data["review"]["rounds_per_task"]["T1"] == 2 and data["review"]["first_pass_pct"] == 0.0'
assert_json "баги до мержа: 1 от ревьюера (P1; P2 — не баг) + 1 красный тест" "$J" 'data["bugs"]["by_review"] == 1 and data["bugs"]["by_tests"] == 1'
assert_json "вмешательства: correction + interrupt" "$J" 'data["interventions"]["by_reason"] == {"correction": 1, "interrupt": 1}'
assert_json "MAST: FM-2.2 закрыт правилом" "$J" 'data["mast"]["by_code"]["FM-2.2"] == {"count": 1, "closed": 1}'
assert_json "MAST: авто-кандидат FM-1.3 (повтор шага)" "$J" 'data["mast"]["candidates"]["FM-1.3"] >= 1'
assert_json "прогноз vs факт по задаче" "$J" 'data["tasks"]["items"]["T1"]["estimate_min"] == 30 and data["tasks"]["items"]["T1"]["actual_min"] is not None'
assert_json "задачи по статусам" "$J" 'data["tasks"]["by_status"] == {"done": 1}'
assert_json "автономия: задача закрыта без ручной правки" "$J" 'data["autonomy"]["tasks_done"] == 1 and data["autonomy"]["ai_only"] == 1'
assert_json "плейбук: 2 → 3 правила по git" "$J" '[p["rules"] for p in data["playbook"]["series"]][-2:] == [2, 3]'
assert_json "git: коммиты всего/AI" "$J" 'data["git"]["commits"] == 2 and data["git"]["ai_commits"] == 1'
assert_json "эвалы: серия по итерациям" "$J" '[e["score"] for e in data["evals"]["series"]["rag"]] == [0.7, 0.85]'

# ── текст и HTML
t "report (текст) → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z"
t_out "текстовая сводка показывает стоимость" 'Стоимость'
t "report --html → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --html '$TMP/d.html'"
assert_file_contains "HTML: панель токенов" "$TMP/d.html" 'Токены по моделям'
assert_file_absent "HTML: нет путей машины" "$TMP/d.html" '/(Users|home|private|tmp)/'
assert_file_absent "HTML: нет текста промптов" "$TMP/d.html" 'переделай'

# ── авто-задачи: prompt-hook сам открывает задачу и просит агента дать прогноз; исправление → MAST
export HARNESS_TELEMETRY_DIR="$TMP/tel2"
PH="$ROOT/.claude/hooks/telemetry-prompt.sh"
ph() { (cd "$R" && printf '%s' "$1" | bash "$PH"); }
t "prompt-hook: мусор → exit 0" 0 ph 'oops'
t "prompt-hook: одобрение без задачи → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"ок"}'
t_out_absent "одобрение задачу не открывает" 'additionalContext'
t "prompt-hook: просьба без задачи → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"сделай экспорт в csv"}'
t_out "агенту: открыта T1, дай прогноз" '"additionalContext".*T1.*task estimate T1'
t "status видит авто-задачу" 0 bash -c "cd '$R' && bash '$TL' status"
t_out "status: ▶ T1" '▶ T1'
t "агент даёт прогноз и заголовок" 0 bash -c "cd '$R' && bash '$TL' task estimate T1 25 --title 'экспорт csv'"
t "prompt-hook: исправление курса → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"нет, не так"}'
t_out "агенту: классифицируй сбой по MAST" 'log mast code=FM'
t "агент закрывает задачу" 0 bash -c "cd '$R' && bash '$TL' task done T1"
t "prompt-hook: следующая просьба → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"теперь добавь импорт"}'
t_out "нумерация авто-задач сквозная: T2" 'task estimate T2'
t "task start auto → следующий номер" 0 bash -c "cd '$R' && bash '$TL' task done T2 && bash '$TL' task start auto --estimate 5"
t_out "auto → T3" 'T3'
t "каждый промпт залогирован ровно один раз" 0 test "$(grep -c '"ev": "UserPromptSubmit"' "$HARNESS_TELEMETRY_DIR/events.jsonl")" -eq 4
t "report по авто-задачам → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --json > '$TMP/r2.json'"
assert_json "авто-задача: прогноз и заголовок от агента, статус done" "$TMP/r2.json" 'data["tasks"]["items"]["T1"]["estimate_min"] == 25 and data["tasks"]["items"]["T1"]["title"] == "экспорт csv" and data["tasks"]["items"]["T1"]["status"] == "done"'
assert_json "заголовок не берётся из текста промпта" "$TMP/r2.json" 'data["tasks"]["items"]["T2"]["title"] is None'
assert_json "постановка задачи — не вмешательство, исправление — да" "$TMP/r2.json" 'data["interventions"]["by_reason"].get("correction") == 1 and "request" not in data["interventions"]["by_reason"]'

# ── «давай + просьба» — постановка задачи; одобрение — только когда весь промпт из слов согласия
export HARNESS_TELEMETRY_DIR="$TMP/tel3"
t "prompt-hook: «давай в zip архив» → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"давай в zip архив"}'
t_out "«давай + просьба» открывает задачу" 'task estimate T1'
bash -c "cd '$R' && bash '$TL' task done T1" >/dev/null
t "prompt-hook: «да, давай!» → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"да, давай!"}'
t_out_absent "чистое одобрение задачу не открывает" 'additionalContext'
export HARNESS_TELEMETRY_DIR="$TMP/tel"

# ── пайп маскирует exit-код: FAIL-счётчики в выводе делают прогон красным
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"p1","tool_input":{"command":"bash tests/harness/cases/x.sh | sort | uniq -c"},"tool_response":{"stdout":"  14 FAIL\n  44 ok","stderr":""}}'
t "report после пайпа → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --json > '$TMP/r3.json'"
assert_json "exit 0 + «14 FAIL» в выводе = красный прогон" "$TMP/r3.json" 'data["tests"]["series"][-1]["status"] == "fail" and data["tests"]["series"][-1]["failed"] == 14'

# ══ пакет правок: system-уведомления, вердикт ревьюера, RED до кода, рутина, failures.md, оценка человека
rep() { (cd "$R" && bash "$TL" report --since 2000-01-01T00:00:00Z --json > "$1"); }
tstart() { bash -c "cd '$R' && bash '$TL' $*" >/dev/null; }

# 1. <task-notification>/<system-reminder> — не человек
export HARNESS_TELEMETRY_DIR="$TMP/tel4"
t "prompt-hook: task-notification без задачи → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>x</task-id>\nDo NOT stop"}'
t_out_absent "уведомление: нет additionalContext" 'additionalContext'
t "status после уведомления → exit 0" 0 bash -c "cd '$R' && bash '$TL' status"
t_out_absent "уведомление задачу не открывает" '▶'
t "prompt-hook: system-reminder без задачи → exit 0" 0 ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"<system-reminder>\nпросто напоминание"}'
t_out_absent "system-reminder: нет additionalContext" 'additionalContext'
ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"сделай экспорт"}' >/dev/null
ph '{'"$B"',"hook_event_name":"UserPromptSubmit","prompt":"<task-notification>\n<task-id>x</task-id>\nDo NOT stop"}' >/dev/null
rep "$TMP/r4.json"
assert_json "уведомление классифицировано system" "$TMP/r4.json" 'sum(1 for _ in open("'"$HARNESS_TELEMETRY_DIR"'/events.jsonl") if "\"intent\": \"system\"" in _) == 3'
assert_json "уведомление — не вмешательство и не FM-1.1" "$TMP/r4.json" 'all(k not in data["interventions"]["by_reason"] for k in ("system", "correction", "request")) and "FM-1.1" not in data["mast"]["candidates"]'

# 2. вердикт ревьюера: строка «Вердикт:» главнее слов в находках; P2 — не баг
export HARNESS_TELEMETRY_DIR="$TMP/tel5"
tstart task start T1 --estimate 10
hook '{'"$B"',"hook_event_name":"SubagentStop","agent_id":"r1","agent_type":"code-reviewer","last_assistant_message":"Вердикт: APPROVE\n- P2 мелочь: файл блокируется на запись\n- P2 ещё BLOCK в описании"}'
tstart task done T1
rep "$TMP/r5.json"
assert_json "ревью: строка «Вердикт: APPROVE» главнее слов в находках" "$TMP/r5.json" 'data["review"]["verdicts"] == {"APPROVE": 1} and data["review"]["first_pass_pct"] == 100.0'
assert_json "баги: P2 не считаются" "$TMP/r5.json" 'data["bugs"]["by_review"] == 0'

# 3-4. RED до кода: правка теста — не код; echo-маскировка «exit=1»
export HARNESS_TELEMETRY_DIR="$TMP/tel6"
tstart task start T1 --estimate 10
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Write","tool_use_id":"w1","tool_input":{"file_path":"'"$R"'/tests/a_test.sh"},"tool_response":{"type":"create","filePath":"'"$R"'/tests/a_test.sh","content":"x\n","structuredPatch":[]}}'
hook '{'"$B"',"hook_event_name":"PostToolUseFailure","tool_name":"Bash","tool_use_id":"b1","tool_input":{"command":"bash tests/a_test.sh"},"error":"Exit code 1\n1 failed, 0 passed"}'
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Edit","tool_use_id":"e1","tool_input":{"file_path":"'"$R"'/src/a.sh"},"tool_response":{"filePath":"'"$R"'/src/a.sh","structuredPatch":[{"lines":["+a"]}],"userModified":false}}'
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"b2","tool_input":{"command":"bash tests/a_test.sh"},"tool_response":{"stdout":"1 passed","stderr":""}}'
tstart task done T1
rep "$TMP/r6.json"
assert_json "RED до кода: правка tests/a_test.sh — не код" "$TMP/r6.json" 'data["tests"]["tasks_red_before_code"] == 1 and data["tests"]["tasks_green_final"] == 1'

export HARNESS_TELEMETRY_DIR="$TMP/tel7"
tstart task start T1 --estimate 10
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"m1","tool_input":{"command":"bash tests/a_test.sh; echo \"case exit=$?\""},"tool_response":{"stdout":"case exit=1 ok=3","stderr":""}}'
rep "$TMP/r7.json"
assert_json "echo exit=1 при exit 0 = красный прогон" "$TMP/r7.json" 'data["tests"]["series"][-1]["status"] == "fail"'

# 5. активное время ≤ факта: ход пересекается с окном задачи
export HARNESS_TELEMETRY_DIR="$TMP/tel8"
tstart task start T1 --estimate 1
sleep 1
TS8="$(python3 -c 'import datetime;print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.000Z"))')"
printf '%s\n' '{"type":"system","subtype":"turn_duration","durationMs":600000,"timestamp":"'"$TS8"'"}' > "$P/S8.jsonl"
hook '{"session_id":"S8","transcript_path":"'"$P/S8.jsonl"'","cwd":"'"$R"'","hook_event_name":"SessionStart","source":"startup"}'
sleep 1
tstart task done T1
rep "$TMP/r8.json"
assert_json "активное время задачи ≤ фактического (+0.1)" "$TMP/r8.json" 'data["tasks"]["items"]["T1"]["active_min"] <= data["tasks"]["items"]["T1"]["actual_min"] + 0.1'

# 6. повторяющаяся рутина → кандидаты в скрипты
export HARNESS_TELEMETRY_DIR="$TMP/tel9"
tstart task start T1 --estimate 10
for i in 1 2 3; do
  hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"q'"$i"'","tool_input":{"command":"cat /Users/alice/work/notes.txt"},"tool_response":{"stdout":"x","stderr":""}}'
  hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"s'"$i"'","tool_input":{"command":"ls -l"},"tool_response":{"stdout":"x","stderr":""}}'
done
hook '{'"$B"',"hook_event_name":"PostToolUse","tool_name":"Bash","tool_use_id":"z1","tool_input":{"command":"git status --short"},"tool_response":{"stdout":"x","stderr":""}}'
rep "$TMP/r9.json"
assert_json "рутина: команда ×3 в report.routine, пути машины → ~/" "$TMP/r9.json" '[r["count"] for r in data["routine"] if r["cmd"] == "cat ~/work/notes.txt"] == [3]'
assert_json "рутина: короткие и разовые команды не попадают" "$TMP/r9.json" 'all(len(r["cmd"]) >= 12 and r["count"] >= 3 for r in data["routine"]) and not any("/Users/" in r["cmd"] for r in data["routine"])'
t "report (текст) с рутиной → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z"
t_out "текст: Кандидаты в скрипты" 'Кандидаты в скрипты'
t "report --html с рутиной → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --html '$TMP/d9.html'"
assert_file_absent "HTML рутины: нет путей машины" "$TMP/d9.html" '/(Users|home|private)/'

# 7-8. failures.md в git + подсказка ACE
export HARNESS_TELEMETRY_DIR="$TMP/tel10"
R2="$TMP/repo2"; mk_repo "$R2"
mk_commit "$R2" README.md "x" "init" >/dev/null
t "log mast в репо → exit 0" 0 bash -c "cd '$R2' && bash '$TL' log mast code=FM-2.2 note='не спросил'"
t_out "ACE: подсказка предложить правило" 'правило'
t_out "ACE: подсказка с closes=FM-2.2" 'closes=FM-2\.2'
FL="$R2/docs/failures.md"
assert_file_contains "failures.md: код FM-2.2" "$FL" 'FM-2\.2'
assert_file_contains "failures.md: название режима" "$FL" 'Не запросил уточнение'
N1="$(cat "$FL" 2>/dev/null | wc -l | tr -d ' ')"
t "log rule closes → exit 0" 0 bash -c "cd '$R2' && bash '$TL' log rule ref=pipeline-rules closes=FM-2.2"
assert_file_contains "failures.md: строка закрытия" "$FL" 'FM-2\.2.*закрыт|закрыт.*FM-2\.2'
t "повторный log mast → exit 0" 0 bash -c "cd '$R2' && bash '$TL' log mast code=FM-2.2 note='снова'"
N2="$(cat "$FL" 2>/dev/null | wc -l | tr -d ' ')"
t "failures.md только растёт" 0 test "${N1:-0}" -gt 0 -a "${N2:-0}" -gt "${N1:-0}"

# 9. оценка человека (METR)
export HARNESS_TELEMETRY_DIR="$TMP/tel11"
tstart task start T1 --estimate 10 --human-estimate 60
rep "$TMP/r11.json"
assert_json "оценка человека в отчёте (страж)" "$TMP/r11.json" 'data["tasks"]["items"]["T1"]["human_estimate_min"] == 60'
t "report (текст) с оценкой человека → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z"
t_out "текст: «человек 60» в строке задачи" 'человек 60'
t "report --html с оценкой человека → exit 0" 0 bash -c "cd '$R' && bash '$TL' report --since 2000-01-01T00:00:00Z --html '$TMP/d11.html'"
assert_file_contains "HTML: подпись «человек» рядом с 60" "$TMP/d11.html" 'человек.{0,60}60'
export HARNESS_TELEMETRY_DIR="$TMP/tel"

harness_exit
