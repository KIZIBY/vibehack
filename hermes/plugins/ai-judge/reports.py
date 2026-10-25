"""reports.py — валидация по agent-report.schema.json и атомарное сохранение отчётов (T060 / US5 / FR-020).

Только stdlib: работает герметично в любом образе Hermes.
"""
from __future__ import annotations

import json
import logging
import os
import tempfile
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


def validate_evidence(ev: Any, context: str = "") -> None:
    """Валидирует объект evidence по схеме."""
    if not isinstance(ev, dict):
        raise ValueError(f"{context}: evidence item must be an object")
    kind = ev.get("kind")
    if kind not in VALID_EVIDENCE_KINDS:
        raise ValueError(f"{context}: invalid evidence kind '{kind}', allowed: {sorted(VALID_EVIDENCE_KINDS)}")
    ref = ev.get("ref")
    if not ref or not isinstance(ref, str) or not ref.strip():
        raise ValueError(f"{context}: evidence ref is required and must be non-empty string")


def validate_score_item(item: Any, index: int) -> None:
    """Валидирует один критерий оценки."""
    if not isinstance(item, dict):
        raise ValueError(f"scores[{index}]: must be an object")

    cid = item.get("criterion_id")
    if not cid or not isinstance(cid, str) or not cid.strip():
        raise ValueError(f"scores[{index}]: criterion_id is required")

    status = item.get("status")
    if status not in ("scored", "no_data"):
        raise ValueError(f"scores[{index}]: status must be 'scored' or 'no_data', got '{status}'")

    justification = item.get("justification")
    if not justification or not isinstance(justification, str):
        raise ValueError(f"scores[{index}]: justification is required")

    conf = item.get("confidence")
    if conf is None or not isinstance(conf, (int, float)) or not (0.0 <= float(conf) <= 1.0):
        raise ValueError(f"scores[{index}]: confidence must be a number between 0 and 1")

    if status == "scored":
        score = item.get("score")
        if score is None or not isinstance(score, (int, float)) or score < 0:
            raise ValueError(f"scores[{index}]: score is required and must be >= 0 for status='scored'")
        max_score = item.get("max_score", 10.0)
        if not isinstance(max_score, (int, float)) or max_score <= 0:
            raise ValueError(f"scores[{index}]: max_score must be > 0")

        evidence = item.get("evidence")
        if not evidence or not isinstance(evidence, list) or len(evidence) == 0:
            raise ValueError(f"scores[{index}] ('{cid}'): status='scored' requires at least one evidence item")
        for ev_idx, ev in enumerate(evidence):
            validate_evidence(ev, context=f"scores[{index}].evidence[{ev_idx}]")

    elif status == "no_data":
        reason = item.get("no_data_reason")
        if not reason or not isinstance(reason, str) or not reason.strip():
            raise ValueError(f"scores[{index}] ('{cid}'): status='no_data' requires a non-empty no_data_reason")


VALID_FLAG_SEVERITY = {"low", "medium", "high", "critical"}
FLAGS_REQUIRING_SEVERITY = {"claim_mismatch"}
MAX_CLAIMS = 20
VALID_SOURCE_REF_KINDS = {"slide", "video", "document", "screenshot", "url"}


def validate_source_ref(source_ref: Any, context: str = "") -> None:
    """Валидирует source_ref — первоисточник утверждения."""
    if not isinstance(source_ref, dict):
        raise ValueError(f"{context}: source_ref must be an object")
    kind = source_ref.get("kind")
    if not kind or not isinstance(kind, str):
        raise ValueError(f"{context}: source_ref.kind is required")
    ref = source_ref.get("ref")
    if not ref or not isinstance(ref, str) or not ref.strip():
        raise ValueError(f"{context}: source_ref.ref is required and must be non-empty string")


