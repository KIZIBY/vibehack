"""Восстановление после перезапуска: фоновые задачи живут в процессе, их записи не должны зависать навсегда."""
import logging

from sqlalchemy import text
from sqlalchemy.orm import sessionmaker

from ..db import session_scope
from . import orchestrator

log = logging.getLogger(__name__)
ACTIVE_RUN = "status IN ('queued', 'running')"
INTERRUPTED_BRIEF_REASON = "прервано перезапуском"


def recover_interrupted_work(session_factory: sessionmaker) -> dict:
    """Брифы в обработке, работы с незавершённым intake и активные прогоны -> ``failed``; статус проекта выправляется."""
    with session_scope(session_factory) as session:
        affected = [row[0] for row in session.execute(text(
            f"SELECT project_id FROM run WHERE {ACTIVE_RUN} UNION SELECT id FROM project WHERE status = 'evaluating'"))]
    runs = orchestrator.recover_interrupted(session_factory)   # свои транзакции; исключение уходит наружу без правок
    with session_scope(session_factory) as session:
        briefs = session.execute(
            text("UPDATE brief SET status = 'failed', reason = :reason WHERE status = 'processing'"),
            {"reason": INTERRUPTED_BRIEF_REASON}).rowcount
        submissions = session.execute(
            text("UPDATE submission SET intake_status = 'failed' WHERE intake_status IN ('pending', 'running')")).rowcount
        for project_id in affected:
            _settle_project(session, project_id)
    result = {"briefs": briefs, "submissions": submissions, "run_tasks": runs, "runs": runs}
    if any(result.values()):
        log.warning("восстановлена прерванная работа", extra=result)
    return result


def _settle_project(session, project_id: str) -> None:
    """Проект, застрявший в оценке, возвращается в рабочий статус: results при наличии оценок, иначе intake."""
    has_scores = session.execute(text(
        "SELECT 1 FROM criterion_score cs JOIN submission s ON s.id = cs.submission_id WHERE s.project_id = :p LIMIT 1"),
        {"p": project_id}).first() is not None
    session.execute(
        text("UPDATE project SET status = :status WHERE id = :p AND status IN ('evaluating', 'results')"),
        {"status": "results" if has_scores else "intake", "p": project_id})
