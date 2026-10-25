#!/usr/bin/env python3
"""telemetry.py — телеметрия агентов харнесса: сырой лог действий → метрики → дашборд.

Слои:
  prompt-hook  синхронный UserPromptSubmit: логирует промпт и ведёт задачи за агента — открывает T<n>,
          просит прогноз, напоминает закрыть, на исправление курса просит MAST-классификацию.
  hook    Claude Code hook на все события (async): payload из stdin → одна JSONL-строка в
          <dir>/events.jsonl. Секреты (scripts/secret-patterns.sh + generic key=value) режутся ДО
          записи, длинные строки обрезаются head+tail. Никогда не падает: exit 0 всегда (I-8).
  task    задачи и прогноз времени (идея METR): task new|start|status|done <id> [--estimate MIN]
  log     семантика, которой не видно из хуков: mast, rule, intervention, bug, eval, manual-edit,
          milestone (name=start — начало окна отчёта, например старт хакатона).
  status  одна строка «где мы»: активная задача, прошло/прогноз, токены и $ за окно.
  report  events.jsonl + транскрипты Claude Code + git → текст | --json | --html FILE.

Каталог: $HARNESS_TELEMETRY_DIR, иначе <основной checkout>/.harness/telemetry — общий для всех
worktree и вне git: в сыром логе промпты и пути машины (AGENTS.md → «Секреты и приватность»).
Агрегаты (--json/--html) путей машины и текста промптов не содержат.

Usage-токены — только из реальных транскриптов (source=transcript); стоимость — API-эквивалент по
прайсу PRICES (на подписке это оценка, не счёт). Python ≥3.8, только stdlib.
"""
import collections
import datetime as dt
import fcntl
import hashlib
import json
import os
import re
import subprocess
import sys
from pathlib import Path

SCHEMA = 1
HARNESS_ROOT = Path(__file__).resolve().parent.parent
STR_MAX, STR_HEAD, STR_TAIL = 4000, 1500, 2500
PROMPT_MAX = 8000
LIST_MAX = 200

# USD за 1M токенов: (input, output, cache_read). Запись кэша = input×1.25 (5m) / ×2 (1h);
# speed=fast — ×2. Источник: прайс Anthropic API (кэш claude-api skill, 2026-10-06).
# Переопределение: $HARNESS_TELEMETRY_PRICES → JSON {"model": [in, out, cache_read]}.
PRICES = {
    "claude-fable-5-1": (10.0, 50.0, 0.25),
    "claude-mythos-5-1": (10.0, 50.0, 0.25),
    "claude-fable-5": (10.0, 50.0, 1.0),
    "claude-mythos-5": (10.0, 50.0, 1.0),
    "claude-opus-5-5": (4.0, 20.0, 0.20),
    "claude-opus-5": (5.0, 25.0, 0.50),
    "claude-opus-4-8": (5.0, 25.0, 0.50),
    "claude-opus-4-7": (5.0, 25.0, 0.50),
    "claude-opus-4-6": (5.0, 25.0, 0.50),
    "claude-sonnet-5-5": (2.0, 10.0, 0.20),
    "claude-sonnet-5": (2.0, 10.0, 0.20),
    "claude-sonnet-4-6": (3.0, 15.0, 0.30),
    "claude-haiku-5-5": (0.10, 0.50, 0.01),
    "claude-haiku-4-5": (1.0, 5.0, 0.10),
}

# MAST — Multi-Agent System failure Taxonomy (Cemri et al., 2025): 3 категории, 14 режимов.
MAST_FC = {
    "FC1": "Спецификация и дизайн системы",
    "FC2": "Рассогласование агентов",
    "FC3": "Верификация и завершение",
}
MAST = {
    "FM-1.1": ("FC1", "Нарушение спецификации задачи"),
    "FM-1.2": ("FC1", "Нарушение спецификации роли"),
    "FM-1.3": ("FC1", "Повтор шагов"),
    "FM-1.4": ("FC1", "Потеря истории разговора"),
    "FM-1.5": ("FC1", "Не знает условия завершения"),
    "FM-2.1": ("FC2", "Сброс разговора"),
    "FM-2.2": ("FC2", "Не запросил уточнение"),
    "FM-2.3": ("FC2", "Уход от задачи"),
    "FM-2.4": ("FC2", "Утаивание информации"),
    "FM-2.5": ("FC2", "Игнор ввода другого агента"),
    "FM-2.6": ("FC2", "Рассуждение расходится с действием"),
    "FM-3.1": ("FC3", "Преждевременное завершение"),
    "FM-3.2": ("FC3", "Нет или неполная верификация"),
    "FM-3.3": ("FC3", "Неверная верификация"),
}

TASK_STATUSES = ("todo", "doing", "review", "done", "blocked")
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
TEST_RE = re.compile(os.environ.get(
    "HARNESS_TELEMETRY_TEST_RE",
    r"(^|[\s;&|/(])(check\.sh|run-tests\.sh|agent-eval\.sh|pytest|py\.test|jest|vitest|mocha"
    r"|playwright\s+test|go\s+test|cargo\s+test|mvn\b[^;&|]*\btest|gradlew?\b[^;&|]*\btest"
    r"|rspec|phpunit|(npm|pnpm|yarn|bun)\s+(run\s+)?test|make\s+test|tox\b|unittest"
    r"|tests?/\S+\.sh)"))
REVIEW_RE = re.compile(os.environ.get("HARNESS_TELEMETRY_REVIEW_RE", r"review|critic"), re.I)
VERDICT_LINE_RE = re.compile(
    r"^\W*(?:вердикт|verdict)\s*[:—-]\s*\**\s*(APPROVE[D]?|BLOCK(?:ED)?|REQUEST[_ ]CHANGES|LGTM|ОДОБР\w*|БЛОК\w*)",
    re.I | re.M)
VERDICT_TOKEN_RE = re.compile(r"\b(APPROVE[D]?|BLOCK(?:ED)?|REQUEST_CHANGES|LGTM)\b")  # только ЗАГЛАВНЫМИ
BUG_PRIORITIES = ("P0", "P1", "CRITICAL", "HIGH", "BLOCKER")
SYSTEM_PROMPT_PREFIXES = ("<task-notification>", "<system-reminder>")
FINDING_RE = re.compile(
    r"^\s*(?:[-*•]|\d+[.)])\s*\**\s*\[?(P[0-3]|CRITICAL|HIGH|MEDIUM|BLOCKER|MAJOR)\b", re.I | re.M)
REJECT_RE = re.compile(r"doesn.t want to proceed|rejected|was denied|user denied|отклон", re.I)
CORRECTION_RE = re.compile(
    r"(^|\W)(нет[,.!\s]|не так|не то\b|не туда|неправильн|ошиб|исправь|переделай|откати|стоп\b"
    r"|хватит|я про\b|имел в виду|дебил|идиот|не надо|не нужно|wrong|that.s not|not what"
    r"|i meant|revert|undo|stop\b|don.t)", re.I)
# Одобрение — только когда ВЕСЬ промпт из слов согласия: «давай в zip архив» — это постановка задачи.
APPROVAL_WORDS = frozenset(
    "да ага ок окей ok okay yes yep go давай давайте го поехали продолжай continue согласен норм "
    "супер отлично делай делаем запускай lgtm хорошо ладно конечно верно точно именно угу +".split())


# ───────────────────────────── утилиты ─────────────────────────────

def now():
    return dt.datetime.now(dt.timezone.utc)