def validate_flag_item(flag: Any) -> None:
    """Валидирует флаг нечестности или сбоя."""
    if not isinstance(flag, dict):
        raise ValueError("flag must be an object")
    ftype = flag.get("type")
    if ftype not in VALID_FLAG_TYPES:
        raise ValueError(f"flag type '{ftype}' is invalid, allowed: {sorted(VALID_FLAG_TYPES)}")

    severity = flag.get("severity")
    if ftype in FLAGS_REQUIRING_SEVERITY:
        if not severity or severity not in VALID_FLAG_SEVERITY:
            raise ValueError(
                f"flag '{ftype}' requires severity (one of {sorted(VALID_FLAG_SEVERITY)})"
            )
    elif severity is not None and severity not in VALID_FLAG_SEVERITY:
        raise ValueError(
            f"flag severity '{severity}' is invalid, allowed: {sorted(VALID_FLAG_SEVERITY)}"
        )

    conf = flag.get("confidence")
    if conf is None or not isinstance(conf, (int, float)) or not (0.0 <= float(conf) <= 1.0):
        raise ValueError("flag confidence must be a number between 0 and 1")

    note = flag.get("note")
    if not note or not isinstance(note, str) or not note.strip():
        raise ValueError("flag note is required")

    evidence = flag.get("evidence")
    if not evidence or not isinstance(evidence, list) or len(evidence) == 0:
        raise ValueError(f"flag '{ftype}' requires at least one evidence item")
    for ev_idx, ev in enumerate(evidence):
        validate_evidence(ev, context=f"flag.evidence[{ev_idx}]")


def get_role_report_path(run_id: str, role: str) -> Path:
    """Возвращает путь к файлу отчёта роли: runs/<run_id>/reports/<role>.json."""
    return DATA_DIR / "runs" / run_id / "reports" / f"{role}.json"


def load_or_init_scores_doc(run_id: str, role: str, submission_id: str = "", rubric_version: int = 1) -> dict[str, Any]:
    """Загружает существующий отчёт роли или инициализирует пустой документ по схеме."""
    path = get_role_report_path(run_id, role)
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
    run_id = params.get("run_id") or guard.extract_run_id(session_id)
    if not run_id:
        raise ValueError("run_id is required")

    role = params.get("role") or guard.extract_role(session_id)
    if not role or role not in VALID_ROLES:
        raise ValueError(f"valid role is required (one of {sorted(VALID_ROLES)})")

    submission_id = params.get("submission_id") or ""
    rubric_version = int(params.get("rubric_version") or 1)

    raw_scores = params.get("scores")
    if not isinstance(raw_scores, list) or len(raw_scores) == 0:
        raise ValueError("scores must be a non-empty list of criteria scores")

    for idx, item in enumerate(raw_scores):
        validate_score_item(item, idx)

    # Загружаем текущий отчёт роли для объединения оценок
    doc = load_or_init_scores_doc(run_id, role, submission_id=submission_id, rubric_version=rubric_version)
    if submission_id:
        doc["submission_id"] = submission_id
    doc["rubric_version"] = rubric_version

    # Правило: последняя оценка критерия побеждает (Last score wins)
    existing_scores = {s["criterion_id"]: s for s in doc.get("scores", [])}
    for item in raw_scores:
        existing_scores[item["criterion_id"]] = item
    doc["scores"] = list(existing_scores.values())

    if "summary" in params and isinstance(params["summary"], str):
        doc["summary"] = params["summary"]

    report_path = get_role_report_path(run_id, role)
    write_atomic(report_path, doc)

    return {"success": True, "saved_criteria": len(doc["scores"]), "report_path": str(report_path)}


