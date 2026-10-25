"""reports.py — валидация по agent-report.schema.json и атомарное сохранение отчётов (T060 / US5 / FR-020).

Только stdlib: работает герметично в любом образе Hermes.
"""
from __future__ import annotations

import json
import logging
import os
from pathlib import Path
from typing import Any

try:
    from . import guard
except (ImportError, ValueError):
    try:
        import guard
    except ImportError:
        import importlib.util
        _guard_path = Path(__file__).resolve().parent / "guard.py"
        _spec = importlib.util.spec_from_file_location("guard", _guard_path)
        guard = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(guard)

log = logging.getLogger(__name__)

# Каталог данных по умолчанию — монтируемый общий том
DATA_DIR = Path(os.getenv("JUDGE_DATA_DIR", "/opt/data/workspaces"))

VALID_ROLES = {"code", "business", "design", "critic-uniqueness", "critic-honesty"}
VALID_FLAG_TYPES = {
    "plagiarism",
    "pre_start_project",
    "claim_mismatch",
    "prompt_injection",
    "incomplete_materials",
    "agent_failure",
    "secret_exposed",
}
VALID_EVIDENCE_KINDS = {
    "file",
    "slide",
    "video",
    "screenshot",
    "url",
    "claim",
    "commit",
    "search",
}
VALID_CLAIM_VERDICTS = {"confirmed", "not_found", "contradicted"}
VALID_MATERIAL_TYPES = {
    "repository",
    "host",
    "presentation",
    "screencast",
    "archive",
    "code_file",
    "document",
    "image",
    "metrics_row",
    "other",
}


def write_atomic(target_path: Path, data: dict[str, Any]) -> None:
    """Атомарно записывает JSON-документ на диск через временный файл в том же каталоге."""
    target_path = Path(target_path)
    target_path.parent.mkdir(parents=True, exist_ok=True)

    tmp_file = target_path.with_suffix(f".tmp.{os.getpid()}")
    try:
        content = json.dumps(data, ensure_ascii=False, indent=2)
        tmp_file.write_text(content, encoding="utf-8")
        tmp_file.replace(target_path)
    finally:
        if tmp_file.exists():
            try:
                tmp_file.unlink()
            except OSError:
                pass


def _is_num(v: Any) -> bool:
    return isinstance(v, (int, float)) and not isinstance(v, bool) and v == v and v not in (float("inf"), float("-inf"))


def _only(obj: dict, allowed: set[str], ctx: str) -> None:
    extra = set(obj) - allowed
    if extra:
        raise ValueError(f"{ctx}: unknown fields {sorted(extra)}")


def _text(obj: dict, key: str, ctx: str, max_len: int, required: bool = True) -> None:
    v = obj.get(key)
    if v is None and not required:
        return
    if not isinstance(v, str) or not v.strip():
        raise ValueError(f"{ctx}: '{key}' is required and must be a non-empty string")
    if len(v) > max_len:
        raise ValueError(f"{ctx}: '{key}' is longer than {max_len} characters")


def validate_evidence(ev: Any, context: str = "") -> None:
    """Валидирует объект evidence по схеме (kind, ref, quote <= 500, без лишних полей)."""
    if not isinstance(ev, dict):
        raise ValueError(f"{context}: evidence item must be an object")
    _only(ev, {"kind", "ref", "quote"}, context)
    kind = ev.get("kind")
    if kind not in VALID_EVIDENCE_KINDS:
        raise ValueError(f"{context}: invalid evidence kind '{kind}', allowed: {sorted(VALID_EVIDENCE_KINDS)}")
    _text(ev, "ref", context, 10_000)
    if "quote" in ev and (not isinstance(ev["quote"], str) or len(ev["quote"]) > 500):
        raise ValueError(f"{context}: quote must be a string up to 500 characters")


