"""Приём отчётов агентов: чтение ``runs/<run_id>/reports/<role>.json``, повторная проверка и запись результата.

Контракт — ``specs/001-ai-judge-platform/contracts/agent-run.md`` §3 и ``agent-report.schema.json``. Плагину роли не
доверяем: документ перепроверяется схемой и правилами backend, а любой изъян превращается в понятный итог, а не в
исключение или тихую потерю критерия.

Итог приёма для задачи ``run_task``:
- принятая оценка пишется в ``criterion_score``; отклонённая (критерий не из рубрики этой версии, роль не вправе его
  оценивать, балл вне ``[0, max_score]``, ``scored`` без доказательств) не пишется, а критерий роли без принятой
  оценки получает ``no_data`` с причиной ``rejected: <код>`` (оценку отклонили) или ``agent_failure`` (оценки нет);
- нет файла, битый JSON, документ не по схеме или с чужими идентификаторами — ВСЕ критерии роли получают ``no_data``
  (``agent_failure``) и пишется один флаг ``agent_failure``; в пояснении нет путей машины;
- повторный вызов для той же задачи ничего не дублирует.

Коммит делает вызывающий код: ``ingest_report`` пишет в переданную сессию.
"""
from __future__ import annotations

import errno
import json
import logging
import os
import re
import stat
import unicodedata
from functools import lru_cache
from pathlib import Path
from typing import Any, Mapping
from urllib.parse import urlsplit

import jsonschema
from sqlalchemy import text
from sqlalchemy.orm import Session

from ..common import new_id, utc_now_iso

log = logging.getLogger(__name__)

SCHEMA_PATH = (Path(__file__).resolve().parents[3] / "specs" / "001-ai-judge-platform" / "contracts"
               / "agent-report.schema.json")
MAX_REPORT_BYTES = 2 * 1024 * 1024
MAX_TEXT = 3000
MAX_URL = 2000
SAFE_NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
_INVISIBLE = frozenset([0x200E, 0x200F, 0xFEFF, *range(0x202A, 0x202F), *range(0x2066, 0x206A)])
_LINE_BREAKS = frozenset([" ", " "])


# ─────────────────────────────── общие помощники (используются и рубрикой) ───────────────────────────────

def clean_text(value: Any, limit: int = MAX_TEXT) -> str:
    """Убирает управляющие символы (``\\n`` и ``\\t`` остаются), невидимые символы направления текста и
    одиночные суррогаты, нормализует переводы строк и обрезает до ``limit`` символов."""
    source = value if isinstance(value, str) else str(value)
    source = source.replace("\r\n", "\n").replace("\r", "\n")
    kept = []
    for char in source:
        if char in "\n\t":
            kept.append(char)
        elif char in _LINE_BREAKS:
            kept.append("\n")
        elif unicodedata.category(char) in ("Cc", "Cs") or ord(char) in _INVISIBLE:
            continue
        else:
            kept.append(char)
    return "".join(kept)[:limit]


def clean_json(value: Any) -> Any:
    """Рекурсивно очищает строки внутри JSON-значения (ключи словарей тоже)."""
    if isinstance(value, str):
        return clean_text(value)
    if isinstance(value, list):
        return [clean_json(item) for item in value]
    if isinstance(value, dict):
        return {clean_text(key, 200): clean_json(item) for key, item in value.items()}
    return value


@lru_cache(maxsize=1)
def _schema() -> dict[str, Any]:
    return json.loads(SCHEMA_PATH.read_text(encoding="utf-8"))


@lru_cache(maxsize=None)
def document_validator(definition: str) -> jsonschema.Draft202012Validator:
    """Валидатор одного из документов схемы (``scores_document``, ``rubric_document`` …) без ``oneOf`` верхнего
    уровня: ошибки указывают на конкретное поле."""
    schema = _schema()
    if definition not in schema["$defs"]:
        raise KeyError(definition)
    return jsonschema.Draft202012Validator({"$ref": f"#/$defs/{definition}", "$defs": schema["$defs"]})


def _reject_constant(name: str) -> Any:
    raise ValueError(f"недопустимая константа JSON: {name}")


_O_DIRECTORY = getattr(os, "O_DIRECTORY", 0)
_O_NOFOLLOW = getattr(os, "O_NOFOLLOW", 0)


