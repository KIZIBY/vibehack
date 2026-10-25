"""Начальная схема: проекты, рубрики, работы, прогоны, оценки, журнал (data-model.md).

Revision ID: 0001
Revises:
"""
import sqlalchemy as sa
from alembic import op

revision = "0001"
down_revision = None
branch_labels = None
depends_on = None

ID = sa.String(26)   # ULID
ROLES = ("rubric", "sorter", "code", "business", "design", "critic-uniqueness", "critic-honesty")
MATERIAL_TYPES = ("repository", "host", "presentation", "screencast", "archive", "code_file", "document",
                  "image", "metrics_row", "other")
APPEND_ONLY_TABLES = ("journal_event", "score_override")
# Ключ строки для SQLite-триггера против INSERT OR REPLACE (REPLACE удаляет старую строку без DELETE-триггера)
SQLITE_ROW_KEY = {
    "journal_event": "run_id = NEW.run_id AND seq = NEW.seq",
    "score_override": "id = NEW.id",
}


def _in(column: str, values) -> sa.TextClause:
    return sa.text(f"{column} IN ({', '.join(repr(v) for v in values)})")


def _ts(name: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, sa.DateTime(timezone=True), nullable=nullable)


def _fk(name: str, target: str, nullable: bool = False) -> sa.Column:
    return sa.Column(name, ID, sa.ForeignKey(f"{target}.id"), nullable=nullable)


def _create_append_only_guards() -> None:
    dialect = op.get_context().dialect.name
    if dialect == "postgresql":
        op.execute(
            "CREATE FUNCTION judge_append_only() RETURNS trigger AS $$ "
            "BEGIN RAISE EXCEPTION '% is append-only', TG_TABLE_NAME; END; "
            "$$ LANGUAGE plpgsql"
        )
        for table in APPEND_ONLY_TABLES:
            for verb in ("UPDATE", "DELETE"):
                op.execute(
                    f"CREATE TRIGGER {table}_no_{verb.lower()} BEFORE {verb} ON {table} "
                    "FOR EACH ROW EXECUTE FUNCTION judge_append_only()"
                )
            # TRUNCATE не вызывает построчные триггеры — закрываем его отдельным триггером на оператор
            op.execute(
                f"CREATE TRIGGER {table}_no_truncate BEFORE TRUNCATE ON {table} "
                "FOR EACH STATEMENT EXECUTE FUNCTION judge_append_only()"
            )
    else:
        for table in APPEND_ONLY_TABLES:
            for verb in ("UPDATE", "DELETE"):
                op.execute(
                    f"CREATE TRIGGER {table}_no_{verb.lower()} BEFORE {verb} ON {table} "
                    f"BEGIN SELECT RAISE(ABORT, '{table} is append-only'); END"
                )
            op.execute(
                f"CREATE TRIGGER {table}_no_replace BEFORE INSERT ON {table} "
                f"WHEN EXISTS (SELECT 1 FROM {table} WHERE {SQLITE_ROW_KEY[table]}) "
                f"BEGIN SELECT RAISE(ABORT, '{table} is append-only'); END"
            )


def _drop_append_only_guards() -> None:
    dialect = op.get_context().dialect.name
    for table in APPEND_ONLY_TABLES:
        for verb in ("update", "delete"):
            if dialect == "postgresql":
                op.execute(f"DROP TRIGGER {table}_no_{verb} ON {table}")
            else:
                op.execute(f"DROP TRIGGER {table}_no_{verb}")
        if dialect == "postgresql":
            op.execute(f"DROP TRIGGER {table}_no_truncate ON {table}")
        else:
            op.execute(f"DROP TRIGGER {table}_no_replace")
    if dialect == "postgresql":
        op.execute("DROP FUNCTION judge_append_only()")


