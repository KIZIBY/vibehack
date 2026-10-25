"""T030: работы — ``/api/v1/projects/{id}/submissions``, ``…/submissions:batch``, ``/api/v1/submissions/{id}``.
Тесты написаны ДО реализации (RED): ``backend/app/{routers,services}/submissions.py`` ещё нет.

Контракт (contracts/openapi.yaml, задание T030):
- ``POST …/submissions`` (multipart: ``team_name``, ``files``[], ``links`` — JSON-массив URL строкой) -> 201 ``SubmissionSummary``
  (``intake_status=pending``, ``completeness=unknown``, ``evaluation_status=not_started``, ``flags=[]``);
  имя 1–120 символов после обрезки, уникально в проекте без учёта регистра (дубликат -> 409 ``conflict``, в том числе при гонке);
  не больше 30 файлов и 20 ссылок, файл не больше ``MAX_FILE_BYTES`` (413), ссылка проходит ``validate_public_url`` ДО записи чего-либо
  (небезопасная -> 422 ``invalid``, ничего не создаётся); файлы лежат в ``projects/<pid>/submissions/<sid>/raw/…``;
  проект ``setup`` -> ``intake``; сбой после записи файлов не оставляет ни строк БД, ни файлов;
- ``GET …/submissions`` -> ``{"items": [SubmissionSummary…]}``; ``GET /api/v1/submissions/{id}`` -> ``SubmissionDetail``;
  404 для неизвестных и удалённых;
- ``POST …/submissions:batch`` (multipart: ``table`` CSV/XLSX, ``archive`` ZIP) -> 201 ``{items, rejected}``;
  ``rejected[].row`` — номер строки листа (заголовок = 1, первая строка данных = ``"2"``) либо имя папки архива;
  плохие строки не валят пачку; лимиты: таблица 5 МБ, 500 строк (413), XLSX не распаковывается сверх лимита (413);
  ZIP не распаковывается API: сохраняется как материал ``archive`` каждой команды, чьё имя совпало с папкой верхнего уровня
  (команды пачки = строки таблицы + папки архива без строки).

Ссылки проверяются резолвером из ``app.state.url_resolver`` (в тестах сети нет). Фоновый intake подменён заглушкой.
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import io
import json
import threading
import zipfile
from pathlib import Path

import jsonschema
import pytest
import sqlalchemy as sa
import yaml
from alembic import command
from alembic.config import Config

REPO = Path(__file__).resolve().parents[2]
BACKEND = REPO / "backend"
OPENAPI = REPO / "specs" / "001-ai-judge-platform" / "contracts" / "openapi.yaml"
SESSION_SECRET = "session-secret-ZK7"      # выдуманное значение
PROJECTS = "/api/v1/projects"
PUBLIC_IP = "93.184.216.34"


# ─────────────────────────────── хелперы ───────────────────────────────

def assert_matches(name: str, payload) -> None:
    doc = yaml.safe_load(OPENAPI.read_text(encoding="utf-8"))
    jsonschema.validate(payload, {"$ref": f"#/components/schemas/{name}", "components": doc["components"]},
                        format_checker=jsonschema.FormatChecker())


def make_cfg(url: str) -> Config:
    cfg = Config(str(BACKEND / "alembic.ini"))
    cfg.set_main_option("script_location", str(BACKEND / "migrations"))
    cfg.set_main_option("sqlalchemy.url", url)
    return cfg


def fake_resolver(host, port, *args, **kwargs):
    address = "127.0.0.1" if str(host).startswith("evil") else PUBLIC_IP
    return [(2, 1, 6, "", (address, port))]


class StubRunner:
    """Заглушка IntakeRunner: без подпроцесса, опись «полная»; ``calls`` — каталоги, с которыми вызывали."""

    def __init__(self):
        self.calls = []

    async def run(self, submission_dir, out_dir):
        self.calls.append((Path(submission_dir), Path(out_dir)))
        sub = Path(submission_dir)
        return {"schema_version": "1", "submission_id": sub.name, "project_id": sub.parent.parent.name,
                "team_name": "x", "created_at": "2026-10-25T10:00:00Z", "materials": [],
                "completeness": {"status": "complete", "required": [], "missing": []}}


def make_app(tmp_path):
    from app.config import load_settings
    from app.main import create_app
    url = f"sqlite:///{tmp_path / 'db.sqlite'}"
    command.upgrade(make_cfg(url), "head")
    settings = load_settings({"JUDGE_DATABASE_URL": url, "JUDGE_SESSION_SECRET": SESSION_SECRET,
                              "JUDGE_DATA_DIR": str(tmp_path / "data")})
    app = create_app(settings)
    app.state.url_resolver = fake_resolver
    app.state.intake_runner = StubRunner()
    return app


def make_client(app, *, authorized: bool = True):
    from fastapi.testclient import TestClient
    client = TestClient(app, raise_server_exceptions=False)
    if authorized:
        client.cookies.set("session", app.state.sessions.issue("demo"))
    return client


@pytest.fixture
def app(tmp_path):
    return make_app(tmp_path)


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


@pytest.fixture
def project(client):
    resp = client.post(PROJECTS, json={"name": "Хакатон", "type": "product_hackathon"})
    assert resp.status_code == 201
    return resp.json()


def subs_url(project_id: str) -> str:
    return f"{PROJECTS}/{project_id}/submissions"


def batch_url(project_id: str) -> str:
    return f"{PROJECTS}/{project_id}/submissions:batch"


def post_sub(client, project_id, team="Команда", files=(), links=None):
    data = {"team_name": team}
    if links is not None:
        data["links"] = links if isinstance(links, str) else json.dumps(links)
    parts = [("files", (name, content, "application/octet-stream")) for name, content in files]
    return client.post(subs_url(project_id), data=data, files=parts or None)


def post_batch(client, project_id, table=None, archive=None, table_name="teams.csv"):
    parts = {}
    if table is not None:
        parts["table"] = (table_name, table, "application/octet-stream")
    if archive is not None:
        parts["archive"] = ("teams.zip", archive, "application/zip")
    return client.post(batch_url(project_id), files=parts or None)


def error_of(resp) -> dict:
    return resp.json()["error"]


def sql(app, statement: str, params: dict | None = None):
    with app.state.engine.begin() as conn:
        return conn.execute(sa.text(statement), params or {})


def rows(app, statement: str, params: dict | None = None) -> list[dict]:
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(sa.text(statement), params or {}).mappings()]


def stored_files(tmp_path) -> list[Path]:
    root = tmp_path / "data"
    return sorted(p for p in root.rglob("*") if p.is_file()) if root.exists() else []


def csv_bytes(*lines: str, bom: bool = False) -> bytes:
    return (("﻿" if bom else "") + "\n".join(lines) + "\n").encode("utf-8")


def xlsx_bytes(table: list[list]) -> bytes:
    from openpyxl import Workbook
    workbook = Workbook()
    sheet = workbook.active
    for line in table:
        sheet.append(line)
    buffer = io.BytesIO()
    workbook.save(buffer)
    return buffer.getvalue()


def zip_bytes(entries: dict[str, bytes]) -> bytes:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        for name, content in entries.items():
            archive.writestr(name, content)
    return buffer.getvalue()


HEADER = "team_name,repo_url,host_url,presentation_url,screencast_url"
TYPES_BY_TEAM = ("SELECT s.team_name, group_concat(m.type) AS types FROM submission s "
                 "JOIN material m ON m.submission_id = s.id GROUP BY s.id")


def types_by_team(app) -> dict:
    return {r["team_name"]: sorted(r["types"].split(",")) for r in rows(app, TYPES_BY_TEAM)}


# ─────────────────────────────── доступ ───────────────────────────────

@pytest.mark.parametrize("method,path", [("get", "/api/v1/projects/X/submissions"), ("post", "/api/v1/projects/X/submissions"),
                                         ("post", "/api/v1/projects/X/submissions:batch"),
                                         ("get", "/api/v1/submissions/X")])
def test_submissions_require_session(app, method, path):
    with make_client(app, authorized=False) as anonymous:
        resp = getattr(anonymous, method)(path)
    assert resp.status_code == 401 and error_of(resp)["code"] == "unauthorized"


# ─────────────────────────────── создание одной работы ───────────────────────────────

def test_create_returns_pending_summary_and_rows(app, client, project, tmp_path):
    resp = post_sub(client, project["id"], "  Команда А  ", files=[("slides.pdf", b"%PDF-1.4 data")],
                    links=["https://github.com/team/repo", "https://demo.example.org/app"])
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert_matches("SubmissionSummary", body)
    assert body["team_name"] == "Команда А"
    assert (body["intake_status"], body["completeness"], body["evaluation_status"], body["flags"]) == (
        "pending", "unknown", "not_started", [])
    sub = rows(app, "SELECT * FROM submission WHERE id = :id", {"id": body["id"]})[0]
    assert sub["project_id"] == project["id"] and sub["team_name"] == "Команда А"
    materials = rows(app, "SELECT * FROM material WHERE submission_id = :id", {"id": body["id"]})
    by_type = {m["type"]: m for m in materials}
    assert set(by_type) == {"presentation", "repository", "host"}
    assert all(m["status"] == "available" and len(m["id"]) == 26 for m in materials)
    assert by_type["repository"]["source_kind"] == "url" and by_type["repository"]["source_ref"] == "https://github.com/team/repo"
    assert by_type["host"]["source_kind"] == "url"
    upload = by_type["presentation"]
    assert upload["source_kind"] == "upload" and upload["size_bytes"] == len(b"%PDF-1.4 data")
    assert upload["source_ref"].startswith(f"projects/{project['id']}/submissions/{body['id']}/raw/")
    assert not upload["source_ref"].startswith("/") and str(tmp_path) not in upload["source_ref"]
    assert (tmp_path / "data" / upload["source_ref"]).read_bytes() == b"%PDF-1.4 data"


@pytest.mark.parametrize("filename,expected", [
    ("slides.pdf", "presentation"), ("deck.PPTX", "presentation"), ("old.ppt", "presentation"), ("talk.key", "presentation"),
    ("demo.mp4", "screencast"), ("demo.mov", "screencast"), ("demo.webm", "screencast"), ("demo.mkv", "screencast"),
    ("code.zip", "archive"), ("code.tar", "archive"), ("code.gz", "archive"), ("code.7z", "archive"),
    ("shot.png", "image"), ("shot.JPG", "image"), ("shot.jpeg", "image"), ("shot.gif", "image"), ("shot.webp", "image"),
    ("notes.txt", "other"), ("noext", "other"),
])
def test_file_material_type_heuristic(app, client, project, filename, expected):
    resp = post_sub(client, project["id"], files=[(filename, b"x")])
    assert resp.status_code == 201, resp.text
    assert [m["type"] for m in rows(app, "SELECT type FROM material")] == [expected]


@pytest.mark.parametrize("url,expected", [
    ("https://github.com/a/b", "repository"), ("https://gitlab.com/a/b", "repository"),
    ("https://bitbucket.org/a/b", "repository"), ("https://git.example.org/a/b.git", "repository"),
    ("https://example.org/app", "host"), ("http://demo.example.org/", "host"),
])
def test_link_material_type_heuristic(app, client, project, url, expected):
    resp = post_sub(client, project["id"], links=[url])
    assert resp.status_code == 201, resp.text
    assert [m["type"] for m in rows(app, "SELECT type FROM material")] == [expected]


def test_create_moves_project_from_setup_to_intake_and_touches_it(app, client, project):
    before = rows(app, "SELECT status, last_activity_at FROM project WHERE id = :id", {"id": project["id"]})[0]
    assert before["status"] == "setup"
    assert post_sub(client, project["id"], links=["https://github.com/a/b"]).status_code == 201
    after = rows(app, "SELECT status, last_activity_at FROM project WHERE id = :id", {"id": project["id"]})[0]
    assert after["status"] == "intake" and after["last_activity_at"] > before["last_activity_at"]


def test_create_keeps_other_project_status(app, client, project):
    sql(app, "UPDATE project SET status = 'evaluating' WHERE id = :id", {"id": project["id"]})
    assert post_sub(client, project["id"]).status_code == 201
    assert rows(app, "SELECT status FROM project WHERE id = :id", {"id": project["id"]})[0]["status"] == "evaluating"


def test_create_starts_intake_in_background_on_the_submission_directory(app, client, project, tmp_path):
    body = post_sub(client, project["id"], files=[("a.pdf", b"x")]).json()
    runner = app.state.intake_runner
    sub_dir = (tmp_path / "data" / "projects" / project["id"] / "submissions" / body["id"]).resolve()
    assert [c[0].resolve() for c in runner.calls] == [sub_dir]
    detail = client.get(f"/api/v1/submissions/{body['id']}").json()
    assert detail["complete"] is True
    listed = client.get(subs_url(project["id"])).json()["items"][0]
    assert (listed["intake_status"], listed["completeness"]) == ("ready", "complete")


@pytest.mark.parametrize("team", ["", "   ", "\t\n", "я" * 121, " " + "я" * 121])
def test_create_rejects_bad_team_name(app, client, project, team):
    resp = post_sub(client, project["id"], team)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert rows(app, "SELECT id FROM submission") == []


def test_create_requires_team_name(client, project):
    resp = client.post(subs_url(project["id"]), data={"links": "[]"})
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"


def test_create_accepts_120_chars_after_trim(client, project):
    resp = post_sub(client, project["id"], "  " + "я" * 120 + "  ")
    assert resp.status_code == 201 and resp.json()["team_name"] == "я" * 120


def test_duplicate_team_name_is_conflict_case_insensitive(app, client, project, tmp_path):
    first = post_sub(client, project["id"], "Команда", files=[("a.pdf", b"one")])
    assert first.status_code == 201
    files_before = stored_files(tmp_path)
    for variant in ("Команда", "команда", "КОМАНДА", "  Команда "):
        resp = post_sub(client, project["id"], variant, files=[("b.pdf", b"two")], links=["https://github.com/a/b"])
        assert resp.status_code == 409 and error_of(resp)["code"] == "conflict", variant
    assert len(rows(app, "SELECT id FROM submission")) == 1
    assert len(rows(app, "SELECT id FROM material")) == 1
    assert stored_files(tmp_path) == files_before


def test_same_team_name_in_another_project_is_fine(client, project):
    other = client.post(PROJECTS, json={"name": "Второй", "type": "other"}).json()
    assert post_sub(client, project["id"], "Команда").status_code == 201
    assert post_sub(client, other["id"], "команда").status_code == 201


@pytest.mark.parametrize("names", [("Команда", "Команда"), ("Команда", "команда")])
def test_parallel_duplicates_create_exactly_one(app, project, names):
    statuses = []

    def worker(team):
        c = make_client(app)        # без lifespan: выход из него закрыл бы общий движок под соседним потоком
        statuses.append(post_sub(c, project["id"], team).status_code)

    threads = [threading.Thread(target=worker, args=(n,)) for n in names]
    for t in threads:
        t.start()
    for t in threads:
        t.join()
    assert sorted(statuses) == [201, 409]
    assert len(rows(app, "SELECT id FROM submission")) == 1


def test_limit_of_30_files_and_20_links(app, client, project):
    assert post_sub(client, project["id"], "ok", files=[(f"f{i}.txt", b"x") for i in range(30)]).status_code == 201
    too_many_files = post_sub(client, project["id"], "many", files=[(f"f{i}.txt", b"x") for i in range(31)])
    assert too_many_files.status_code == 422 and error_of(too_many_files)["code"] == "invalid"
    assert post_sub(client, project["id"], "links-ok",
                    links=[f"https://example.org/{i}" for i in range(20)]).status_code == 201
    too_many_links = post_sub(client, project["id"], "links", links=[f"https://example.org/{i}" for i in range(21)])
    assert too_many_links.status_code == 422
    assert {r["team_name"] for r in rows(app, "SELECT team_name FROM submission")} == {"ok", "links-ok"}


@pytest.mark.parametrize("links", ["not json", '{"a": 1}', '"https://a.example/"', "[1, 2]", "[null]"])
def test_links_must_be_a_json_array_of_strings(app, client, project, links):
    resp = post_sub(client, project["id"], links=links)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert rows(app, "SELECT id FROM submission") == []


@pytest.mark.parametrize("bad", [
    "http://127.0.0.1/x", "http://169.254.169.254/latest/meta-data", "http://localhost/x", "ftp://example.org/x",
    "https://evil.example.org/x", "file:///etc/passwd", "http://[::1]/",
])
def test_unsafe_link_rejects_everything_before_saving(app, client, project, tmp_path, bad):
    resp = post_sub(client, project["id"], files=[("a.pdf", b"x")], links=["https://github.com/a/b", bad])
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert rows(app, "SELECT id FROM submission") == [] and rows(app, "SELECT id FROM material") == []
    assert stored_files(tmp_path) == []


def test_too_large_file_is_413_and_leaves_nothing(app, client, project, tmp_path, monkeypatch):
    from app.services import submissions
    monkeypatch.setattr(submissions, "MAX_FILE_BYTES", 10)
    resp = post_sub(client, project["id"], files=[("ok.txt", b"1234"), ("big.bin", b"x" * 11)])
    assert resp.status_code == 413 and error_of(resp)["code"] == "too_large"
    assert rows(app, "SELECT id FROM submission") == [] and rows(app, "SELECT id FROM material") == []
    assert stored_files(tmp_path) == []


def test_file_names_are_sanitized_inside_the_submission_tree(app, client, project, tmp_path):
    body = post_sub(client, project["id"], files=[("../../etc/passwd.txt", b"x"), ("a\\b\\c.pdf", b"y")]).json()
    base = (tmp_path / "data" / "projects" / project["id"] / "submissions" / body["id"] / "raw").resolve()
    files = stored_files(tmp_path)
    assert len(files) == 2 and all(f.resolve().is_relative_to(base) for f in files)
    assert {f.name for f in files} == {"passwd.txt", "c.pdf"}


def test_same_file_name_twice_is_kept(app, client, project, tmp_path):
    body = post_sub(client, project["id"], files=[("a.pdf", b"one"), ("a.pdf", b"two")]).json()
    assert sorted(f.read_bytes() for f in stored_files(tmp_path)) == [b"one", b"two"]
    assert len(rows(app, "SELECT id FROM material WHERE submission_id = :id", {"id": body["id"]})) == 2


def test_unknown_or_deleted_project_is_404_and_saves_nothing(app, client, project, tmp_path):
    resp = post_sub(client, "NOPE", files=[("a.pdf", b"x")])
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": project["id"]})
    assert post_sub(client, project["id"], files=[("a.pdf", b"x")]).status_code == 404
    assert client.get(subs_url(project["id"])).status_code == 404
    assert stored_files(tmp_path) == []


def test_failure_after_saving_files_leaves_no_rows_and_no_files(app, client, project, tmp_path, monkeypatch):
    from app.services import projects

    def boom(*args, **kwargs):
        raise RuntimeError("сбой после записи файлов")

    monkeypatch.setattr(projects, "touch_project", boom)
    resp = post_sub(client, project["id"], files=[("a.pdf", b"x" * 1000)], links=["https://github.com/a/b"])
    assert resp.status_code == 500
    assert rows(app, "SELECT id FROM submission") == [] and rows(app, "SELECT id FROM material") == []
    assert stored_files(tmp_path) == []
    assert rows(app, "SELECT status FROM project WHERE id = :id", {"id": project["id"]})[0]["status"] == "setup"
    assert str(tmp_path) not in resp.text


# ─────────────────────────────── список и детали ───────────────────────────────

def test_list_is_empty_then_in_creation_order(client, project):
    assert client.get(subs_url(project["id"])).json() == {"items": []}
    ids = [post_sub(client, project["id"], name).json()["id"] for name in ("Б", "А", "В")]
    items = client.get(subs_url(project["id"])).json()["items"]
    assert [i["id"] for i in items] == ids
    for item in items:
        assert_matches("SubmissionSummary", item)
        assert item["evaluation_status"] == "not_started" and item["flags"] == []


def test_list_is_per_project_and_hides_deleted(app, client, project):
    other = client.post(PROJECTS, json={"name": "Второй", "type": "other"}).json()
    keep = post_sub(client, project["id"], "Остаётся").json()["id"]
    gone = post_sub(client, project["id"], "Удалена").json()["id"]
    post_sub(client, other["id"], "Чужая")
    sql(app, "UPDATE submission SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": gone})
    assert [i["id"] for i in client.get(subs_url(project["id"])).json()["items"]] == [keep]


def test_list_reports_missing_from_inventory(app, client, project):
    sub = post_sub(client, project["id"], "Команда").json()["id"]
    sql(app, "UPDATE submission SET completeness = 'incomplete', missing = :m WHERE id = :id",
        {"m": json.dumps(["repository"]), "id": sub})
    item = client.get(subs_url(project["id"])).json()["items"][0]
    assert item["completeness"] == "incomplete" and item["missing"] == ["repository"]
    assert_matches("SubmissionSummary", item)


def test_unknown_project_list_is_404(client):
    resp = client.get(subs_url("NOPE"))
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


def test_detail_matches_schema(app, client, project):
    sub = post_sub(client, project["id"], "Команда", files=[("slides.pdf", b"x")], links=["https://github.com/a/b"]).json()["id"]
    sql(app, "UPDATE material SET status = 'partial', reason = 'частично' WHERE type = 'repository'")
    detail = client.get(f"/api/v1/submissions/{sub}")
    assert detail.status_code == 200
    body = detail.json()
    assert_matches("SubmissionDetail", body)
    assert body["id"] == sub and body["team_name"] == "Команда"
    assert (body["criteria"], body["flags"], body["total"], body["cost_usd"], body["latest_run_id"]) == ([], [], None, None, None)
    assert isinstance(body["complete"], bool)
    by_type = {m["type"]: m for m in body["materials"]}
    assert set(by_type) == {"presentation", "repository"}
    assert by_type["repository"]["status"] == "partial" and by_type["repository"]["reason"] == "частично"
    assert by_type["presentation"]["name"] == "slides.pdf" and by_type["presentation"]["status"] == "available"
    assert all(len(m["material_id"]) == 26 for m in body["materials"])
    assert "source_ref" not in json.dumps(body) and "projects/" not in json.dumps(body)


def test_detail_complete_follows_completeness(app, client, project):
    sub = post_sub(client, project["id"], "Команда").json()["id"]
    sql(app, "UPDATE submission SET completeness = 'incomplete' WHERE id = :id", {"id": sub})
    assert client.get(f"/api/v1/submissions/{sub}").json()["complete"] is False
    sql(app, "UPDATE submission SET completeness = 'complete' WHERE id = :id", {"id": sub})
    assert client.get(f"/api/v1/submissions/{sub}").json()["complete"] is True


def test_detail_404_for_unknown_deleted_and_deleted_project(app, client, project):
    sub = post_sub(client, project["id"], "Команда").json()["id"]
    assert client.get("/api/v1/submissions/NOPE").status_code == 404
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": project["id"]})
    assert client.get(f"/api/v1/submissions/{sub}").status_code == 404
    sql(app, "UPDATE project SET deleted_at = NULL WHERE id = :id", {"id": project["id"]})
    sql(app, "UPDATE submission SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": sub})
    resp = client.get(f"/api/v1/submissions/{sub}")
    assert resp.status_code == 404 and error_of(resp)["code"] == "not_found"


# ─────────────────────────────── пачка: таблица ───────────────────────────────

def test_batch_csv_creates_submissions_with_link_materials(app, client, project):
    table = csv_bytes(HEADER,
                      "Альфа,https://github.com/a/alfa,https://alfa.example.org,https://alfa.example.org/deck,https://alfa.example.org/v",
                      "Бета,https://gitlab.com/b/beta,,,")
    resp = post_batch(client, project["id"], table)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert body["rejected"] == [] and [i["team_name"] for i in body["items"]] == ["Альфа", "Бета"]
    for item in body["items"]:
        assert_matches("SubmissionSummary", item)
        assert (item["intake_status"], item["completeness"]) == ("pending", "unknown")
    types = types_by_team(app)
    assert types["Альфа"] == ["host", "presentation", "repository", "screencast"]
    assert types["Бета"] == ["repository"]
    assert rows(app, "SELECT status FROM project WHERE id = :id", {"id": project["id"]})[0]["status"] == "intake"
    assert len(app.state.intake_runner.calls) == 2      # опись строится для каждой работы


@pytest.mark.parametrize("table", [
    csv_bytes(HEADER, "Альфа,https://github.com/a/alfa,,,", bom=True),
    csv_bytes("team_name;repo_url", "Альфа;https://github.com/a/alfa"),
    csv_bytes("Team_Name , Repo_URL ,unknown_col", "Альфа,https://github.com/a/alfa,zzz"),
])
def test_batch_csv_variants(client, project, table):
    resp = post_batch(client, project["id"], table)
    assert resp.status_code == 201, resp.text
    assert resp.json()["rejected"] == [] and [i["team_name"] for i in resp.json()["items"]] == ["Альфа"]


def test_batch_xlsx_first_sheet(client, project):
    table = xlsx_bytes([["team_name", "repo_url", "host_url"],
                        ["Альфа", "https://github.com/a/alfa", "https://alfa.example.org"],
                        ["Бета", None, None]])
    resp = post_batch(client, project["id"], table, table_name="teams.xlsx")
    assert resp.status_code == 201, resp.text
    assert [i["team_name"] for i in resp.json()["items"]] == ["Альфа", "Бета"] and resp.json()["rejected"] == []


def test_batch_xlsx_formulas_are_not_evaluated(app, client, project):
    table = xlsx_bytes([["team_name", "repo_url"], ["Альфа", '=HYPERLINK("http://127.0.0.1/x","y")'],
                        ["Бета", "https://github.com/b/beta"]])
    resp = post_batch(client, project["id"], table, table_name="teams.xlsx")
    assert resp.status_code == 201
    body = resp.json()
    assert [i["team_name"] for i in body["items"]] == ["Бета"]
    assert [r["row"] for r in body["rejected"]] == ["2"]
    assert rows(app, "SELECT source_ref FROM material") == [{"source_ref": "https://github.com/b/beta"}]


def test_batch_rejects_bad_rows_without_failing_the_batch(app, client, project):
    post_sub(client, project["id"], "Существует")
    table = csv_bytes(HEADER,
                      "Хорошая,https://github.com/a/good,,,",                  # 2
                      ",https://github.com/a/noname,,,",                          # 3: нет названия
                      "Плохая ссылка,http://169.254.169.254/latest,,,",           # 4: небезопасная ссылка
                      "хорошая,https://github.com/a/dup,,,",                      # 5: дубликат внутри пачки (регистр)
                      "СУЩЕСТВУЕТ,https://github.com/a/old,,,",                   # 6: дубликат существующей команды
                      "Ссылка-мусор,not a url,,,",                                # 7: невалидная ссылка
                      ",,,,",                                                     # 8: пустая строка
                      "Вторая хорошая,,https://ok.example.org,,")                 # 9
    resp = post_batch(client, project["id"], table)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert [i["team_name"] for i in body["items"]] == ["Хорошая", "Вторая хорошая"]
    assert [r["row"] for r in body["rejected"]] == ["3", "4", "5", "6", "7", "8"]
    assert all(isinstance(r["row"], str) and isinstance(r["reason"], str) and r["reason"] for r in body["rejected"])
    assert {r["team_name"] for r in rows(app, "SELECT team_name FROM submission")} == {"Существует", "Хорошая", "Вторая хорошая"}


def test_batch_trailing_blank_rows_are_ignored(client, project):
    resp = post_batch(client, project["id"], csv_bytes(HEADER, "Альфа,,,,", ",,,,", ",,,,"))
    assert resp.status_code == 201 and resp.json()["rejected"] == [] and len(resp.json()["items"]) == 1


def test_batch_requires_table_or_archive(client, project):
    resp = post_batch(client, project["id"])
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"


@pytest.mark.parametrize("table", [csv_bytes("name,repo_url", "Альфа,https://github.com/a/b"), b"\xff\xfe\x00garbage\x80",
                                   b"", xlsx_bytes([["foo"], ["bar"]])],
                         ids=["no-team-column", "garbage", "empty", "xlsx-no-team-column"])
def test_batch_bad_table_is_422(app, client, project, table):
    resp = post_batch(client, project["id"], table)
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert rows(app, "SELECT id FROM submission") == []


def test_batch_table_over_5_mb_is_413(app, client, project):
    resp = post_batch(client, project["id"], b"team_name\n" + b"a" * (5 * 1024 * 1024 + 1))
    assert resp.status_code == 413 and error_of(resp)["code"] == "too_large"
    assert rows(app, "SELECT id FROM submission") == []


def test_batch_over_500_rows_is_413_and_500_is_the_limit(app, client, project):
    resp = post_batch(client, project["id"], csv_bytes("team_name", *[f"T{i}" for i in range(501)]))
    assert resp.status_code == 413 and error_of(resp)["code"] == "too_large"
    assert rows(app, "SELECT id FROM submission") == []
    resp = post_batch(client, project["id"], csv_bytes("team_name", *[f"T{i}" for i in range(500)]))
    assert resp.status_code == 201 and len(resp.json()["items"]) == 500


def test_batch_xlsx_that_expands_too_much_is_413(app, client, project):
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", zipfile.ZIP_DEFLATED) as archive:
        archive.writestr("xl/worksheets/sheet1.xml", b"0" * (110 * 1024 * 1024))
    assert len(buffer.getvalue()) < 5 * 1024 * 1024
    resp = post_batch(client, project["id"], buffer.getvalue(), table_name="teams.xlsx")
    assert resp.status_code == 413 and error_of(resp)["code"] == "too_large"
    assert rows(app, "SELECT id FROM submission") == []


def test_batch_unknown_project_is_404(client):
    assert post_batch(client, "NOPE", csv_bytes("team_name", "A")).status_code == 404


# ─────────────────────────────── пачка: ZIP ───────────────────────────────

ARCHIVE = {"Альфа/readme.md": b"alfa", "Альфа/src/a.py": b"print(1)", "Бета/readme.md": b"beta",
           "__MACOSX/Альфа/._readme.md": b"junk", "loose.txt": b"top-level file", ".hidden/x": b"h"}


def test_batch_archive_without_table_creates_a_submission_per_folder(app, client, project, tmp_path):
    data = zip_bytes(ARCHIVE)
    resp = post_batch(client, project["id"], archive=data)
    assert resp.status_code == 201, resp.text
    body = resp.json()
    assert [i["team_name"] for i in body["items"]] == ["Альфа", "Бета"] and body["rejected"] == []
    for item in body["items"]:
        material = rows(app, "SELECT * FROM material WHERE submission_id = :id", {"id": item["id"]})
        assert [(m["type"], m["source_kind"], m["status"]) for m in material] == [("archive", "upload", "available")]
        stored = tmp_path / "data" / material[0]["source_ref"]
        assert stored.read_bytes() == data       # архив не распаковывается API
        raw = (tmp_path / "data" / "projects" / project["id"] / "submissions" / item["id"] / "raw").resolve()
        assert stored.resolve().is_relative_to(raw)
    assert not any(p.name in {"readme.md", "a.py"} for p in stored_files(tmp_path))
    assert len(stored_files(tmp_path)) == 2         # временная копия архива удалена


def test_batch_table_and_archive_are_joined_by_team_name(app, client, project):
    table = csv_bytes(HEADER, "Альфа,https://github.com/a/alfa,,,", "Гамма,https://github.com/g/gamma,,,")
    resp = post_batch(client, project["id"], table, archive=zip_bytes(ARCHIVE))
    assert resp.status_code == 201, resp.text
    assert [i["team_name"] for i in resp.json()["items"]] == ["Альфа", "Гамма", "Бета"]
    assert types_by_team(app) == {"Альфа": ["archive", "repository"], "Гамма": ["repository"], "Бета": ["archive"]}


def test_batch_corrupt_archive_is_422_and_leaves_nothing(app, client, project, tmp_path):
    resp = post_batch(client, project["id"], archive=b"this is not a zip")
    assert resp.status_code == 422 and error_of(resp)["code"] == "invalid"
    assert rows(app, "SELECT id FROM submission") == [] and stored_files(tmp_path) == []


def test_batch_archive_without_folders_is_422(app, client, project, tmp_path):
    resp = post_batch(client, project["id"], archive=zip_bytes({"loose.txt": b"x"}))
    assert resp.status_code == 422
    assert rows(app, "SELECT id FROM submission") == [] and stored_files(tmp_path) == []


def test_batch_archive_is_linked_only_to_matching_teams(app, client, project, tmp_path):
    resp = post_batch(client, project["id"], csv_bytes("team_name", "Дельта"), archive=zip_bytes({"Другая/x.txt": b"x"}))
    assert resp.status_code == 201
    assert [i["team_name"] for i in resp.json()["items"]] == ["Дельта", "Другая"]
    assert types_by_team(app) == {"Другая": ["archive"]}       # у «Дельты» нет материалов
    assert len(stored_files(tmp_path)) == 1


def test_batch_archive_too_large_is_413(app, client, project, tmp_path, monkeypatch):
    from app.services import submissions
    monkeypatch.setattr(submissions, "MAX_ARCHIVE_BYTES", 100)
    resp = post_batch(client, project["id"], archive=zip_bytes({"A/x.txt": b"x" * 5000}))
    assert resp.status_code == 413
    assert rows(app, "SELECT id FROM submission") == [] and stored_files(tmp_path) == []