def _open_directory_chain(root: Path, parts: tuple[str, ...]) -> int:
    """Файловый дескриптор каталога ``root/parts``; каждый шаг открывается относительно предыдущего дескриптора
    с ``O_NOFOLLOW``, поэтому символическая ссылка на любом уровне (в том числе подменённая между проверкой и
    открытием) даёт ``OSError``, а не выход за пределы ``root``."""
    fd = os.open(root.resolve(), os.O_RDONLY | _O_DIRECTORY)
    try:
        for part in parts:
            next_fd = os.open(part, os.O_RDONLY | _O_DIRECTORY | _O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
    except BaseException:
        os.close(fd)
        raise
    return fd


def read_json_file(root: Path, *parts: str) -> tuple[Any, str | None]:
    """Читает JSON-файл агента строго внутри ``root``: без символических ссылок на любом уровне пути, только
    обычный файл, не больше ``MAX_REPORT_BYTES``, числа ``NaN``/``Infinity`` недопустимы.

    Возвращает ``(значение, None)`` или ``(None, причина)``; причина — короткий код без путей:
    ``missing | unreadable | too_large | invalid_json``."""
    if not parts or not all(SAFE_NAME.match(part) for part in parts):
        return None, "missing"
    try:
        dir_fd = _open_directory_chain(root, tuple(parts[:-1]))
        try:
            file_fd = os.open(parts[-1], os.O_RDONLY | _O_NOFOLLOW | getattr(os, "O_NONBLOCK", 0), dir_fd=dir_fd)
        finally:
            os.close(dir_fd)
        with os.fdopen(file_fd, "rb") as handle:
            if not stat.S_ISREG(os.fstat(handle.fileno()).st_mode):
                return None, "unreadable"
            raw = handle.read(MAX_REPORT_BYTES + 1)
    except OSError as exc:
        return None, "missing" if exc.errno in (errno.ENOENT, errno.ENOTDIR) else "unreadable"
    if len(raw) > MAX_REPORT_BYTES:
        return None, "too_large"
    try:
        return json.loads(raw.decode("utf-8"), parse_constant=_reject_constant), None
    except (ValueError, RecursionError):
        return None, "invalid_json"


def remove_file(root: Path, *parts: str) -> None:
    """Удаляет файл внутри ``root``, не следуя символическим ссылкам; отсутствие или отказ — не ошибка."""
    if not parts or not all(SAFE_NAME.match(part) for part in parts):
        return
    try:
        dir_fd = _open_directory_chain(root, tuple(parts[:-1]))
    except OSError:
        return
    try:
        os.unlink(parts[-1], dir_fd=dir_fd)
    except OSError:
        pass
    finally:
        os.close(dir_fd)


# ─────────────────────────────── приём отчёта ───────────────────────────────

_FAILURE_NOTES = {
    "missing": "Отчёт роли не получен: файл отсутствует.",
    "unreadable": "Отчёт роли не удалось прочитать.",
    "too_large": "Отчёт роли слишком большой.",
    "invalid_json": "Отчёт роли не удалось разобрать: это не корректный JSON.",
    "invalid_document": "Отчёт роли имеет неверную структуру.",
}


def ingest_report(session: Session, *, data_dir: str | Path, project_id: str, run_task: Mapping[str, Any]) -> dict:
    """Принимает отчёт роли по задаче ``run_task`` (``id, run_id, submission_id, role, rubric_version``)."""
    task = _check_task(session, project_id, run_task)
    # Блокировка строки задачи: параллельный приём той же задачи дождётся коммита первого и увидит его записи
    session.execute(text("UPDATE run_task SET state = state WHERE id = :id"), {"id": task["id"]})
    previous = _previous_summary(session, task["id"])
    if previous is not None:
        return previous

    criteria = _rubric_criteria(session, project_id, task["rubric_version"])
    role_criteria = [cid for cid, crit in criteria.items() if crit["agent"] == task["role"]]
    now = utc_now_iso()

    document, failure = _load_document(Path(data_dir), task)
    if failure is not None:
        return _record_failure(session, task, criteria, role_criteria, failure, now)
    document, item_errors = document

    outcomes, unkeyed = _evaluate_scores(document.get("scores"), item_errors, criteria, task["role"])
    summary = {"accepted": 0, "no_data": 0, "flags": 0, "claims": 0, "rejected": []}
    for cid in role_criteria:
        outcome = outcomes.get(cid)
        crit = criteria[cid]
        if outcome is None:
            _insert_no_data(session, task, cid, crit["max_score"], "agent_failure",
                            "Агент не вернул оценку по этому критерию.", now)
            summary["no_data"] += 1
        elif outcome["kind"] == "rejected":
            _insert_no_data(session, task, cid, crit["max_score"], f"rejected: {outcome['reason']}",
                            f"Оценка агента отклонена при проверке: {outcome['reason']}.", now)
            summary["no_data"] += 1
        else:
            _insert_score(session, task, cid, outcome["record"], now)
            if outcome["record"]["status"] == "scored":
                summary["accepted"] += 1
            else:
                summary["no_data"] += 1
    summary["rejected"] = [{"criterion_id": cid, "reason": outcome["reason"]}
                           for cid, outcome in outcomes.items() if outcome["kind"] == "rejected"]
    summary["rejected"] += [{"criterion_id": None, "reason": reason} for reason in unkeyed]

    summary["flags"] = _insert_flags(session, task, project_id, criteria, document.get("flags") or [], now)
    if task["role"] == "critic-honesty":
        summary["claims"] = _insert_claims(session, task, document.get("claims") or [])
    log.info("отчёт роли принят", extra={"run_task_id": task["id"], "role": task["role"],
                                        "accepted": summary["accepted"], "no_data": summary["no_data"],
                                        "rejected": len(summary["rejected"])})
    return summary


def _check_task(session: Session, project_id: str, run_task: Mapping[str, Any]) -> dict[str, Any]:
    """Проверяет форму ``run_task`` и возвращает задачу по строкам БД: ``run_id``, ``submission_id``, ``role`` и
    версия рубрики берутся из ``run_task`` / ``run``, а не из переданного словаря (источник истины — БД)."""
    try:
        passed = {key: run_task[key] for key in ("id", "run_id", "submission_id", "role", "rubric_version")}
    except KeyError as exc:
        raise ValueError(f"в run_task нет поля {exc.args[0]}") from None
    if not isinstance(passed["id"], str) or not passed["id"]:
        raise ValueError("run_task.id должен быть непустой строкой")
    if not isinstance(passed["submission_id"], str) or not passed["submission_id"]:
        raise ValueError("приём оценок возможен только для задачи с submission_id")
    if isinstance(passed["rubric_version"], bool) or not isinstance(passed["rubric_version"], int):
        raise ValueError("run_task.rubric_version должен быть целым")
    row = session.execute(
        text("SELECT t.id, t.run_id, t.submission_id, t.role, r.rubric_version FROM run_task t "
             "JOIN run r ON r.id = t.run_id WHERE t.id = :id AND r.project_id = :project"),
        {"id": passed["id"], "project": project_id}).mappings().first()
    if row is None:
        raise LookupError("задача не найдена в этом проекте")
    task = dict(row)
    if not isinstance(task["submission_id"], str) or not task["submission_id"]:
        raise ValueError("приём оценок возможен только для задачи с submission_id")
    if any(passed[key] != task[key] for key in ("submission_id", "role", "rubric_version")):
        log.warning("run_task не совпадает с записью в БД; используются данные БД", extra={"run_task_id": task["id"]})
    return task


def _previous_summary(session: Session, run_task_id: str) -> dict | None:
    """Итог прежнего приёма по строкам БД; ``None``, если по задаче ничего не записано."""
    params = {"task": run_task_id}
    scores = session.execute(
        text("SELECT criterion_id, status, no_data_reason FROM criterion_score WHERE run_task_id = :task "
             "ORDER BY created_at, id"), params).mappings().all()
    flags = session.execute(text("SELECT count(*) FROM flag WHERE run_task_id = :task"), params).scalar_one()
    claims = session.execute(text("SELECT count(*) FROM claim WHERE run_task_id = :task"), params).scalar_one()
    if not scores and not flags and not claims:
        return None
    prefix = "rejected: "
    return {
        "accepted": sum(1 for row in scores if row["status"] == "scored"),
        "no_data": sum(1 for row in scores if row["status"] == "no_data"),
        "flags": flags,
        "claims": claims,
        "rejected": [{"criterion_id": row["criterion_id"], "reason": row["no_data_reason"][len(prefix):]}
                     for row in scores if str(row["no_data_reason"] or "").startswith(prefix)],
    }


def _rubric_criteria(session: Session, project_id: str, version: int) -> dict[str, dict[str, Any]]:
    rows = session.execute(
        text("SELECT c.id, c.max_score, c.agent FROM criterion c JOIN rubric r ON r.id = c.rubric_id "
             "WHERE r.project_id = :project AND r.version = :version ORDER BY c.position, c.id"),
        {"project": project_id, "version": version}).mappings().all()
    return {row["id"]: {"max_score": row["max_score"], "agent": row["agent"]} for row in rows}


def _load_document(data_dir: Path, task: dict[str, Any]):
    """Возвращает ``((документ, ошибки_отдельных_оценок), None)`` или ``(None, (код, пояснение))``."""
    run_id, role = task["run_id"], task["role"]
    if not (isinstance(run_id, str) and isinstance(role, str) and SAFE_NAME.match(run_id) and SAFE_NAME.match(role)):
        return None, ("missing", _FAILURE_NOTES["missing"])
    raw, problem = read_json_file(data_dir, "runs", run_id, "reports", f"{role}.json")
    if problem is not None:
        return None, (problem, _FAILURE_NOTES[problem])
    if not isinstance(raw, dict):
        return None, ("invalid_document", _FAILURE_NOTES["invalid_document"])

    item_errors: set[int] = set()
    try:
        errors = list(document_validator("scores_document").iter_errors(raw))
    except Exception:  # noqa: BLE001 — любой сбой проверки схемой = документ невалиден
        return None, ("invalid_document", _FAILURE_NOTES["invalid_document"])
    for error in errors:
        path = list(error.absolute_path)
        if len(path) >= 2 and path[0] == "scores" and isinstance(path[1], int):
            item_errors.add(path[1])
            continue
        where = clean_text(".".join(str(part) for part in path) or "документ", 100)
        return None, ("invalid_document", f"Отчёт роли не прошёл проверку по схеме (поле: {where}).")
    for field in ("run_id", "role", "submission_id", "rubric_version"):
        if raw.get(field) != task[field]:
            return None, ("identifier_mismatch", f"Идентификаторы в отчёте не совпадают с задачей (поле: {field}).")
    return (raw, item_errors), None


def _record_failure(session, task, criteria, role_criteria, failure, now) -> dict:
    code, note = failure
    for cid in role_criteria:
        _insert_no_data(session, task, cid, criteria[cid]["max_score"], "agent_failure",
                        "Отчёт агента недоступен или не прошёл проверку.", now)
    session.execute(
        text("INSERT INTO flag (id, run_task_id, submission_id, criterion_id, type, confidence, note, evidence, "
             "related_submission_id, related_url, created_at) VALUES (:id, :task, :sub, NULL, 'agent_failure', :conf, "
             ":note, :evidence, NULL, NULL, :now)"),
        {"id": new_id(), "task": task["id"], "sub": task["submission_id"], "conf": 1.0, "note": clean_text(note),
         "evidence": json.dumps([{"kind": "file", "ref": f"reports/{clean_text(task['role'], 60)}.json"}],
                                ensure_ascii=False), "now": now})
    log.error("отчёт роли отклонён целиком", extra={"run_task_id": task["id"], "role": str(task["role"])[:60],
                                                   "reason": code})
    return {"accepted": 0, "no_data": len(role_criteria), "flags": 1, "claims": 0, "rejected": []}


# ─────────────────────────────── оценки ───────────────────────────────

def _evaluate_scores(items: Any, item_errors: set[int], criteria: dict, role: str) -> tuple[dict, list[str]]:
    """``({criterion_id: {"kind": "ok"|"rejected", ...}}, причины для элементов без пригодного criterion_id)``;
    повтор одного критерия — побеждает последний."""
    outcomes: dict[str, dict] = {}
    unkeyed: list[str] = []
    for index, item in enumerate(items if isinstance(items, list) else []):
        cid = item.get("criterion_id") if isinstance(item, dict) else None
        if not isinstance(cid, str) or not cid:
            unkeyed.append("schema_invalid")
            continue
        outcomes[cid] = _evaluate_item(item, index in item_errors, criteria.get(cid), role)
    return outcomes, unkeyed


def _evaluate_item(item: dict, schema_invalid: bool, crit: dict | None, role: str) -> dict:
    def rejected(reason: str) -> dict:
        return {"kind": "rejected", "reason": reason}

    if crit is None:
        return rejected("criterion_not_in_rubric")
    if crit["agent"] != role:
        return rejected("role_not_allowed")
    status = item.get("status")
    if status == "scored":
        score = item.get("score")
        if isinstance(score, bool) or not isinstance(score, (int, float)):
            return rejected("invalid_score")
        if not 0 <= score <= crit["max_score"]:
            return rejected("score_out_of_range")
        if "max_score" in item and item["max_score"] != crit["max_score"]:
            return rejected("max_score_mismatch")
        evidence = _usable_evidence(item.get("evidence"))
        if not evidence:
            return rejected("no_evidence")
        justification = clean_text(item.get("justification", "")).strip()
        if not justification:
            return rejected("empty_justification")
        if schema_invalid:
            return rejected("schema_invalid")
        return {"kind": "ok", "record": {
            "status": "scored", "score": float(score), "max_score": crit["max_score"], "justification": justification,
            "evidence": evidence, "confidence": _confidence(item.get("confidence")), "no_data_reason": None}}
    if status == "no_data":
        if schema_invalid:
            return rejected("schema_invalid")
        reason = clean_text(item.get("no_data_reason", "")).strip() or "no_data_reported"
        evidence = _usable_evidence(item.get("evidence"))
        return {"kind": "ok", "record": {
            "status": "no_data", "score": None, "max_score": crit["max_score"],
            "justification": clean_text(item.get("justification", "")).strip() or None,
            "evidence": evidence or None, "confidence": _confidence(item.get("confidence")),
            "no_data_reason": reason}}
    return rejected("schema_invalid")


def _usable_evidence(evidence: Any) -> list[dict]:
    """Только элементы с непустой ссылкой; пустой массив и пробельные ссылки доказательством не считаются."""
    if not isinstance(evidence, list):
        return []
    return [clean_json(item) for item in evidence
            if isinstance(item, dict) and isinstance(item.get("ref"), str) and clean_text(item["ref"]).strip()]


def _confidence(value: Any) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not 0 <= value <= 1:
        return None
    return float(value)


def _insert_score(session: Session, task: dict, criterion_id: str, record: dict, now: str) -> None:
    session.execute(
        text("INSERT INTO criterion_score (id, run_task_id, submission_id, criterion_id, rubric_version, status, "
             "score, max_score, justification, evidence, confidence, no_data_reason, version, created_at) "
             "VALUES (:id, :task, :sub, :cid, :rv, :status, :score, :max, :just, :evidence, :conf, :reason, 1, :now)"),
        {"id": new_id(), "task": task["id"], "sub": task["submission_id"], "cid": criterion_id,
         "rv": task["rubric_version"], "status": record["status"], "score": record["score"],
         "max": record["max_score"], "just": record["justification"],
         "evidence": None if record["evidence"] is None else json.dumps(record["evidence"], ensure_ascii=False),
         "conf": record["confidence"], "reason": record["no_data_reason"], "now": now})


def _insert_no_data(session: Session, task: dict, criterion_id: str, max_score: float, reason: str,
                    justification: str, now: str) -> None:
    _insert_score(session, task, criterion_id, {
        "status": "no_data", "score": None, "max_score": max_score, "justification": justification,
        "evidence": None, "confidence": None, "no_data_reason": reason}, now)


# ─────────────────────────────── флаги и утверждения ───────────────────────────────

def _insert_flags(session: Session, task: dict, project_id: str, criteria: dict, flags: list, now: str) -> int:
    written = 0
    for item in flags:
        criterion_id = item.get("criterion_id")
        related = item.get("related_submission_id")
        if related is not None and session.execute(
                text("SELECT 1 FROM submission WHERE id = :id AND project_id = :project"),
                {"id": related, "project": project_id}).first() is None:
            related = None
        session.execute(
            text("INSERT INTO flag (id, run_task_id, submission_id, criterion_id, type, confidence, note, evidence, "
                 "related_submission_id, related_url, created_at) VALUES (:id, :task, :sub, :cid, :type, :conf, "
                 ":note, :evidence, :related, :url, :now)"),
            {"id": new_id(), "task": task["id"], "sub": task["submission_id"],
             "cid": criterion_id if criterion_id in criteria else None, "type": item["type"],
             "conf": _confidence(item.get("confidence")), "note": clean_text(item.get("note", "")).strip() or "—",
             "evidence": json.dumps(clean_json(item.get("evidence") or []), ensure_ascii=False),
             "related": related, "url": _safe_url(item.get("related_url")), "now": now})
        written += 1
    return written


def _safe_url(value: Any) -> str | None:
    if not isinstance(value, str):
        return None
    url = clean_text(value, MAX_URL).strip()
    try:
        parts = urlsplit(url)
    except ValueError:
        return None
    return url if parts.scheme in ("http", "https") and parts.netloc else None


def _insert_claims(session: Session, task: dict, claims: list) -> int:
    latest: dict[str, dict] = {}
    for item in claims:
        latest[clean_text(item["claim_id"], 200)] = item
    for claim_id, item in latest.items():
        session.execute(
            text("INSERT INTO claim (id, run_task_id, claim_id, text, source_ref, verdict, evidence) "
                 "VALUES (:id, :task, :claim, :text, :source, :verdict, :evidence)"),
            {"id": new_id(), "task": task["id"], "claim": claim_id, "text": clean_text(item["text"]),
             "source": json.dumps(clean_json(item["source_ref"]), ensure_ascii=False), "verdict": item["verdict"],
             "evidence": json.dumps(clean_json(item.get("evidence") or []), ensure_ascii=False)})
    return len(latest)