def upgrade() -> None:
    op.create_table(
        "project",
        sa.Column("id", ID, primary_key=True),
        sa.Column("name", sa.String, nullable=False),
        sa.Column("type", sa.String, nullable=False),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("starts_on", sa.Date),
        sa.Column("ends_on", sa.Date),
        sa.Column("agents", sa.JSON, nullable=False),
        sa.Column("required_materials", sa.JSON, nullable=False),
        sa.Column("rubric_confirmed_version", sa.Integer),
        sa.Column("retention_days", sa.Integer, nullable=False, server_default=sa.text("7")),
        _ts("last_activity_at"),
        sa.Column("version", sa.Integer, nullable=False, server_default=sa.text("1")),
        _ts("created_at"),
        _ts("updated_at"),
        _ts("deleted_at", nullable=True),
        sa.CheckConstraint(_in("type", ("product_hackathon", "ml_hackathon", "homework", "other")),
                           name="ck_project_type"),
        sa.CheckConstraint(_in("status", ("setup", "intake", "evaluating", "results", "archived")),
                           name="ck_project_status"),
    )

    op.create_table(
        "brief",
        sa.Column("id", ID, primary_key=True),
        _fk("project_id", "project"),
        sa.Column("name", sa.String, nullable=False),
        sa.Column("source", sa.String, nullable=False),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("reason", sa.String),
        sa.Column("path", sa.String),
        sa.Column("extracted_text_path", sa.String),
        _ts("created_at"),
        _ts("deleted_at", nullable=True),
        sa.CheckConstraint(_in("source", ("upload", "url", "chat")), name="ck_brief_source"),
        sa.CheckConstraint(_in("status", ("processing", "extracted", "failed", "deleted")), name="ck_brief_status"),
    )
    op.create_index("ix_brief_project", "brief", ["project_id"])

    op.create_table(
        "rubric",
        sa.Column("id", ID, primary_key=True),
        _fk("project_id", "project"),
        sa.Column("version", sa.Integer, nullable=False),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("weights_were_missing", sa.Boolean, nullable=False, server_default=sa.false()),
        _ts("confirmed_at", nullable=True),
        _ts("created_at"),
        sa.UniqueConstraint("project_id", "version", name="uq_rubric_project_version"),
        sa.CheckConstraint(_in("status", ("draft", "confirmed", "superseded")), name="ck_rubric_status"),
    )

    op.create_table(
        "criterion",
        sa.Column("id", ID, primary_key=True),
        _fk("rubric_id", "rubric"),
        sa.Column("position", sa.Integer, nullable=False),
        sa.Column("name", sa.String, nullable=False),
        sa.Column("description", sa.String),
        sa.Column("weight", sa.Float, nullable=False),
        sa.Column("max_score", sa.Float, nullable=False),
        sa.Column("agent", sa.String, nullable=False),
        sa.Column("anchors", sa.JSON),
        sa.Column("source_ref", sa.String),
        sa.CheckConstraint("weight > 0", name="ck_criterion_weight"),
        sa.CheckConstraint("max_score > 0", name="ck_criterion_max_score"),
    )
    op.create_index("ix_criterion_rubric", "criterion", ["rubric_id", "position"])

    op.create_table(
        "ux_metrics",
        sa.Column("project_id", ID, sa.ForeignKey("project.id"), primary_key=True),
        sa.Column("metrics", sa.JSON, nullable=False),
        _ts("created_at"),
    )

    op.create_table(
        "message",
        sa.Column("id", ID, primary_key=True),
        _fk("project_id", "project"),
        sa.Column("author", sa.String, nullable=False),
        sa.Column("kind", sa.String, nullable=False),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("attachments", sa.JSON),
        _ts("created_at"),
        sa.CheckConstraint(_in("author", ("organizer", "agent", "system")), name="ck_message_author"),
    )
    op.create_index("ix_message_project_created", "message", ["project_id", "created_at", "id"])

    op.create_table(
        "submission",
        sa.Column("id", ID, primary_key=True),
        _fk("project_id", "project"),
        sa.Column("team_name", sa.String, nullable=False),
        sa.Column("intake_status", sa.String, nullable=False),
        sa.Column("completeness", sa.String),
        sa.Column("missing", sa.JSON),
        sa.Column("inventory_path", sa.String),
        sa.Column("version", sa.Integer, nullable=False, server_default=sa.text("1")),
        _ts("created_at"),
        _ts("deleted_at", nullable=True),
        sa.UniqueConstraint("project_id", "team_name", name="uq_submission_project_team"),
        sa.CheckConstraint(_in("intake_status", ("pending", "running", "ready", "failed")),
                           name="ck_submission_intake_status"),
    )

    op.create_table(
        "material",
        sa.Column("id", ID, primary_key=True),
        _fk("submission_id", "submission"),
        sa.Column("type", sa.String, nullable=False),
        sa.Column("source_kind", sa.String, nullable=False),
        sa.Column("source_ref", sa.String),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("reason", sa.String),
        sa.Column("size_bytes", sa.Integer),
        _ts("purged_at", nullable=True),
        sa.CheckConstraint(_in("type", MATERIAL_TYPES), name="ck_material_type"),
        sa.CheckConstraint(_in("source_kind", ("upload", "url")), name="ck_material_source_kind"),
        sa.CheckConstraint(_in("status", ("available", "partial", "unavailable", "deleted")),
                           name="ck_material_status"),
    )
    op.create_index("ix_material_submission", "material", ["submission_id"])

    op.create_table(
        "run",
        sa.Column("id", ID, primary_key=True),
        _fk("project_id", "project"),
        sa.Column("rubric_version", sa.Integer, nullable=False),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("requested", sa.JSON),
        sa.Column("tokens_in", sa.Integer),
        sa.Column("tokens_out", sa.Integer),
        sa.Column("cost_usd", sa.Numeric(12, 6)),
        _ts("created_at"),
        _ts("finished_at", nullable=True),
        sa.CheckConstraint(_in("status", ("queued", "running", "completed", "partial", "failed")),
                           name="ck_run_status"),
    )
    op.create_index("ix_run_project", "run", ["project_id", "created_at"])

    op.create_table(
        "run_task",
        sa.Column("id", ID, primary_key=True),
        _fk("run_id", "run"),
        _fk("submission_id", "submission", nullable=True),
        sa.Column("role", sa.String, nullable=False),
        sa.Column("state", sa.String, nullable=False),
        sa.Column("attempt", sa.Integer, nullable=False, server_default=sa.text("1")),
        sa.Column("reason", sa.String),
        sa.Column("hermes_run_id", sa.String),
        _ts("started_at", nullable=True),
        _ts("finished_at", nullable=True),
        sa.Column("tokens_in", sa.Integer),
        sa.Column("tokens_out", sa.Integer),
        sa.Column("cost_usd", sa.Numeric(12, 6)),
        sa.Column("model", sa.String),
        sa.Column("provider", sa.String),
        sa.CheckConstraint(_in("role", ROLES), name="ck_run_task_role"),
        sa.CheckConstraint(_in("state", ("queued", "running", "done", "failed", "no_data")),
                           name="ck_run_task_state"),
    )
    op.create_index("ix_run_task_run", "run_task", ["run_id"])
    # Одна активная задача на (работа, роль) — устав I-15. Для project-level задач (submission_id NULL)
    # уникальность не действует: NULL в уникальных индексах считаются различными.
    active = sa.text("state IN ('queued', 'running')")
    op.create_index("uq_run_task_active", "run_task", ["submission_id", "role"], unique=True,
                    sqlite_where=active, postgresql_where=active)

    op.create_table(
        "criterion_score",
        sa.Column("id", ID, primary_key=True),
        _fk("run_task_id", "run_task"),
        _fk("submission_id", "submission"),
        sa.Column("criterion_id", ID, nullable=False),
        sa.Column("rubric_version", sa.Integer, nullable=False),
        sa.Column("status", sa.String, nullable=False),
        sa.Column("score", sa.Float),
        sa.Column("max_score", sa.Float),
        sa.Column("justification", sa.Text),
        sa.Column("evidence", sa.JSON),
        sa.Column("confidence", sa.Float),
        sa.Column("no_data_reason", sa.String),
        sa.Column("version", sa.Integer, nullable=False, server_default=sa.text("1")),
        _ts("created_at"),
        sa.CheckConstraint(_in("status", ("scored", "no_data")), name="ck_criterion_score_status"),
    )
    op.create_index("ix_criterion_score_lookup", "criterion_score",
                    ["submission_id", "criterion_id", "created_at"])

    op.create_table(
        "score_override",
        sa.Column("id", ID, primary_key=True),
        _fk("criterion_score_id", "criterion_score"),
        _fk("submission_id", "submission"),
        sa.Column("criterion_id", ID, nullable=False),
        sa.Column("score", sa.Float, nullable=False),
        sa.Column("reason", sa.String, nullable=False),
        sa.Column("actor", sa.String, nullable=False),
        _ts("created_at"),
    )
    op.create_index("ix_score_override_score", "score_override", ["criterion_score_id", "created_at"])

    op.create_table(
        "flag",
        sa.Column("id", ID, primary_key=True),
        _fk("run_task_id", "run_task"),
        _fk("submission_id", "submission"),
        sa.Column("criterion_id", ID),
        sa.Column("type", sa.String, nullable=False),
        sa.Column("confidence", sa.Float),
        sa.Column("note", sa.Text),
        sa.Column("evidence", sa.JSON),
        sa.Column("related_submission_id", ID),
        sa.Column("related_url", sa.String),
        _ts("created_at"),
        sa.CheckConstraint(
            _in("type", ("plagiarism", "pre_start_project", "claim_mismatch", "prompt_injection",
                         "incomplete_materials", "agent_failure", "secret_exposed")),
            name="ck_flag_type"),
    )
    op.create_index("ix_flag_submission", "flag", ["submission_id"])

    op.create_table(
        "claim",
        sa.Column("id", ID, primary_key=True),
        _fk("run_task_id", "run_task"),
        sa.Column("claim_id", sa.String, nullable=False),
        sa.Column("text", sa.Text, nullable=False),
        sa.Column("source_ref", sa.JSON),
        sa.Column("verdict", sa.String, nullable=False),
        sa.Column("evidence", sa.JSON),
        sa.CheckConstraint(_in("verdict", ("confirmed", "not_found", "contradicted")), name="ck_claim_verdict"),
    )
    op.create_index("ix_claim_run_task", "claim", ["run_task_id"])

    op.create_table(
        "journal_event",
        sa.Column("run_id", sa.String, nullable=False),
        sa.Column("seq", sa.Integer, nullable=False),
        sa.Column("schema_version", sa.String, nullable=False, server_default="1"),
        _ts("ts"),
        sa.Column("project_id", sa.String, nullable=False),
        sa.Column("submission_id", sa.String),
        sa.Column("role", sa.String),
        sa.Column("session_id", sa.String),
        sa.Column("event", sa.String, nullable=False),
        sa.Column("tool", sa.String),
        sa.Column("args_summary", sa.Text),
        sa.Column("result_summary", sa.Text),
        sa.Column("refs", sa.JSON),
        sa.Column("duration_ms", sa.Integer),
        sa.Column("model", sa.String),
        sa.Column("provider", sa.String),
        sa.Column("tokens_in", sa.Integer),
        sa.Column("tokens_out", sa.Integer),
        sa.Column("cost_usd", sa.Numeric(12, 6)),
        sa.Column("actor", sa.String),
        sa.Column("source", sa.String, nullable=False),
        sa.PrimaryKeyConstraint("run_id", "seq", name="pk_journal_event"),
    )
    op.create_index("ix_journal_event_submission_seq", "journal_event", ["submission_id", "seq"])

    _create_append_only_guards()