def validate_score_item(item: Any, index: int) -> None:
    """Валидирует один критерий оценки по agent-report.schema.json (score)."""
    ctx = f"scores[{index}]"
    if not isinstance(item, dict):
        raise ValueError(f"{ctx}: must be an object")
    _only(item, {"criterion_id", "status", "score", "max_score", "justification", "evidence", "confidence",
                 "no_data_reason"}, ctx)

    cid = item.get("criterion_id")
    if not cid or not isinstance(cid, str) or not cid.strip():
        raise ValueError(f"{ctx}: criterion_id is required")

    status = item.get("status")
    if status not in ("scored", "no_data"):
        raise ValueError(f"{ctx}: status must be 'scored' or 'no_data', got '{status}'")

    _text(item, "justification", ctx, 3000)

    conf = item.get("confidence")
    if not _is_num(conf) or not (0.0 <= float(conf) <= 1.0):
        raise ValueError(f"{ctx}: confidence must be a number between 0 and 1")

    if "max_score" in item and (not _is_num(item["max_score"]) or item["max_score"] <= 0):
        raise ValueError(f"{ctx}: max_score must be a number > 0")
    if "evidence" in item:
        if not isinstance(item["evidence"], list):
            raise ValueError(f"{ctx}: evidence must be a list")
        for ev_idx, ev in enumerate(item["evidence"]):
            validate_evidence(ev, context=f"{ctx}.evidence[{ev_idx}]")

    if status == "scored":
        score = item.get("score")
        if not _is_num(score) or score < 0:
            raise ValueError(f"{ctx}: score is required and must be a number >= 0 for status='scored'")
        if not item.get("evidence"):
            raise ValueError(f"{ctx} ('{cid}'): status='scored' requires at least one evidence item")
    else:
        if "score" in item and not _is_num(item["score"]):
            raise ValueError(f"{ctx}: score must be a number")
        reason = item.get("no_data_reason")
        if not reason or not isinstance(reason, str) or not reason.strip():
            raise ValueError(f"{ctx} ('{cid}'): status='no_data' requires a non-empty no_data_reason")


def validate_flag_item(flag: Any) -> None:
    """Валидирует флаг нечестности или сбоя (flag в agent-report.schema.json)."""
    if not isinstance(flag, dict):
        raise ValueError("flag must be an object")
    _only(flag, {"type", "criterion_id", "confidence", "note", "evidence", "related_submission_id", "related_url"}, "flag")
    ftype = flag.get("type")
    if ftype not in VALID_FLAG_TYPES:
        raise ValueError(f"flag type '{ftype}' is invalid, allowed: {sorted(VALID_FLAG_TYPES)}")

    conf = flag.get("confidence")
    if not _is_num(conf) or not (0.0 <= float(conf) <= 1.0):
        raise ValueError("flag confidence must be a number between 0 and 1")

    _text(flag, "note", "flag", 1500)
    for key in ("criterion_id", "related_submission_id", "related_url"):
        if key in flag and not isinstance(flag[key], str):
            raise ValueError(f"flag: '{key}' must be a string")

    evidence = flag.get("evidence")
    if not evidence or not isinstance(evidence, list):
        raise ValueError(f"flag '{ftype}' requires at least one evidence item")
    for ev_idx, ev in enumerate(evidence):
        validate_evidence(ev, context=f"flag.evidence[{ev_idx}]")


def validate_claim_item(c: Any, idx: int) -> None:
    """Валидирует утверждение (claim в agent-report.schema.json)."""
    ctx = f"claims[{idx}]"
    if not isinstance(c, dict):
        raise ValueError(f"{ctx}: must be an object")
    _only(c, {"claim_id", "text", "source_ref", "verdict", "evidence"}, ctx)
    _text(c, "claim_id", ctx, 10_000)
    _text(c, "text", ctx, 500)
    if "source_ref" not in c:
        raise ValueError(f"{ctx}: source_ref is required")
    validate_evidence(c["source_ref"], context=f"{ctx}.source_ref")
    if c.get("verdict") not in VALID_CLAIM_VERDICTS:
        raise ValueError(f"{ctx}: verdict must be one of {sorted(VALID_CLAIM_VERDICTS)}")
    evidence = c.get("evidence")
    if not isinstance(evidence, list):
        raise ValueError(f"{ctx}: evidence must be a list")
    for ev_idx, ev in enumerate(evidence):
        validate_evidence(ev, context=f"{ctx}.evidence[{ev_idx}]")


def validate_experts(experts: Any, role: str) -> None:
    """experts — только роль business: [{name, domain, scores?}] (agent-report.schema.json)."""
    if role != "business":
        raise ValueError("experts is allowed only for role 'business'")
    if not isinstance(experts, list):
        raise ValueError("experts must be a list")
    for i, ex in enumerate(experts):
        if not isinstance(ex, dict):
            raise ValueError(f"experts[{i}]: must be an object")
        for req in ("name", "domain"):
            if not isinstance(ex.get(req), str) or not ex[req].strip():
                raise ValueError(f"experts[{i}]: '{req}' is required")
        _only(ex, {"name", "domain", "scores"}, f"experts[{i}]")
        sc = ex.get("scores", [])
        if not isinstance(sc, list):
            raise ValueError(f"experts[{i}]: scores must be a list")
        for j, item in enumerate(sc):
            validate_score_item(item, j)