def save_flag(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_flag: валидирует флаг и добавляет в список flags отчёта роли."""
    run_id = params.get("run_id") or guard.extract_run_id(session_id)
    if not run_id:
        raise ValueError("run_id is required")

    role = params.get("role") or guard.extract_role(session_id)
    if not role or role not in VALID_ROLES:
        raise ValueError(f"valid role is required (one of {sorted(VALID_ROLES)})")

    flag_data = params.get("flag")
    if not isinstance(flag_data, dict):
        raise ValueError("flag must be an object")

    validate_flag_item(flag_data)

    doc = load_or_init_scores_doc(run_id, role)
    flags = doc.setdefault("flags", [])
    flags.append(flag_data)

    report_path = get_role_report_path(run_id, role)
    write_atomic(report_path, doc)

    return {"success": True, "total_flags": len(flags), "report_path": str(report_path)}


def save_claims(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_claims (роль critic-honesty).

    Валидирует:
    - source_ref (kind + ref) для каждого утверждения
    - contradicted вердикт требует непустой evidence
    - уникальность claim_id
    - максимум MAX_CLAIMS утверждений
    """
    run_id = params.get("run_id") or guard.extract_run_id(session_id)
    if not run_id:
        raise ValueError("run_id is required")

    role = params.get("role") or guard.extract_role(session_id) or "critic-honesty"

    claims = params.get("claims")
    if not isinstance(claims, list):
        raise ValueError("claims must be a list")

    if len(claims) > MAX_CLAIMS:
        raise ValueError(
            f"too many claims ({len(claims)}): maximum is {MAX_CLAIMS} per call"
        )

    seen_ids: set[str] = set()
    for idx, c in enumerate(claims):
        if not isinstance(c, dict):
            raise ValueError(f"claims[{idx}]: must be an object")
        claim_id = c.get("claim_id")
        if not claim_id or not c.get("text"):
            raise ValueError(f"claims[{idx}]: claim_id and text are required")

        # Уникальность claim_id
        if claim_id in seen_ids:
            raise ValueError(f"claims[{idx}]: duplicate claim_id '{claim_id}'")
        seen_ids.add(claim_id)

        if c.get("verdict") not in VALID_CLAIM_VERDICTS:
            raise ValueError(f"claims[{idx}]: verdict must be one of {sorted(VALID_CLAIM_VERDICTS)}")

        # source_ref обязателен — откуда утверждение
        source_ref = c.get("source_ref")
        if not source_ref:
            raise ValueError(f"claims[{idx}]: source_ref is required (where the claim comes from)")
        validate_source_ref(source_ref, context=f"claims[{idx}]")

        evidence = c.get("evidence", [])
        if not isinstance(evidence, list):
            raise ValueError(f"claims[{idx}]: evidence must be a list")

        # contradicted вердикт требует доказательства расхождения
        verdict = c.get("verdict")
        if verdict == "contradicted" and len(evidence) == 0:
            raise ValueError(
                f"claims[{idx}]: verdict 'contradicted' requires at least one evidence item"
            )

        for ev in evidence:
            validate_evidence(ev, context=f"claims[{idx}]")

    doc = load_or_init_scores_doc(run_id, role)
    doc["claims"] = claims

    report_path = get_role_report_path(run_id, role)
    write_atomic(report_path, doc)

    return {"success": True, "claims_count": len(claims), "report_path": str(report_path)}


def save_rubric(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_rubric (роль rubric)."""
    del session_id
    project_id = params.get("project_id")
    if not project_id:
        raise ValueError("project_id is required")

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

    out_path = DATA_DIR / "projects" / str(project_id) / "rubric_draft.json"
    write_atomic(out_path, doc)

    return {"success": True, "criteria_count": len(criteria), "out_path": str(out_path)}


def save_ux_metrics(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_ux_metrics (роль design)."""
    del session_id
    project_id = params.get("project_id")
    if not project_id:
        raise ValueError("project_id is required")

    metrics = params.get("metrics")
    if not isinstance(metrics, list) or len(metrics) == 0:
        raise ValueError("metrics must be a non-empty list")

    for idx, m in enumerate(metrics):
        if not isinstance(m, dict):
            raise ValueError(f"metrics[{idx}]: must be an object")
        for req in ("name", "how_to_measure", "good_looks_like"):
            if req not in m:
                raise ValueError(f"metrics[{idx}]: '{req}' is required")

    doc = {
        "schema_version": "1",
        "kind": "ux_metrics",
        "project_id": str(project_id),
        "metrics": metrics,
    }

    out_path = DATA_DIR / "projects" / str(project_id) / "ux_metrics.json"
    write_atomic(out_path, doc)

    return {"success": True, "metrics_count": len(metrics), "out_path": str(out_path)}


def save_inventory_patch(params: dict[str, Any], session_id: str | None = None) -> dict[str, Any]:
    """Обрабатывает report_inventory_patch (роль sorter)."""
    run_id = params.get("run_id") or guard.extract_run_id(session_id)
    if not run_id:
        raise ValueError("run_id is required")

    submission_id = params.get("submission_id") or "default"
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