def iso(t):
    return t.astimezone(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.") + "%03dZ" % (t.microsecond // 1000)


def parse_ts(s):
    if not s or not isinstance(s, str):
        return None
    s = s.strip().replace("Z", "+00:00")
    m = re.match(r"^(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(\.\d+)?(.*)$", s)
    if m:  # нормализуем дробь до 6 знаков: fromisoformat до 3.11 капризен
        frac = (m.group(2) or ".0")[1:7].ljust(6, "0")
        s = "%s.%s%s" % (m.group(1), frac, m.group(3) or "+00:00")
    try:
        t = dt.datetime.fromisoformat(s)
    except ValueError:
        try:
            t = dt.datetime.fromisoformat(s[:10])
        except ValueError:
            return None
    return t if t.tzinfo else t.replace(tzinfo=dt.timezone.utc)


def git(args, cwd=None):
    try:
        r = subprocess.run(["git", *args], cwd=cwd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.SubprocessError):
        return None
    return r.stdout if r.returncode == 0 else None


def toplevel(cwd=None):
    out = git(["rev-parse", "--show-toplevel"], cwd)
    return out.strip() if out else None


def telemetry_dir(cwd=None):
    env = os.environ.get("HARNESS_TELEMETRY_DIR")
    if env:
        return Path(env)
    out = git(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd)
    if out:
        common = Path(out.strip())
        base = common.parent if common.name == ".git" else common
        return base / ".harness" / "telemetry"
    return Path(cwd or os.getcwd()) / ".harness" / "telemetry"


def wt_key(cwd):
    """Ключ worktree для указателя текущей задачи: параллельные worktree ведут свои задачи."""
    base = toplevel(cwd) or os.path.realpath(cwd or os.getcwd())
    return hashlib.sha1(base.encode()).hexdigest()[:10]


def append(path, rec):
    path.parent.mkdir(parents=True, exist_ok=True)
    line = json.dumps(rec, ensure_ascii=False, separators=(",", ": ")) + "\n"
    with open(path, "a", encoding="utf-8") as f:
        fcntl.flock(f, fcntl.LOCK_EX)
        f.write(line)
        fcntl.flock(f, fcntl.LOCK_UN)


def read_jsonl(path):
    out = []
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            for line in f:
                line = line.strip()
                if not line:
                    continue
                try:
                    v = json.loads(line)
                except ValueError:
                    continue
                if isinstance(v, dict):
                    out.append(v)
    except OSError:
        pass
    return out


# ───────────────────────────── редакция секретов ─────────────────────────────

def _secret_re():
    pats = []
    try:
        src = (HARNESS_ROOT / "scripts" / "secret-patterns.sh").read_text(encoding="utf-8")
        m = re.search(r"^SECRET_RE='(.*)'$", src, re.M)
        if m:
            pats.append(m.group(1).replace("[:space:]", r"\s"))
    except OSError:
        pass
    if not pats:  # fail-closed: без канона — минимальный встроенный набор
        pats.append(r"ghp_[A-Za-z0-9]{36,}|github_pat_\w{20,}|sk-ant-[\w-]{20,}|sk-proj-[\w-]{20,}"
                    r"|AKIA[0-9A-Z]{16}|BEGIN (RSA|OPENSSH) PRIVATE KEY")
    pats.append(r"Bearer\s+[A-Za-z0-9._~+/=-]{16,}")
    return re.compile("|".join("(?:%s)" % p for p in pats))


SECRET_RE = _secret_re()
KV_SECRET_RE = re.compile(
    r"(?i)\b((?:api[_-]?key|access[_-]?token|auth[_-]?token|secret|password|passwd|pwd)\s*[=:]\s*)"
    r"(['\"]?)[^\s'\"]{6,}\2")


def redact(s):
    s = SECRET_RE.sub("[REDACTED]", s)
    return KV_SECRET_RE.sub(lambda m: m.group(1) + "[REDACTED]", s)


def clip(s, limit=STR_MAX):
    if len(s) <= limit:
        return s
    head = int(limit * STR_HEAD / STR_MAX)
    tail = limit - head
    return "%s\n…[+%d симв.]…\n%s" % (s[:head], len(s) - limit, s[-tail:])


def sanitize(v, limit=STR_MAX):
    if isinstance(v, str):
        return clip(redact(v), limit)
    if isinstance(v, dict):
        return {k: sanitize(x, limit) for k, x in v.items()}
    if isinstance(v, list):
        out = [sanitize(x, limit) for x in v[:LIST_MAX]]
        if len(v) > LIST_MAX:
            out.append("…[+%d элементов]" % (len(v) - LIST_MAX))
        return out
    return v


# ───────────────────────────── hook ─────────────────────────────

def current_task(tdir, cwd):
    if os.environ.get("HARNESS_TASK"):
        return os.environ["HARNESS_TASK"]
    try:
        v = json.loads((tdir / "current" / (wt_key(cwd) + ".json")).read_text(encoding="utf-8"))
        return v.get("task")
    except (OSError, ValueError):
        return None


def rel_path(path, cwd):
    if not isinstance(path, str):
        return None
    top = toplevel(cwd) if cwd else None
    if top and path.startswith(top.rstrip("/") + "/"):
        return path[len(top.rstrip("/")) + 1:]
    return os.path.basename(path)


def count_tests(text):
    if not isinstance(text, str):
        return {}
    out = {}
    m = re.search(r"\bpass=(\d+)\s+fail=(\d+)", text)  # ИТОГ tests/harness/run-tests.sh
    if m:
        return {"passed": int(m.group(1)), "failed": int(m.group(2))}
    p = re.findall(r"(\d+)\s+(?:passed|passing|tests? passed)\b", text, re.I)
    f = re.findall(r"(\d+)\s+(?:failed|failing|failures?|errors?)\b", text, re.I)
    if not f:  # `… | sort | uniq -c` → «  14 FAIL»; построчный вывод tests/harness → «FAIL  <имя>»
        f = re.findall(r"(\d+)\s+FAIL\b", text) or (
            [str(len(re.findall(r"^FAIL\s", text, re.M)))] if re.search(r"^FAIL\s", text, re.M) else [])
    if p:
        out["passed"] = int(p[-1])
    if f:
        out["failed"] = int(f[-1])
    return out


def loc_of(tool, resp):
    if not isinstance(resp, dict):
        return None
    added = removed = 0
    for h in resp.get("structuredPatch") or []:
        for ln in (h.get("lines") or []) if isinstance(h, dict) else []:
            if isinstance(ln, str) and ln.startswith("+"):
                added += 1
            elif isinstance(ln, str) and ln.startswith("-"):
                removed += 1
    if not added and not removed and resp.get("type") == "create":
        added = len((resp.get("content") or "").splitlines())
    return {"added": added, "removed": removed}


TEST_PATH_RE = re.compile(r"(^|/)(tests?|__tests__|specs?)/|(^|/)test_[^/]*$|[._](test|spec)\.[^/]+$")


def is_test_path(path):
    return bool(path) and bool(TEST_PATH_RE.search(path))


def mask_paths(s):
    """Пути машины → ~ / <tmp>: агрегаты (JSON/HTML) показывают без станционных путей (AGENTS.md)."""
    s = re.sub(r"/(?:Users|home)/[^/\s'\"]+", "~", s)
    return re.sub(r"(?:/private)?/(?:var/folders|tmp)/[^\s'\"]*", "<tmp>", s)


def classify_prompt(text):
    s = (text or "").strip()
    if not s:
        return "empty"
    if s.startswith(SYSTEM_PROMPT_PREFIXES):  # уведомления среды о субагентах и т.п. — не человек
        return "system"
    if s.startswith("/"):
        return "command"
    if CORRECTION_RE.search(s):
        return "correction"
    words = re.findall(r"[\w+]+", s.lower())
    if words and all(w in APPROVAL_WORDS for w in words):
        return "approval"
    if s.endswith("?"):
        return "question"
    return "request"


def parse_verdict(text):
    if not isinstance(text, str):
        return None
    prios = [f.upper() for f in FINDING_RE.findall(text)]
    bugs = sum(1 for f in prios if f in BUG_PRIORITIES)
    m = VERDICT_LINE_RE.search(text) or VERDICT_TOKEN_RE.search(text)
    if not m:
        return {"verdict": "unknown", "findings": len(prios), "bugs": bugs}
    word = m.group(1).upper()
    verdict = "APPROVE" if word.startswith(("APPROVE", "LGTM", "ОДОБР")) else "BLOCK"
    return {"verdict": verdict, "findings": len(prios), "bugs": bugs}


def derive(ev, tool, p, cwd):
    d = {}
    tin = p.get("tool_input") if isinstance(p.get("tool_input"), dict) else {}
    resp = p.get("tool_response")
    if tool in EDIT_TOOLS:
        if ev == "PostToolUse":
            loc = loc_of(tool, resp)
            if loc:
                d["loc"] = loc
            d["file"] = rel_path((resp or {}).get("filePath") if isinstance(resp, dict) else None, cwd) \
                or rel_path(tin.get("file_path") or tin.get("notebook_path"), cwd)
            if isinstance(resp, dict) and resp.get("userModified"):
                d["user_modified"] = True
        elif ev in ("PostToolUseFailure", "PermissionDenied"):
            if ev == "PermissionDenied" or REJECT_RE.search(str(p.get("error") or "")):
                d["rejected"] = True
    if tool == "Bash" and ev in ("PostToolUse", "PostToolUseFailure"):
        cmd = str(tin.get("command") or "")
        if TEST_RE.search(cmd):
            if ev == "PostToolUse" and isinstance(resp, dict):
                text = "%s\n%s" % (resp.get("stdout") or "", resp.get("stderr") or "")
                status = "fail" if resp.get("interrupted") else "pass"
            else:
                text = str(p.get("error") or "")
                status = "interrupted" if p.get("is_interrupt") else "fail"
            counts = count_tests(text)
            # пайп или `; echo exit=$?` съел exit-код, но провал виден в выводе
            if status == "pass" and (counts.get("failed") or re.search(r"\bexit=[1-9]\d*\b", text)):
                status = "fail"
            d["test"] = dict(status=status, **counts)
        if ev == "PostToolUse" and re.search(r"\bgh\s+pr\s+create\b", cmd):
            d["pr"] = True
        if ev == "PostToolUse" and "agent-eval.sh" in cmd:
            top = toplevel(cwd)
            try:
                lr = json.loads((Path(top) / "tests/agent-evals/last-run.json").read_text(encoding="utf-8"))
                d["eval"] = {"name": "agent-eval", "score": float(lr.get("pct_resolved")) / 100.0}
            except (OSError, ValueError, TypeError):
                pass
    if ev == "PostToolUse" and tool == "ReportFindings":
        n = len(tin.get("findings") or [])
        d["review"] = {"verdict": "BLOCK" if n else "APPROVE", "findings": n, "reviewer": "code-review"}
    if ev == "SubagentStop" and REVIEW_RE.search(str(p.get("agent_type") or "")):
        v = parse_verdict(p.get("last_assistant_message"))
        if v and v["verdict"] != "unknown":
            d["review"] = dict(v, reviewer=p.get("agent_type"))
    if ev == "UserPromptSubmit":
        d["intent"] = classify_prompt(p.get("prompt"))
    return d


def hook_record(p, cwd, tdir):
    ev = p.get("hook_event_name")
    tool = p.get("tool_name")
    rec = {"v": SCHEMA, "ts": iso(now()), "src": "hook", "ev": ev,
           "session": p.get("session_id"), "agent_id": p.get("agent_id"),
           "agent_type": p.get("agent_type"), "cwd": cwd,
           "transcript": p.get("transcript_path"), "mode": p.get("permission_mode"),
           "task": current_task(tdir, cwd), "tool": tool, "tool_use_id": p.get("tool_use_id")}
    if "tool_input" in p:
        rec["input"] = sanitize(p["tool_input"])
    if "tool_response" in p:
        rec["resp"] = sanitize(p["tool_response"])
    for k in ("prompt", "last_assistant_message"):
        if k in p:
            rec[k] = sanitize(p[k], PROMPT_MAX)
    for k in ("error", "reason", "source", "message", "agent_transcript_path", "trigger",
              "notification_type", "is_interrupt", "stop_hook_active", "custom_instructions"):
        if k in p:
            rec[k] = sanitize(p[k])
    d = derive(ev, tool, p, cwd)
    if d:
        rec["d"] = d
    return {k: v for k, v in rec.items() if v is not None}


def _read_payload():
    raw = sys.stdin.read()
    p = json.loads(raw) if raw.strip() else None
    return p if isinstance(p, dict) else None


def _hook_error(e):
    try:
        append(telemetry_dir() / "hook-errors.jsonl", {"ts": iso(now()), "error": repr(e)[:500]})
    except Exception:  # noqa: BLE001
        pass


def cmd_hook(_args):
    try:
        p = _read_payload()
        if p:
            cwd = p.get("cwd") or os.getcwd()
            tdir = telemetry_dir(cwd)
            append(tdir / "events.jsonl", hook_record(p, cwd, tdir))
    except Exception as e:  # noqa: BLE001 — телеметрия не имеет права ронять сессию
        _hook_error(e)
    return 0


TL_CMD = "bash scripts/telemetry.sh"
MAST_HINT = ("FM-1.1 нарушил ТЗ · FM-1.3 повторял шаги · FM-2.2 не уточнил · FM-2.3 ушёл от задачи · "
             "FM-3.1 закончил рано · FM-3.2 не проверил · FM-3.3 проверил неверно")


def next_task_id(tdir):
    ids = [int(m.group(1)) for e in read_jsonl(tdir / "events.jsonl") if e.get("ev") == "task"
           for m in [re.match(r"^T(\d+)$", str(e.get("id") or ""))] if m]
    return "T%d" % (max(ids) + 1 if ids else 1)


def task_title(tdir, tid):
    title = None
    for e in read_jsonl(tdir / "events.jsonl"):
        if e.get("ev") == "task" and e.get("id") == tid and e.get("title"):
            title = e["title"]
    return title


def set_pointer(tdir, cwd, tid):
    ptr = tdir / "current" / (wt_key(cwd) + ".json")
    ptr.parent.mkdir(parents=True, exist_ok=True)
    ptr.write_text(json.dumps({"task": tid, "ts": iso(now())}), encoding="utf-8")


def cmd_prompt_hook(_args):
    """Синхронный UserPromptSubmit: логирует промпт и ведёт задачи за агента.

    Нет активной задачи и промпт — постановка (не одобрение) → открывает T<n> и просит агента дать
    прогноз и заголовок (заголовок не берётся из промпта: агрегаты без текста промптов). Активная
    задача и новая просьба → напоминает закрыть её, если это другая работа. Исправление курса →
    просит классифицировать сбой по MAST. Подсказка уходит агенту через additionalContext.
    """
    try:
        p = _read_payload()
        if not p:
            return 0
        cwd = p.get("cwd") or os.getcwd()
        tdir = telemetry_dir(cwd)
        intent = classify_prompt(p.get("prompt"))
        active = current_task(tdir, cwd)
        ctx = []
        if not active and intent not in ("approval", "empty", "system"):
            tid = next_task_id(tdir)
            append(tdir / "events.jsonl", {"v": SCHEMA, "ts": iso(now()), "src": "hook", "ev": "task",
                                           "id": tid, "task": tid, "status": "doing", "auto": True,
                                           "session": p.get("session_id"), "cwd_key": wt_key(cwd)})
            set_pointer(tdir, cwd, tid)
            ctx.append("Телеметрия: открыта задача %s. До начала работы дай прогноз и короткий заголовок: "
                       "`%s task estimate %s <мин> --title \"…\"`; по завершении — `%s task done %s`."
                       % (tid, TL_CMD, tid, TL_CMD, tid))
        elif active and intent == "request":
            title = task_title(tdir, active)
            ctx.append("Телеметрия: активна %s%s. Если это новая работа — `%s task done %s && %s task start "
                       "auto --estimate <мин> --title \"…\"`." % (
                           active, " «%s»" % title if title else "", TL_CMD, active, TL_CMD))
        if intent == "correction":
            ctx.append("Телеметрия: похоже на исправление курса. Если это сбой агента — классифицируй: "
                       "`%s log mast code=FM-x.y note=\"…\"` (%s)." % (TL_CMD, MAST_HINT))
        append(tdir / "events.jsonl", hook_record(p, cwd, tdir))
        if ctx:
            print(json.dumps({"hookSpecificOutput": {"hookEventName": "UserPromptSubmit",
                                                     "additionalContext": "\n".join(ctx)}}, ensure_ascii=False))
    except Exception as e:  # noqa: BLE001
        _hook_error(e)
    return 0


# ───────────────────────────── task / log ─────────────────────────────

def cli_event(ev, fields):
    cwd = os.getcwd()
    tdir = telemetry_dir(cwd)
    rec = {"v": SCHEMA, "ts": iso(now()), "src": "cli", "ev": ev, "cwd_key": wt_key(cwd)}
    if "task" not in fields:
        t = current_task(tdir, cwd)
        if t:
            rec["task"] = t
    rec.update({k: sanitize(v) if isinstance(v, str) else v for k, v in fields.items() if v is not None})
    append(tdir / "events.jsonl", rec)
    return tdir, rec


def _num(s, name):
    try:
        return float(s)
    except (TypeError, ValueError):
        raise SystemExit("telemetry: %s должно быть числом, получено %r" % (name, s))


def cmd_task(args):
    if len(args) < 2 or args[0] not in ("new", "start", "status", "review", "done", "block", "estimate"):
        print("usage: telemetry task new|start|review|done|block <id|auto> [--title T] [--estimate MIN] "
              "[--human-estimate MIN]\n       telemetry task status <id> <%s>\n"
              "       telemetry task estimate <id> <MIN> [--title T]" % "|".join(TASK_STATUSES),
              file=sys.stderr)
        return 2
    action, tid, rest = args[0], args[1], args[2:]
    if tid == "auto" and action in ("new", "start"):
        tid = next_task_id(telemetry_dir(os.getcwd()))
    status = {"new": "todo", "start": "doing", "review": "review", "done": "done", "block": "blocked"}.get(action)
    if action == "estimate":
        if not rest:
            print("telemetry: task estimate <id> <MIN>", file=sys.stderr)
            return 2
        rest = ["--estimate"] + rest
    if action == "status":
        if not rest or rest[0] not in TASK_STATUSES:
            print("telemetry: статус — один из %s" % ", ".join(TASK_STATUSES), file=sys.stderr)
            return 2
        status, rest = rest[0], rest[1:]
    fields = {"task": tid, "id": tid, "status": status}
    i = 0
    while i < len(rest):
        flag = rest[i]
        val = rest[i + 1] if i + 1 < len(rest) else None
        if flag == "--title":
            fields["title"] = val
        elif flag == "--estimate":
            fields["estimate_min"] = _num(val, "--estimate")
        elif flag == "--human-estimate":
            fields["human_estimate_min"] = _num(val, "--human-estimate")
        else:
            print("telemetry: неизвестный флаг %s" % flag, file=sys.stderr)
            return 2
        i += 2
    tdir, _ = cli_event("task", {k: v for k, v in fields.items() if v is not None})
    ptr = tdir / "current" / (wt_key(os.getcwd()) + ".json")
    if status == "doing":
        set_pointer(tdir, os.getcwd(), tid)
    elif status in ("done", "blocked", "todo"):
        try:
            if json.loads(ptr.read_text(encoding="utf-8")).get("task") == tid:
                ptr.unlink()
        except (OSError, ValueError):
            pass
    print("telemetry: task %s → %s" % (tid, status or "прогноз %g мин" % fields["estimate_min"]))
    return 0


LOG_KINDS = {
    "mast": "code=FM-x.y [note=…] — подтверждённая ошибка по MAST",
    "rule": "ref=<файл/якорь/guard> [closes=FM-x.y] — правило добавлено в плейбук",
    "intervention": "reason=<причина> [note=…] — вмешательство человека, которого не видно хукам",
    "bug": "source=review|test|human|prod [note=…] — найденный баг",
    "eval": "name=<набор> score=<0..1> [iteration=N] — эвал-скор (RAG/LLM-судья/agent-eval)",
    "manual-edit": "[files=…] [note=…] — человек правил код руками",
    "milestone": "name=<метка> — веха; name=start открывает окно отчёта",
    "review": "verdict=APPROVE|BLOCK [findings=N] [bugs=P0+P1] [reviewer=…] — круг ревью вне субагентов",
}


FAILURES_HEADER = ("# failures.md — сбои агентов по MAST (append-only; пишет `scripts/telemetry.sh log mast|rule`)\n\n"
                   "| ts (UTC) | код | категория | режим / событие | задача | заметка |\n|---|---|---|---|---|---|\n")


def failures_append(kind, rec):
    """docs/failures.md репозитория: ошибки видит вся команда, а не только локальный лог (best-effort, I-8)."""
    try:
        top = toplevel(os.getcwd())
        if not top:
            return
        path = Path(top) / "docs" / "failures.md"
        cell = lambda v: mask_paths(" ".join(str(v or "-").split())).replace("|", "∕")  # noqa: E731
        if kind == "mast":
            fc, name = MAST[rec["code"]]
            row = [rec["ts"], rec["code"], "%s %s" % (fc, MAST_FC[fc]), name, rec.get("task"), rec.get("note")]
        else:
            row = [rec["ts"], rec["closes"], "закрыт правилом", rec.get("ref"), rec.get("task"), rec.get("note")]
        path.parent.mkdir(parents=True, exist_ok=True)
        new = not path.exists()
        with open(path, "a", encoding="utf-8") as f:
            if new:
                f.write(FAILURES_HEADER)
            f.write("| %s |\n" % " | ".join(cell(v) for v in row))
    except Exception as e:  # noqa: BLE001
        print("telemetry: WARN — docs/failures.md не дописан: %r" % e, file=sys.stderr)


def cmd_log(args):
    if not args or args[0] not in LOG_KINDS:
        print("usage: telemetry log <kind> key=value …\n" +
              "\n".join("  %-12s %s" % (k, v) for k, v in LOG_KINDS.items()), file=sys.stderr)
        return 2
    kind, fields = args[0], {}
    for a in args[1:]:
        if "=" not in a:
            print("telemetry: ожидаю key=value, получено %r" % a, file=sys.stderr)
            return 2
        k, v = a.split("=", 1)
        fields[k] = v
    need = {"mast": "code", "rule": "ref", "intervention": "reason", "bug": "source",
            "eval": "name", "milestone": "name", "review": "verdict"}.get(kind)
    if need and not fields.get(need):
        print("telemetry: log %s требует %s=" % (kind, need), file=sys.stderr)
        return 2
    if kind == "review":
        fields["verdict"] = fields["verdict"].upper()
        if fields["verdict"] not in ("APPROVE", "BLOCK"):
            print("telemetry: verdict — APPROVE или BLOCK", file=sys.stderr)
            return 2
        for key in ("findings", "bugs"):
            if key in fields:
                fields[key] = int(_num(fields[key], key))
    for key in ("code", "closes"):
        if key in fields and (kind in ("mast", "rule")):
            fields[key] = fields[key].upper()
            if fields[key] not in MAST:
                print("telemetry: неизвестный MAST-код %s (есть: %s)" % (fields[key], ", ".join(MAST)),
                      file=sys.stderr)
                return 2
    if kind == "eval":
        fields["score"] = _num(fields.get("score"), "score")
        if "iteration" in fields:
            fields["iteration"] = int(_num(fields["iteration"], "iteration"))
    _, rec = cli_event(kind, fields)
    print("telemetry: %s записан" % kind)
    if kind == "mast" or (kind == "rule" and fields.get("closes")):
        failures_append(kind, rec)
    if kind == "mast":
        print("telemetry: предложи владельцу ОДНО правило, закрывающее этот сбой (ACE); после «ок» — запись в "
              "docs/pipeline-rules.md и `bash scripts/telemetry.sh log rule ref=… closes=%s`" % fields["code"])
    return 0


# ───────────────────────────── транскрипты ─────────────────────────────

def price_table():
    table = dict(PRICES)
    path = os.environ.get("HARNESS_TELEMETRY_PRICES")
    if path:
        try:
            table.update({k: tuple(v) for k, v in json.loads(Path(path).read_text()).items()})
        except (OSError, ValueError, TypeError):
            pass
    return table


def price_for(model, table):
    m = re.sub(r"\[.*?\]$", "", model or "")
    best = None
    for k in table:
        if m == k or m.startswith(k + "-") or m.startswith(k + "@"):
            if best is None or len(k) > len(best):
                best = k
    return table.get(best) if best else None


def usage_cost(model, u, table):
    pr = price_for(model, table)
    if not pr:
        return None
    pin, pout, pcr = pr
    cc = u.get("cache_creation") or {}
    c1h = int(cc.get("ephemeral_1h_input_tokens") or 0)
    c5 = int(u.get("cache_creation_input_tokens") or 0) - c1h
    c5 = max(c5, 0)
    usd = (int(u.get("input_tokens") or 0) * pin + int(u.get("output_tokens") or 0) * pout
           + int(u.get("cache_read_input_tokens") or 0) * pcr + c5 * pin * 1.25 + c1h * pin * 2.0) / 1e6
    return usd * (2.0 if u.get("speed") == "fast" else 1.0)


def _text_of(content):
    if isinstance(content, str):
        return content
    if isinstance(content, list):
        return " ".join(c.get("text", "") for c in content if isinstance(c, dict))
    return ""


def load_transcripts(paths, since):
    """→ (messages, turns, interrupts). messages: dedup по message.id, роль из subagents/*.meta.json."""
    msgs, turns, interrupts = {}, [], []
    seen_files = set()

    def scan(path, role, main):
        rp = os.path.realpath(path)
        if rp in seen_files or not os.path.isfile(rp):
            return
        seen_files.add(rp)
        for e in read_jsonl(rp):
            t = parse_ts(e.get("timestamp"))
            if t is None or t < since:
                continue
            typ = e.get("type")
            if typ == "assistant":
                m = e.get("message") or {}
                u = m.get("usage")
                model = m.get("model")
                if not isinstance(u, dict) or not model or model.startswith("<"):
                    continue
                key = m.get("id") or e.get("requestId") or e.get("uuid")
                if key in msgs:
                    continue
                msgs[key] = {"ts": t, "model": model, "role": role, "usage": u}
            elif main and typ == "system" and e.get("subtype") == "turn_duration":
                turns.append({"ts": t, "ms": int(e.get("durationMs") or 0)})
            elif main and typ == "user":
                txt = _text_of((e.get("message") or {}).get("content"))
                if txt.lstrip().startswith("[Request interrupted by user"):
                    interrupts.append({"ts": t})

    for p in paths:
        if not p:
            continue
        scan(p, "main", True)
        sub = Path(re.sub(r"\.jsonl$", "", p)) / "subagents"
        if sub.is_dir():
            for f in sorted(sub.glob("agent-*.jsonl")):
                role = "subagent"
                try:
                    meta = json.loads(f.with_name(f.name[:-6] + ".meta.json").read_text(encoding="utf-8"))
                    role = meta.get("agentType") or role
                except (OSError, ValueError):
                    pass
                scan(str(f), role, False)
    return list(msgs.values()), turns, interrupts


# ───────────────────────────── агрегация ─────────────────────────────

def _bucket(t, minutes=15):
    t = t.astimezone(dt.timezone.utc)
    return iso(t.replace(minute=t.minute - t.minute % minutes, second=0, microsecond=0))


def _zero_tok():
    return {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "thinking": 0, "total": 0, "usd": 0.0}


def _add_tok(acc, u, usd):
    i, o = int(u.get("input_tokens") or 0), int(u.get("output_tokens") or 0)
    cr, cw = int(u.get("cache_read_input_tokens") or 0), int(u.get("cache_creation_input_tokens") or 0)
    acc["input"] += i
    acc["output"] += o
    acc["cache_read"] += cr
    acc["cache_write"] += cw
    acc["thinking"] += int((u.get("output_tokens_details") or {}).get("thinking_tokens") or 0)
    acc["total"] += i + o + cr + cw
    acc["usd"] += usd or 0.0


def resolve_since(events, since_arg):
    if since_arg:
        t = parse_ts(since_arg)
        if t is None:
            raise SystemExit("telemetry: не разобрал --since %r" % since_arg)
        return t
    starts = [parse_ts(e["ts"]) for e in events if e.get("ev") == "milestone" and e.get("name") == "start"]
    if starts:
        return max(starts)
    ts = [parse_ts(e.get("ts")) for e in events]
    ts = [t for t in ts if t]
    return min(ts) if ts else dt.datetime(1970, 1, 1, tzinfo=dt.timezone.utc)


def git_stats(cwd, since):
    top = toplevel(cwd)
    out = {"commits": 0, "ai_commits": 0, "ai_added": 0, "ai_removed": 0, "human_added": 0,
           "human_removed": 0, "series": [], "human_commit_ts": []}
    if not top:
        return out, None
    log = git(["log", "--no-merges", "--since=" + iso(since), "--reverse",
               "--pretty=format:%x1e%H%x1f%aI%x1f%B%x1f", "--numstat"], top) or ""
    for rec in log.split("\x1e"):
        if not rec.strip():
            continue
        parts = rec.split("\x1f")
        if len(parts) < 4:
            continue
        sha, date, body, stats = parts[0].strip(), parts[1], parts[2], parts[3]
        ai = bool(re.search(r"Co-Authored-By", body))
        add = rem = 0
        for ln in stats.strip().splitlines():
            cols = ln.split("\t")
            if len(cols) >= 2 and cols[0].isdigit() and cols[1].isdigit():
                add += int(cols[0])
                rem += int(cols[1])
        out["commits"] += 1
        out["ai_commits"] += 1 if ai else 0
        out["ai_added" if ai else "human_added"] += add
        out["ai_removed" if ai else "human_removed"] += rem
        out["series"].append({"ts": date, "sha": sha[:8], "ai": ai, "added": add, "removed": rem})
        if not ai:
            out["human_commit_ts"].append(parse_ts(date))
    return out, top


def routine_candidates(hook, min_count=3, min_len=12):
    """Bash-команда ≥3 раз — кандидат в скрипт/скилл (Live-SWE-agent, Darwin Gödel Machine)."""
    seen = collections.Counter()
    for e in hook:
        if e.get("tool") == "Bash" and e.get("ev") in ("PostToolUse", "PostToolUseFailure"):
            cmd = " ".join(str((e.get("input") or {}).get("command") or "").split())
            if len(cmd) >= min_len:
                seen[mask_paths(cmd)[:160]] += 1
    return [{"cmd": c, "count": n} for c, n in seen.most_common(10) if n >= min_count]


def count_rules(txt):
    """Правило плейбука = пункт `- **…**` в docs/pipeline-rules.md."""
    return len(re.findall(r"^\s*-\s+\*\*", txt or "", re.M))


def playbook_stats(top, rule_events):
    series = []
    rel = "docs/pipeline-rules.md"
    if top:
        log = git(["log", "--reverse", "--format=%H%x1f%aI", "--", rel], top) or ""
        for ln in log.splitlines():
            sha, _, date = ln.partition("\x1f")
            series.append({"ts": date, "sha": sha[:8], "rules": count_rules(git(["show", "%s:%s" % (sha, rel)], top))})
        try:
            cur = count_rules((Path(top) / rel).read_text(encoding="utf-8"))
            if not series or series[-1]["rules"] != cur:
                series.append({"ts": iso(now()), "sha": "worktree", "rules": cur})
        except OSError:
            pass
    return {"series": series, "logged_rules": len(rule_events),
            "rules_now": series[-1]["rules"] if series else 0}


def build_report(events, since, cwd):
    events = [e for e in events if parse_ts(e.get("ts")) and parse_ts(e["ts"]) >= since]
    events.sort(key=lambda e: e["ts"])
    for e in events:
        e["_t"] = parse_ts(e["ts"])
    hook = [e for e in events if e.get("src") == "hook"]
    cli = [e for e in events if e.get("src") == "cli"]
    by_ev = collections.defaultdict(list)
    for e in cli + [x for x in hook if x.get("ev") == "task"]:
        by_ev[e.get("ev")].append(e)
    by_ev["task"].sort(key=lambda e: e["ts"])

    # ── задачи (replay) и окна времени
    tasks = collections.OrderedDict()
    status_series = []
    for e in by_ev["task"]:
        it = tasks.setdefault(e["id"], {"id": e["id"], "title": None, "status": None, "estimate_min": None,
                                        "human_estimate_min": None, "started": None, "done": None})
        for k in ("title", "estimate_min", "human_estimate_min"):
            if e.get(k) is not None:
                it[k] = e[k]
        if not e.get("status"):
            continue
        it["status"] = e["status"]
        if e["status"] == "doing" and it["started"] is None:
            it["started"] = e["_t"]
        if e["status"] == "done":
            it["done"] = e["_t"]
        status_series.append({"ts": e["ts"], "counts": dict(collections.Counter(t["status"] for t in tasks.values()))})

    def task_at(t):
        best = None
        for it in tasks.values():
            if it["started"] and it["started"] <= t <= (it["done"] or now()):
                if best is None or it["started"] > best["started"]:
                    best = it
        return best["id"] if best else None

    # ── транскрипты: токены, стоимость, активное время, прерывания
    paths = []
    for e in hook:
        for k in ("transcript", "agent_transcript_path"):
            p = e.get(k)
            if p and k == "transcript" and p not in paths:
                paths.append(p)
    msgs, turns, interrupts = load_transcripts(paths, since)
    table = price_table()
    tok = {"total": _zero_tok(), "by_model": {}, "by_role": {}, "by_role_model": {}, "timeline": {},
           "unpriced_models": [], "source": "transcript"}
    per_task_tok = collections.defaultdict(_zero_tok)
    for m in msgs:
        usd = usage_cost(m["model"], m["usage"], table)
        if usd is None and m["model"] not in tok["unpriced_models"]:
            tok["unpriced_models"].append(m["model"])
        _add_tok(tok["total"], m["usage"], usd)
        _add_tok(tok["by_model"].setdefault(m["model"], _zero_tok()), m["usage"], usd)
        _add_tok(tok["by_role"].setdefault(m["role"], _zero_tok()), m["usage"], usd)
        _add_tok(tok["by_role_model"].setdefault("%s · %s" % (m["role"], m["model"]), _zero_tok()), m["usage"], usd)
        b = tok["timeline"].setdefault(_bucket(m["ts"]), {})
        b[m["model"]] = b.get(m["model"], 0) + int(m["usage"].get("output_tokens") or 0) \
            + int(m["usage"].get("input_tokens") or 0)
        tid = task_at(m["ts"])
        if tid:
            _add_tok(per_task_tok[tid], m["usage"], usd)
    tok["timeline"] = [{"ts": k, "by_model": v} for k, v in sorted(tok["timeline"].items())]
    cost = {"total_usd": round(tok["total"]["usd"], 6),
            "by_model": {k: round(v["usd"], 6) for k, v in tok["by_model"].items()},
            "by_role": {k: round(v["usd"], 6) for k, v in tok["by_role"].items()},
            "basis": "API-эквивалент по прайсу; на подписке — оценка, не счёт"}
    active_ms = sum(t["ms"] for t in turns)
    per_task_active = collections.Counter()
    for t in turns:  # ход [ts − ms, ts] ∩ окно задачи [start, done]
        t_end = t["ts"]
        t_start = t_end - dt.timedelta(milliseconds=t["ms"])
        for it in tasks.values():
            if not it["started"]:
                continue
            ov = (min(t_end, it["done"] or now()) - max(t_start, it["started"])).total_seconds()
            if ov > 0:
                per_task_active[it["id"]] += ov * 1000.0
    active = {"minutes": round(active_ms / 60000.0, 1), "turns": len(turns),
              "wall_minutes": round(((events[-1]["_t"] - events[0]["_t"]).total_seconds() / 60.0), 1) if events else 0.0,
              "sessions": len({e.get("session") for e in hook if e.get("session")})}

    # ── инструменты и правки
    tool_counts = collections.Counter(e.get("tool") for e in hook if e.get("ev") == "PostToolUse" and e.get("tool"))
    tool_fail = collections.Counter(e.get("tool") for e in hook if e.get("ev") == "PostToolUseFailure" and e.get("tool"))
    loc = {"added": 0, "removed": 0, "files": 0}
    files = set()
    first_edit = {}
    edits = {"accepted": 0, "rejected": 0, "user_modified": 0, "permission_prompts": 0}
    for e in hook:
        d = e.get("d") or {}
        if e.get("tool") in EDIT_TOOLS:
            if e.get("ev") == "PostToolUse":
                edits["accepted"] += 1
                edits["user_modified"] += 1 if d.get("user_modified") else 0
                if d.get("loc"):
                    loc["added"] += d["loc"]["added"]
                    loc["removed"] += d["loc"]["removed"]
                if d.get("file"):
                    files.add(d["file"])
                tid = e.get("task") or task_at(e["_t"])
                if tid and tid not in first_edit and not is_test_path(d.get("file")):
                    first_edit[tid] = e["_t"]
            elif d.get("rejected"):
                edits["rejected"] += 1
            if e.get("ev") == "PermissionRequest":
                edits["permission_prompts"] += 1
    loc["files"] = len(files)

    # ── тесты
    runs = []
    for e in hook:
        tr = (e.get("d") or {}).get("test")
        if tr:
            runs.append(dict(tr, ts=e["ts"], _t=e["_t"], task=e.get("task") or task_at(e["_t"])))
    red = [r for r in runs if r["status"] == "fail"]
    green = [r for r in runs if r["status"] == "pass"]
    by_task_runs = collections.defaultdict(list)
    for r in runs:
        if r["task"]:
            by_task_runs[r["task"]].append(r)
    red_before = sum(1 for tid, rs in by_task_runs.items()
                     if rs[0]["status"] == "fail" and (tid not in first_edit or rs[0]["_t"] <= first_edit[tid]))
    green_final = sum(1 for rs in by_task_runs.values() if rs[-1]["status"] == "pass")
    tests = {"runs": len(runs), "red": len(red), "green": len(green),
             "red_before_code": sum(1 for r in red if r["task"] and (r["task"] not in first_edit or r["_t"] <= first_edit[r["task"]])),
             "tasks_with_tests": len(by_task_runs), "tasks_red_before_code": red_before,
             "tasks_green_final": green_final,
             "first_failed_sum": sum(rs[0].get("failed", 0) for rs in by_task_runs.values() if rs[0]["status"] == "fail"),
             "final_passed_sum": sum(rs[-1].get("passed", 0) for rs in by_task_runs.values() if rs[-1]["status"] == "pass"),
             "series": [{"ts": r["ts"], "status": r["status"], "passed": r.get("passed"), "failed": r.get("failed"),
                         "task": r["task"]} for r in runs]}

    # ── ревью
    reviews = []
    for e in hook:
        rv = (e.get("d") or {}).get("review")
        if rv:
            reviews.append(dict(rv, ts=e["ts"], task=e.get("task") or task_at(e["_t"]) or "-"))
    for e in by_ev["review"]:  # log review — ревьюер вне субагентов (scripts/review-cross.sh, Codex)
        r = {k: e[k] for k in ("verdict", "findings", "bugs", "reviewer") if k in e}
        reviews.append(dict(r, ts=e["ts"], task=e.get("task") or task_at(e["_t"]) or "-"))
    reviews.sort(key=lambda r: r["ts"])
    rounds = collections.OrderedDict()
    for r in reviews:
        rounds.setdefault(r["task"], []).append(r)
    first_pass = [rs[0]["verdict"] == "APPROVE" for rs in rounds.values()]
    review = {"rounds_total": len(reviews), "rounds_per_task": {k: len(v) for k, v in rounds.items()},
              "tasks_reviewed": len(rounds),
              "first_pass_pct": round(100.0 * sum(first_pass) / len(first_pass), 1) if first_pass else None,
              "avg_rounds": round(len(reviews) / float(len(rounds)), 2) if rounds else None,
              "verdicts": dict(collections.Counter(r["verdict"] for r in reviews))}

    # ── баги до мержа
    bug_ev = collections.Counter(e.get("source") for e in by_ev["bug"])
    # bugs (P0+P1) — если ревьюер их посчитал; иначе BLOCK = находки, минимум одна
    bugs = {"by_review": sum(r["bugs"] if "bugs" in r else
                             (max(r.get("findings", 0), 1) if r["verdict"] == "BLOCK" else 0) for r in reviews)
            + bug_ev.get("review", 0),
            "by_tests": len(red) + bug_ev.get("test", 0),
            "by_human": bug_ev.get("human", 0), "in_prod": bug_ev.get("prod", 0)}

    # ── вмешательства человека
    reasons = collections.Counter()
    samples = []
    first_seen = set()
    task_starts = [e for e in by_ev["task"] if e.get("status") == "doing"]
    last_prompt_t = {}
    for e in hook:
        ev = e.get("ev")
        if ev == "UserPromptSubmit":
            sess = e.get("session")
            intent = classify_prompt(e.get("prompt")) if e.get("prompt") else (e.get("d") or {}).get("intent")
            if intent == "system":
                continue
            fresh_task = any(last_prompt_t.get(sess, since) < s["_t"] <= e["_t"] for s in task_starts)
            last_prompt_t[sess] = e["_t"]
            if sess not in first_seen or fresh_task:
                first_seen.add(sess)
                continue
            reasons[intent or "request"] += 1
            samples.append({"ts": e["ts"], "reason": intent, "task": e.get("task")})
        elif ev == "PermissionRequest":
            reasons["permission"] += 1
        elif ev == "PostToolUse" and e.get("tool") == "AskUserQuestion":
            reasons["answer"] += 1
    reasons["interrupt"] += len(interrupts)
    for e in by_ev["intervention"]:
        reasons[e.get("reason") or "other"] += 1
    manual = list(by_ev["manual-edit"])
    for e in manual:
        reasons["manual-edit"] += 1
    gstats, top = git_stats(cwd, since)
    manual_tasks = set(e.get("task") for e in manual if e.get("task"))
    for t in gstats["human_commit_ts"]:
        tid = task_at(t) if t else None
        if tid:
            manual_tasks.add(tid)
            reasons["manual-edit"] += 1
    interventions = {"total": sum(v for v in reasons.values()), "by_reason": {k: v for k, v in reasons.items() if v},
                     "series": samples}

    # ── MAST
    mast_ev = by_ev["mast"]
    rule_ev = by_ev["rule"]
    by_code = {}
    for e in mast_ev:
        c = by_code.setdefault(e["code"], {"count": 0, "closed": 0})
        c["count"] += 1
        if any(r.get("closes") == e["code"] and r["_t"] >= e["_t"] for r in rule_ev):
            c["closed"] += 1
    by_fc = collections.Counter()
    for code, c in by_code.items():
        by_fc[MAST[code][0]] += c["count"]
    cand = collections.Counter()
    streak_key, streak = None, 0
    for e in hook:
        if e.get("ev") != "PostToolUse":
            continue
        key = (e.get("session"), e.get("agent_id"), e.get("tool"),
               hashlib.sha1(json.dumps(e.get("input"), sort_keys=True, ensure_ascii=False).encode()).hexdigest())
        streak = streak + 1 if key == streak_key else 1
        streak_key = key
        if streak == 3:
            cand["FM-1.3"] += 1
    cand["FM-1.1"] += reasons.get("correction", 0)
    for it in tasks.values():
        if it["status"] == "done" and it["id"] not in by_task_runs:
            cand["FM-3.2"] += 1
    mast = {"by_code": by_code, "by_category": dict(by_fc), "total": sum(c["count"] for c in by_code.values()),
            "closed": sum(c["closed"] for c in by_code.values()),
            "candidates": {k: v for k, v in cand.items() if v},
            "labels": {k: {"fc": v[0], "name": v[1]} for k, v in MAST.items()}, "categories": MAST_FC}

    # ── задачи: прогноз vs факт, статусы, автономия
    items = collections.OrderedDict()
    for tid, it in tasks.items():
        end = it["done"] or now()
        actual = round((end - it["started"]).total_seconds() / 60.0, 1) if it["started"] else None
        items[tid] = {"title": it["title"], "status": it["status"], "estimate_min": it["estimate_min"],
                      "human_estimate_min": it["human_estimate_min"], "actual_min": actual,
                      "active_min": round(per_task_active.get(tid, 0) / 60000.0, 1),
                      "tokens": per_task_tok[tid]["total"] if tid in per_task_tok else 0,
                      "usd": round(per_task_tok[tid]["usd"], 4) if tid in per_task_tok else 0.0,
                      "review_rounds": len(rounds.get(tid, [])), "manual_edit": tid in manual_tasks,
                      "started": iso(it["started"]) if it["started"] else None,
                      "done": iso(it["done"]) if it["done"] else None}
    done = [tid for tid, it in tasks.items() if it["status"] == "done"]
    ai_only = [tid for tid in done if tid not in manual_tasks]
    autonomy = {"tasks_done": len(done), "ai_only": len(ai_only),
                "pct": round(100.0 * len(ai_only) / len(done), 1) if done else None,
                "commit_pct": round(100.0 * gstats["ai_commits"] / gstats["commits"], 1) if gstats["commits"] else None}

    # ── коммиты, PR, эвалы, плейбук
    prs = sum(1 for e in hook if (e.get("d") or {}).get("pr"))
    if top:
        try:
            for ln in (Path(top) / "docs/ops-journal.md").read_text(encoding="utf-8").splitlines():
                m = re.match(r"^\|\s*(\S+)\s*\|\s*publish:pr\s*\|", ln)
                if m and parse_ts(m.group(1)) and parse_ts(m.group(1)) >= since:
                    prs += 1
        except OSError:
            pass
    gstats.pop("human_commit_ts", None)
    gstats["prs"] = prs
    evals = collections.OrderedDict()
    for e in by_ev["eval"] + [dict((x.get("d") or {}).get("eval"), ts=x["ts"]) for x in hook
                              if (x.get("d") or {}).get("eval")]:
        s = evals.setdefault(e["name"], [])
        s.append({"ts": e["ts"], "score": e["score"], "iteration": e.get("iteration") or len(s) + 1})
    for s in evals.values():
        s.sort(key=lambda x: x["ts"])

    return {
        "schema": "harness-telemetry/1", "generated_at": iso(now()), "since": iso(since),
        "events": len(events), "tokens": tok, "cost": cost, "active_time": active,
        "tools": {"calls": dict(tool_counts), "failures": dict(tool_fail)},
        "loc": {"ai_tools": loc, "git": {k: gstats[k] for k in ("ai_added", "ai_removed", "human_added", "human_removed")}},
        "edits": edits, "git": gstats, "tests": tests, "review": review, "bugs": bugs,
        "interventions": interventions, "mast": mast,
        "tasks": {"items": items, "by_status": dict(collections.Counter(it["status"] for it in tasks.values())),
                  "status_series": status_series},
        "autonomy": autonomy, "evals": {"series": evals},
        "playbook": playbook_stats(top, rule_ev),
        "routine": routine_candidates(hook),
    }


# ───────────────────────────── вывод ─────────────────────────────

def fmt_tok(n):
    n = float(n or 0)
    for unit, div in (("M", 1e6), ("K", 1e3)):
        if n >= div:
            return "%.1f%s" % (n / div, unit)
    return "%d" % n


def fmt_pct(v):
    return "—" if v is None else "%.0f%%" % v


def render_text(r):
    L = []
    t = r["tokens"]
    L.append("Телеметрия с %s · событий: %d · сессий: %d" % (r["since"][:16].replace("T", " "), r["events"],
                                                               r["active_time"]["sessions"]))
    L.append("")
    L.append("Время: активно %.0f мин (ходов: %d) · по часам %.0f мин" % (
        r["active_time"]["minutes"], r["active_time"]["turns"], r["active_time"]["wall_minutes"]))
    L.append("Стоимость: $%.2f (API-эквивалент) · токены: %s (вход %s · выход %s · кэш-чтение %s)" % (
        r["cost"]["total_usd"], fmt_tok(t["total"]["total"]), fmt_tok(t["total"]["input"]),
        fmt_tok(t["total"]["output"]), fmt_tok(t["total"]["cache_read"])))
    for k, v in sorted(t["by_model"].items(), key=lambda kv: -kv[1]["usd"]):
        L.append("  модель %-22s %8s ток · $%.2f" % (k, fmt_tok(v["total"]), v["usd"]))
    for k, v in sorted(t["by_role"].items(), key=lambda kv: -kv[1]["usd"]):
        L.append("  роль   %-22s %8s ток · $%.2f" % (k, fmt_tok(v["total"]), v["usd"]))
    if t["unpriced_models"]:
        L.append("  нет цены для: %s" % ", ".join(t["unpriced_models"]))
    tk = r["tasks"]
    L.append("")
    L.append("Задачи: %s · автономно (без ручной правки): %s из %s (%s)" % (
        ", ".join("%s=%d" % kv for kv in tk["by_status"].items()) or "нет",
        r["autonomy"]["ai_only"], r["autonomy"]["tasks_done"], fmt_pct(r["autonomy"]["pct"])))
    for tid, it in tk["items"].items():
        L.append("  %-10s %-7s прогноз %s%s · факт %s мин · активно %s мин · $%.2f%s" % (
            tid, it["status"], "%g мин" % it["estimate_min"] if it["estimate_min"] is not None else "—",
            " · человек %g мин" % it["human_estimate_min"] if it.get("human_estimate_min") is not None else "",
            it["actual_min"] if it["actual_min"] is not None else "—", it["active_min"], it["usd"],
            " · ручная правка" if it["manual_edit"] else ""))
    rv = r["review"]
    L.append("Ревью: кругов %d · среднее на задачу %s · с первого раза %s" % (
        rv["rounds_total"], rv["avg_rounds"] if rv["avg_rounds"] is not None else "—", fmt_pct(rv["first_pass_pct"])))
    b = r["bugs"]
    L.append("Баги до мержа: ревьюер %d · тесты %d · человек %d" % (b["by_review"], b["by_tests"], b["by_human"]))
    ts = r["tests"]
    L.append("Тесты: прогонов %d · красных %d · зелёных %d · задач с RED до кода %d · зелёных в итоге %d" % (
        ts["runs"], ts["red"], ts["green"], ts["tasks_red_before_code"], ts["tasks_green_final"]))
    iv = r["interventions"]
    L.append("Вмешательства человека: %d (%s)" % (
        iv["total"], ", ".join("%s=%d" % kv for kv in sorted(iv["by_reason"].items(), key=lambda kv: -kv[1])) or "нет"))
    m = r["mast"]
    L.append("MAST: ошибок %d · закрыто правилом %d · кандидаты: %s" % (
        m["total"], m["closed"], ", ".join("%s=%d" % kv for kv in m["candidates"].items()) or "нет"))
    g = r["git"]
    L.append("Git: коммитов %d (AI %d) · PR %d · строки AI +%d/−%d · человек +%d/−%d" % (
        g["commits"], g["ai_commits"], g["prs"], g["ai_added"], g["ai_removed"], g["human_added"], g["human_removed"]))
    lc = r["loc"]["ai_tools"]
    e = r["edits"]
    L.append("Правки AI (инструменты): +%d/−%d в %d файлах · принято %d · отклонено %d · поправлено человеком %d" % (
        lc["added"], lc["removed"], lc["files"], e["accepted"], e["rejected"], e["user_modified"]))
    if r.get("routine"):
        L.append("Кандидаты в скрипты (команда ≥3 раз): " + " · ".join(
            "%s ×%d" % (x["cmd"][:60], x["count"]) for x in r["routine"][:5]))
    pb = r["playbook"]
    L.append("Плейбук: правил сейчас %d · залогировано новых %d" % (pb["rules_now"], pb["logged_rules"]))
    for name, s in r["evals"]["series"].items():
        L.append("Эвал %s: %s" % (name, " → ".join("%.2f" % x["score"] for x in s)))
    return "\n".join(L)


def load_events(cwd=None):
    return read_jsonl(telemetry_dir(cwd) / "events.jsonl")


def cmd_report(args):
    since_arg, mode, out = None, "text", None
    i = 0
    while i < len(args):
        a = args[i]
        if a == "--since":
            since_arg = args[i + 1] if i + 1 < len(args) else None
            i += 2
        elif a == "--json":
            mode, i = "json", i + 1
        elif a == "--html":
            mode, out = "html", (args[i + 1] if i + 1 < len(args) else None)
            i += 2
        else:
            print("usage: telemetry report [--since ISO] [--json | --html FILE]", file=sys.stderr)
            return 2
    cwd = os.getcwd()
    events = load_events(cwd)
    r = build_report(events, resolve_since(events, since_arg), cwd)
    if mode == "json":
        json.dump(r, sys.stdout, ensure_ascii=False, indent=1, default=str)
        print()
    elif mode == "html":
        sys.path.insert(0, str(Path(__file__).resolve().parent / "lib"))
        import telemetry_html  # noqa: E402
        if not out:
            print("telemetry: --html требует путь", file=sys.stderr)
            return 2
        Path(out).parent.mkdir(parents=True, exist_ok=True)
        tmp = out + ".tmp"
        Path(tmp).write_text(telemetry_html.render(r), encoding="utf-8")
        os.replace(tmp, out)
        print("telemetry: дашборд → %s" % out)
    else:
        print(render_text(r))
    return 0


def cmd_status(_args):
    cwd = os.getcwd()
    tdir = telemetry_dir(cwd)
    events = load_events(cwd)
    since = resolve_since(events, None)
    tid = current_task(tdir, cwd)
    parts = []
    if tid:
        start = est = title = None
        for e in events:
            if e.get("ev") == "task" and e.get("id") == tid:
                if e.get("status") == "doing" and start is None:
                    start = parse_ts(e["ts"])
                est = e.get("estimate_min", est)
                title = e.get("title", title)
        el = (now() - start).total_seconds() / 60.0 if start else 0
        s = "▶ %s%s · %.0f мин" % (tid, " «%s»" % title if title else "", el)
        if est:
            s += " / прогноз %g мин%s" % (est, " ⚠ перерасход" if el > est else "")
        parts.append(s)
    else:
        parts.append("нет активной задачи (telemetry task start <id> --estimate MIN)")
    paths = list(dict.fromkeys(e["transcript"] for e in events if e.get("transcript")))
    msgs, turns, _ = load_transcripts(paths, since)
    table = price_table()
    usd = sum(usage_cost(m["model"], m["usage"], table) or 0 for m in msgs)
    total = sum(sum(int(m["usage"].get(k) or 0) for k in ("input_tokens", "output_tokens", "cache_read_input_tokens",
                                                            "cache_creation_input_tokens")) for m in msgs)
    parts.append("окно %.0f мин активно · %s ток · $%.2f" % (sum(t["ms"] for t in turns) / 60000.0, fmt_tok(total), usd))
    last = [e for e in events if (e.get("d") or {}).get("test")]
    if last:
        parts.append("тесты: %s" % ("зелёные" if last[-1]["d"]["test"]["status"] == "pass" else "КРАСНЫЕ"))
    print(" · ".join(parts))
    return 0


def main(argv):
    cmds = {"hook": cmd_hook, "prompt-hook": cmd_prompt_hook, "task": cmd_task, "log": cmd_log, "report": cmd_report, "status": cmd_status}
    if not argv or argv[0] not in cmds:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    return cmds[argv[0]](argv[1:])


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