def get_role_report_path(run_id: str, role: str, scope: str = "project") -> Path:
    """Путь отчёта роли: runs/<run_id>/reports/<role>__<scope>.json (scope = submission_id | project)."""
    for label, val in (("run_id", run_id), ("role", role), ("scope", scope)):
        if not isinstance(val, str) or not guard._SAFE_ID.match(val) or ".." in val:
            raise ValueError(f"invalid {label}: {val!r}")
    return DATA_DIR / "runs" / run_id / "reports" / f"{role}__{scope}.json"


def session_ctx(params: dict[str, Any], session_id: str | None, roles: set[str] | None = None) -> tuple[str, str, str]:
    """(run_id, role, scope) только из session_id; расхождение с аргументами модели — отказ.

    Для инструментов оценок scope обязан быть submission_id (не "project").
    """
    ctx = guard.parse_session_id(session_id)
    if not ctx:
        raise ValueError("valid session_id '<run_id>:<role>:<scope>' is required")
    for key, actual in (("run_id", ctx["run_id"]), ("role", ctx["role"])):
        if params.get(key) not in (None, "", actual):
            raise ValueError(f"{key} in arguments does not match the session")
    if params.get("submission_id") not in (None, "", ctx["scope"]):
        raise ValueError("submission_id in arguments does not match the session scope")
    allowed = roles if roles is not None else VALID_ROLES
    if ctx["role"] not in allowed:
        raise ValueError(f"role '{ctx['role']}' cannot submit this report (one of {sorted(allowed)})")
    if ctx["scope"] == guard.PROJECT_SCOPE:
        raise ValueError("session scope must be a submission_id, not 'project'")
    return ctx["run_id"], ctx["role"], ctx["scope"]


def _check_project_id(project_id: Any) -> str:
    if not isinstance(project_id, str) or not guard._SAFE_ID.match(project_id) or ".." in project_id:
        raise ValueError(f"invalid project_id: {project_id!r}")
    return project_id


def load_or_init_scores_doc(run_id: str, role: str, submission_id: str = "", rubric_version: int = 1, scope: str = "project") -> dict[str, Any]:
    """Загружает существующий отчёт роли или инициализирует пустой документ по схеме."""
    path = get_role_report_path(run_id, role, scope)
    if path.exists():
        try:
            data = json.loads(path.read_text(encoding="utf-8"))
            if data.get("kind") == "scores":
                return data
        except Exception as e:
            log.warning("Could not read existing report at %s: %s", path, e)

    return {
        "schema_version": "1",
        "kind": "scores",
        "run_id": run_id,
        "submission_id": submission_id or "default",
        "role": role,
        "rubric_version": rubric_version,
        "scores": [],
        "flags": [],
    }