def downgrade() -> None:
    _drop_append_only_guards()
    op.drop_index("ix_journal_event_submission_seq", table_name="journal_event")
    op.drop_table("journal_event")
    op.drop_index("ix_claim_run_task", table_name="claim")
    op.drop_table("claim")
    op.drop_index("ix_flag_submission", table_name="flag")
    op.drop_table("flag")
    op.drop_index("ix_score_override_score", table_name="score_override")
    op.drop_table("score_override")
    op.drop_index("ix_criterion_score_lookup", table_name="criterion_score")
    op.drop_table("criterion_score")
    op.drop_index("uq_run_task_active", table_name="run_task")
    op.drop_index("ix_run_task_run", table_name="run_task")
    op.drop_table("run_task")
    op.drop_index("ix_run_project", table_name="run")
    op.drop_table("run")
    op.drop_index("ix_material_submission", table_name="material")
    op.drop_table("material")
    op.drop_table("submission")
    op.drop_index("ix_message_project_created", table_name="message")
    op.drop_table("message")
    op.drop_table("ux_metrics")
    op.drop_index("ix_criterion_rubric", table_name="criterion")
    op.drop_table("criterion")
    op.drop_table("rubric")
    op.drop_index("ix_brief_project", table_name="brief")
    op.drop_table("brief")
    op.drop_table("project")