def save_scores(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_scores: валидирует оценки, обновляет критерии (последний побеждает) и сохраняет."""
    run_id, role, scope = session_ctx(params, session_id)
    submission_id = scope
    rubric_version = int(params.get("rubric_version") or 1)

    raw_scores = params.get("scores")
    if not isinstance(raw_scores, list) or len(raw_scores) == 0:
        raise ValueError("scores must be a non-empty list of criteria scores")

    for idx, item in enumerate(raw_scores):
        validate_score_item(item, idx)

    experts = params.get("experts")
    if experts is not None:
        validate_experts(experts, role)

    # Загружаем текущий отчёт роли для объединения оценок
    doc = load_or_init_scores_doc(run_id, role, submission_id=submission_id, rubric_version=rubric_version, scope=scope)
    if submission_id:
        doc["submission_id"] = submission_id
    doc["rubric_version"] = rubric_version

    # Правило: последняя оценка критерия побеждает (Last score wins)
    existing_scores = {s["criterion_id"]: s for s in doc.get("scores", [])}
    for item in raw_scores:
        existing_scores[item["criterion_id"]] = item
    doc["scores"] = list(existing_scores.values())

    if experts is not None:
        doc["experts"] = experts

    if "summary" in params:
        if not isinstance(params["summary"], str) or len(params["summary"]) > 3000:
            raise ValueError("summary must be a string up to 3000 characters")
        doc["summary"] = params["summary"]

    report_path = get_role_report_path(run_id, role, scope)
    write_atomic(report_path, doc)

    return {"success": True, "saved_criteria": len(doc["scores"]), "report_path": str(report_path)}


def save_flag(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_flag: валидирует флаг и добавляет в список flags отчёта роли."""
    run_id, role, scope = session_ctx(params, session_id)

    flag_data = params.get("flag")
    if not isinstance(flag_data, dict):
        raise ValueError("flag must be an object")

    validate_flag_item(flag_data)

    doc = load_or_init_scores_doc(run_id, role, submission_id=scope, scope=scope)
    flags = doc.setdefault("flags", [])
    flags.append(flag_data)

    report_path = get_role_report_path(run_id, role, scope)
    write_atomic(report_path, doc)

    return {"success": True, "total_flags": len(flags), "report_path": str(report_path)}


def save_claims(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_claims (роль critic-honesty)."""
    run_id, role, scope = session_ctx(params, session_id, roles={"critic-honesty"})

    claims = params.get("claims")
    if not isinstance(claims, list):
        raise ValueError("claims must be a list")

    for idx, c in enumerate(claims):
        validate_claim_item(c, idx)

    doc = load_or_init_scores_doc(run_id, role, submission_id=scope, scope=scope)
    doc["claims"] = claims

    report_path = get_role_report_path(run_id, role, scope)
    write_atomic(report_path, doc)

    return {"success": True, "claims_count": len(claims), "report_path": str(report_path)}


def save_rubric(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_rubric (роль rubric)."""
    del session_id
    project_id = _check_project_id(params.get("project_id"))

    criteria = params.get("criteria")
    if not isinstance(criteria, list) or len(criteria) == 0:
        raise ValueError("criteria must be a non-empty list")

    for idx, c in enumerate(criteria):
        if not isinstance(c, dict):
            raise ValueError(f"criteria[{idx}]: must be an object")
        for req in ("name", "description", "weight", "max_score", "agent", "source_ref"):
            if req not in c:
                raise ValueError(f"criteria[{idx}]: '{req}' is required")

    doc = {
        "schema_version": "1",
        "kind": "rubric_draft",
        "project_id": str(project_id),
        "criteria": criteria,
        "weights_were_missing": bool(params.get("weights_were_missing", False)),
    }

    out_path = DATA_DIR / "projects" / str(project_id) / "rubric-draft.json"
    write_atomic(out_path, doc)

    return {"success": True, "criteria_count": len(criteria), "out_path": str(out_path)}


def save_ux_metrics(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """report_ux_metrics (роль design): один набор на проект, только из сессии scope=project; без перезаписи (FR-017)."""
    ctx = guard.parse_session_id(session_id)
    if not ctx or ctx["role"] != "design" or ctx["scope"] != guard.PROJECT_SCOPE:
        raise ValueError("report_ux_metrics is allowed only for role 'design' with session scope 'project'")
    project_id = _check_project_id(params.get("project_id"))

    metrics = params.get("metrics")
    if not isinstance(metrics, list) or len(metrics) == 0:
        raise ValueError("metrics must be a non-empty list")

    for idx, m in enumerate(metrics):
        if not isinstance(m, dict):
            raise ValueError(f"metrics[{idx}]: must be an object")
        _only(m, {"name", "how_to_measure", "good_looks_like"}, f"metrics[{idx}]")
        for req in ("name", "how_to_measure", "good_looks_like"):
            if not isinstance(m.get(req), str):
                raise ValueError(f"metrics[{idx}]: '{req}' is required")

    doc = {
        "schema_version": "1",
        "kind": "ux_metrics",
        "project_id": project_id,
        "metrics": metrics,
    }

    out_path = DATA_DIR / "projects" / project_id / "ux-metrics.json"
    out_path.parent.mkdir(parents=True, exist_ok=True)
    try:
        fd = os.open(out_path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o644)
    except FileExistsError:
        raise ValueError("ux metrics for this project already exist: read projects/<project_id>/ux-metrics.json "
                         "and apply the same set; it is fixed once per project") from None
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(doc, f, ensure_ascii=False, indent=2)

    return {"success": True, "metrics_count": len(metrics), "out_path": str(out_path)}


def save_inventory_patch(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_inventory_patch (роль sorter)."""
    run_id, role, submission_id = session_ctx(params, session_id, roles={"sorter"})
    updates = params.get("updates")
    if not isinstance(updates, list):
        raise ValueError("updates must be a list")

    for idx, u in enumerate(updates):
        if not isinstance(u, dict):
            raise ValueError(f"updates[{idx}]: must be an object")
        if not u.get("material_id") or not u.get("type"):
            raise ValueError(f"updates[{idx}]: material_id and type are required")
        if u["type"] not in VALID_MATERIAL_TYPES:
            raise ValueError(f"updates[{idx}]: invalid material type '{u['type']}'")

    doc = {
        "schema_version": "1",
        "kind": "inventory_patch",
        "run_id": run_id,
        "submission_id": submission_id,
        "updates": updates,
    }

    out_path = DATA_DIR / "runs" / run_id / "reports" / "inventory_patch.json"
    write_atomic(out_path, doc)

    return {"success": True, "updates_count": len(updates), "out_path": str(out_path)}
