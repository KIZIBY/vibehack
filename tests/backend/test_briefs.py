"""T025 (остаток): вводные материалы — ``GET``/``POST /api/v1/projects/{id}/briefs`` и фоновое извлечение текста.
Тесты написаны ДО реализации (RED): ``backend/app/{routers,services,repositories}/briefs.py`` ещё нет.

Контракт (contracts/openapi.yaml ``listBriefs``/``uploadBriefs``, schema ``Brief``, задание T025):
- ``GET`` — ``{"items": [Brief…]}``, новые сверху; 404, если проекта нет или он удалён;
- ``POST`` (multipart: ``files`` — несколько файлов, ``links`` — JSON-массив URL строкой) — 201 ``{"items": [...]}``;
  файл сохраняется потоково через ``Storage.save_upload(project_id, "briefs", …)``: строка ``brief``
  (``source=upload``, ``status=processing``, ``path`` — относительный путь, ``name`` — безопасное имя);
  ссылка проходит ``validate_public_url`` — любая небезопасная → весь запрос 422 до сохранения чего-либо;
  строка ``brief`` ссылки: ``source=url``, ``name`` = URL, сразу ``status=extracted``, ``extracted_text_path`` NULL,
  ``reason`` = «ссылка сохранена без извлечения»; не более ``MAX_FILES`` = 20 файлов и ``MAX_LINKS`` = 20 ссылок
  (иначе 422); пустой запрос → 422; размер файла ограничен ``MAX_FILE_BYTES`` (100 МБ, считается на лету) → 413
  без остатков на диске и без строк в БД (в том числе для файлов того же запроса, сохранённых раньше); вызывает
  ``touch_project``;
- после ответа (``BackgroundTasks``) для файла запускается ``get_intake_runner(app).run(<каталог материала>,
  <каталог материала>/extracted)``; первая запись описи с ``extracted.text_path`` → ``brief.extracted_text_path``
  (относительный путь внутри каталога результата), статус ``extracted``; иначе ``failed`` и короткая ``reason``
  без путей машины и без stderr; затем системное сообщение ``brief_extracted`` («<имя>: текст извлечён» /
  «<имя>: не удалось извлечь материал») и событие ``message.created`` {message_id};
- ответы не содержат абсолютных путей машины и поля ``path``.

Допущения (выбраны тестом): константы лимитов живут в ``app.services.briefs``; фоновые задачи ``TestClient``
выполняет до возврата ответа, поэтому итог извлечения виден сразу после ``client.post``; для ссылок сообщение
в чат не публикуется (ничего не извлекалось).
Все импорты ``app`` — внутри функций: без реализации тесты FAILED, а не ERROR.
"""
from __future__ import annotations

import json
import os
import re
import sys
import textwrap
from pathlib import Path

import pytest
import sqlalchemy as sa

from test_projects import PROJECTS, assert_matches, db_value, error_of, make_app, make_client, parse_dt, sql

MB = 1024 * 1024
PUBLIC_LINK = "https://93.184.216.34/brief.pdf"
PUBLIC_LINK_2 = "http://93.184.216.35/rules"
UNSAFE_LINKS = ["http://127.0.0.1/admin", "http://169.254.169.254/latest/meta-data", "ftp://93.184.216.34/x",
                "http://10.0.0.5/x", "javascript:alert(1)"]
LINK_REASON = "ссылка сохранена без извлечения"
STDERR_MARK = "SECRET-STDERR-MARK-7731"


def url(project_id: str, suffix: str = "briefs") -> str:
    return f"{PROJECTS}/{project_id}/{suffix}"


# ─────────────────────────────── фейковый intake ───────────────────────────────

FAKE_TEMPLATE = '''
import json, os, sys
from pathlib import Path
MODE = %r
sub = Path(sys.argv[1])
assert sys.argv[2] == "--out"
out = Path(sys.argv[3])
out.mkdir(parents=True, exist_ok=True)
rel_dir = "/".join(out.parts[-5:])          # projects/<pid>/briefs/<material>/extracted
if MODE == "crash":
    sys.stderr.write("Traceback " + str(sub) + " " + %r + "\\n")
    sys.exit(3)
uploaded = sorted(p for p in sub.iterdir() if p.is_file())
src = uploaded[0]
extracted = {}
if MODE == "ok":
    (out / "text.txt").write_text("EXTRACTED:" + src.read_text(encoding="utf-8", errors="replace"), encoding="utf-8")
    extracted = {"text_path": rel_dir + "/text.txt"}
elif MODE == "no_text":
    extracted = {"slide_count": 0}
elif MODE == "outside_rel":
    extracted = {"text_path": "../../../../../../../../etc/hosts"}
elif MODE == "outside_abs":
    extracted = {"text_path": "/etc/hosts"}
elif MODE == "other_project":
    extracted = {"text_path": "projects/other/briefs/x/extracted/text.txt"}
elif MODE == "not_in_extracted":
    extracted = {"text_path": rel_dir[: -len("/extracted")] + "/" + src.name}
elif MODE == "missing_file":
    extracted = {"text_path": rel_dir + "/nope.txt"}
elif MODE == "symlink":
    os.symlink("/etc/hosts", out / "text.txt")
    extracted = {"text_path": rel_dir + "/text.txt"}
elif MODE == "second_material":
    (out / "text.txt").write_text("SECOND", encoding="utf-8")
    extracted = None
material = {"material_id": "m1", "type": "document", "source": {"kind": "upload", "path": src.name},
            "status": "available"}
materials = [material]
if extracted:
    material["extracted"] = extracted
if MODE == "second_material":
    materials = [material, {"material_id": "m2", "type": "document", "source": {"kind": "upload", "path": src.name},
                            "status": "available", "extracted": {"text_path": rel_dir + "/text.txt"}}]
inventory = {"schema_version": "1", "submission_id": "b", "project_id": "p", "team_name": "t",
             "created_at": "2026-10-25T10:00:00Z", "materials": materials,
             "completeness": {"status": "complete", "required": [], "missing": []}}
(out / "inventory.json").write_text(json.dumps(inventory), encoding="utf-8")
'''


def install_intake(app, tmp_path: Path, mode: str = "ok"):
    from app.services.intake_runner import IntakeRunner
    script = tmp_path / f"fake_intake_{mode}.py"
    script.write_text(FAKE_TEMPLATE % (mode, STDERR_MARK), encoding="utf-8")
    app.state.intake_runner = IntakeRunner(command=[sys.executable, str(script)], timeout=60)


class SpyBus:
    """Шина событий, запоминающая публикации (интерфейс ``publish(project_id, type, data)``)."""

    def __init__(self):
        self.events: list[tuple[str, str, dict]] = []

    def publish(self, project_id, event_type, data):
        self.events.append((project_id, event_type, data))
        return len(self.events)


# ─────────────────────────────── фикстуры и помощники ───────────────────────────────

@pytest.fixture
def app(tmp_path):
    application = make_app(tmp_path, JUDGE_DATA_DIR=str(tmp_path / "data"))
    application.state.event_bus = SpyBus()
    install_intake(application, tmp_path)
    return application


@pytest.fixture
def client(app):
    with make_client(app) as c:
        yield c


def data_dir(app) -> Path:
    return Path(app.state.settings.data_dir)


def all_files(app) -> list[Path]:
    root = data_dir(app)
    return sorted(p for p in root.rglob("*") if p.is_file()) if root.exists() else []


def seed_project(app, name: str = "Хакатон", status: str = "setup") -> str:
    from app.common import new_id, utc_now_iso
    project_id, now = new_id(), utc_now_iso()
    sql(app, "INSERT INTO project (id, name, type, status, agents, required_materials, retention_days, "
             "last_activity_at, version, created_at, updated_at) "
             "VALUES (:id, :name, 'other', :status, '[]', '[]', 7, :t, 1, :t, :t)",
        {"id": project_id, "name": name, "status": status, "t": now})
    return project_id


@pytest.fixture
def pid(app):
    return seed_project(app)


def brief_rows(app, project_id: str | None = None) -> list[dict]:
    query = "SELECT * FROM brief" + (" WHERE project_id = :p" if project_id else "") + " ORDER BY created_at, id"
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(sa.text(query), {"p": project_id} if project_id else {}).mappings()]


def messages_of(app, project_id: str) -> list[dict]:
    with app.state.engine.connect() as conn:
        return [dict(r) for r in conn.execute(
            sa.text("SELECT * FROM message WHERE project_id = :p ORDER BY created_at, id"), {"p": project_id}).mappings()]


def upload(client, project_id: str, files=(), links=None, **kwargs):
    parts = [("files", (name, content, "application/octet-stream")) for name, content in files]
    data = {} if links is None else {"links": links if isinstance(links, str) else json.dumps(links)}
    return client.post(url(project_id), files=parts or None, data=data or None, **kwargs)


def one_file(client, project_id: str, name: str = "Положение.txt", content: bytes = "Критерии оценки".encode()):
    resp = upload(client, project_id, [(name, content)])
    assert resp.status_code == 201, (resp.status_code, resp.text)
    return resp.json()["items"][0]


def insert_brief(app, project_id: str, name: str, created_at: str, *, deleted_at: str | None = None,
                 source: str = "upload", status: str = "extracted") -> str:
    from app.common import new_id
    brief_id = new_id()
    sql(app, "INSERT INTO brief (id, project_id, name, source, status, created_at, deleted_at) "
             "VALUES (:id, :p, :name, :source, :status, :t, :d)",
        {"id": brief_id, "p": project_id, "name": name, "source": source, "status": status, "t": created_at,
         "d": deleted_at})
    return brief_id


# ─────────────────────────────── доступ ───────────────────────────────

@pytest.mark.parametrize("method", ["get", "post"])
def test_briefs_require_session(app, method):
    with make_client(app, authorized=False) as anonymous:
        resp = getattr(anonymous, method)(url("X"))
    assert resp.status_code == 401


# ─────────────────────────────── GET ───────────────────────────────

def test_get_empty_list(client, pid):
    resp = client.get(url(pid))
    assert resp.status_code == 200
    assert resp.json() == {"items": []}


def test_get_unknown_project_is_404_in_error_format(client):
    resp = client.get(url("NOPE"))
    assert resp.status_code == 404
    assert error_of(resp)["code"] == "not_found"


def test_get_soft_deleted_project_is_404(app, client, pid):
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": pid})
    assert client.get(url(pid)).status_code == 404


def test_get_lists_newest_first_matching_schema_and_hides_other_projects_and_deleted(app, client, pid):
    other = seed_project(app, "Чужой")
    a = insert_brief(app, pid, "a.txt", "2026-10-25T10:00:00.000001+00:00")
    b = insert_brief(app, pid, "b.txt", "2026-10-25T10:00:00.000003+00:00")
    c = insert_brief(app, pid, "c.txt", "2026-10-25T10:00:00.000002+00:00")
    insert_brief(app, pid, "gone.txt", "2026-10-25T10:00:00.000009+00:00", deleted_at="2026-10-25T11:00:00+00:00")
    insert_brief(app, other, "foreign.txt", "2026-10-25T10:00:00.000005+00:00")
    body = client.get(url(pid)).json()
    assert [item["id"] for item in body["items"]] == [b, c, a]
    for item in body["items"]:
        assert_matches("Brief", item)
        assert set(item) <= {"id", "name", "source", "status", "reason"}


def test_get_response_includes_reason_only_when_present(app, client, pid):
    brief_id = insert_brief(app, pid, "x.txt", "2026-10-25T10:00:00+00:00", status="failed")
    sql(app, "UPDATE brief SET reason = :r WHERE id = :id", {"r": "не удалось", "id": brief_id})
    insert_brief(app, pid, "y.txt", "2026-10-25T10:00:01+00:00")
    items = {i["name"]: i for i in client.get(url(pid)).json()["items"]}
    assert items["x.txt"]["reason"] == "не удалось"
    assert "reason" not in items["y.txt"]


# ─────────────────────────────── POST: файлы ───────────────────────────────

def test_post_file_returns_201_with_processing_brief_and_stores_row_and_file(app, client, pid):
    resp = upload(client, pid, [("Положение.txt", "Критерии оценки".encode())])
    assert resp.status_code == 201
    items = resp.json()["items"]
    assert len(items) == 1
    item = items[0]
    assert_matches("Brief", item)
    assert (item["name"], item["source"], item["status"]) == ("Положение.txt", "upload", "processing")
    row = next(r for r in brief_rows(app, pid) if r["id"] == item["id"])
    assert row["source"] == "upload" and row["name"] == "Положение.txt"
    assert re.fullmatch(rf"projects/{pid}/briefs/[A-Za-z0-9_-]+/Положение\.txt", row["path"])
    assert (data_dir(app) / row["path"]).read_bytes() == "Критерии оценки".encode()


def test_post_response_has_no_machine_paths_or_path_field(app, client, pid, tmp_path):
    resp = upload(client, pid, [("a.txt", b"x")], links=[PUBLIC_LINK])
    assert resp.status_code == 201
    assert str(tmp_path) not in resp.text
    for item in resp.json()["items"]:
        assert "path" not in item and "extracted_text_path" not in item


def test_post_several_files_creates_a_brief_for_each_in_request_order(app, client, pid):
    resp = upload(client, pid, [("one.txt", b"1"), ("two.txt", b"2"), ("three.md", b"3")])
    assert resp.status_code == 201
    items = resp.json()["items"]
    assert [i["name"] for i in items] == ["one.txt", "two.txt", "three.md"]
    assert len({i["id"] for i in items}) == 3
    assert len(brief_rows(app, pid)) == 3
    assert len({r["path"] for r in brief_rows(app, pid)}) == 3


def test_post_traversal_filename_is_stored_inside_project_directory(app, client, pid, tmp_path):
    resp = upload(client, pid, [("../../../evil.txt", b"boom")])
    assert resp.status_code == 201
    item = resp.json()["items"][0]
    assert item["name"] == "evil.txt"
    row = brief_rows(app, pid)[0]
    saved = (data_dir(app) / row["path"]).resolve()
    assert saved.is_relative_to((data_dir(app) / "projects" / pid / "briefs").resolve())
    assert saved.read_bytes() == b"boom"
    assert not (tmp_path / "evil.txt").exists() and not (tmp_path.parent / "evil.txt").exists()


def test_post_same_filename_twice_makes_two_independent_materials(app, client, pid):
    upload(client, pid, [("a.txt", b"first")])
    upload(client, pid, [("a.txt", b"second")])
    rows = brief_rows(app, pid)
    assert len(rows) == 2 and rows[0]["path"] != rows[1]["path"]
    assert sorted((data_dir(app) / r["path"]).read_bytes() for r in rows) == [b"first", b"second"]


def test_post_touches_project_without_changing_version(app, client, pid):
    old = "2020-01-01T00:00:00.000000+00:00"
    sql(app, "UPDATE project SET last_activity_at = :t WHERE id = :id", {"t": old, "id": pid})
    assert upload(client, pid, [("a.txt", b"x")]).status_code == 201
    assert parse_dt(db_value(app, "last_activity_at", pid)) > parse_dt(old)
    assert db_value(app, "version", pid) == 1


def test_post_unknown_project_is_404_and_saves_nothing(app, client):
    resp = upload(client, "NOPE", [("a.txt", b"x")])
    assert resp.status_code == 404
    assert all_files(app) == [] and brief_rows(app) == []


def test_post_soft_deleted_project_is_404(app, client, pid):
    sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id", {"t": "2026-10-25T00:00:00+00:00", "id": pid})
    assert upload(client, pid, [("a.txt", b"x")]).status_code == 404
    assert all_files(app) == []


# ─────────────────────────────── POST: лимиты и проверки ───────────────────────────────

def test_limits_are_documented_constants():
    from app.services import briefs
    assert briefs.MAX_FILE_BYTES == 100 * MB
    assert briefs.MAX_FILES == 20 and briefs.MAX_LINKS == 20


def test_post_file_over_limit_is_413_without_leftovers(app, client, pid, monkeypatch):
    from app.services import briefs
    monkeypatch.setattr(briefs, "MAX_FILE_BYTES", 1024)
    resp = upload(client, pid, [("big.bin", b"x" * 2048)])
    assert resp.status_code == 413
    assert error_of(resp)["code"] == "too_large"
    assert all_files(app) == [] and brief_rows(app) == []


def test_post_file_exactly_at_limit_is_accepted(app, client, pid, monkeypatch):
    from app.services import briefs
    monkeypatch.setattr(briefs, "MAX_FILE_BYTES", 1024)
    assert upload(client, pid, [("edge.bin", b"x" * 1024)]).status_code == 201


def test_post_oversized_second_file_rolls_back_the_first(app, client, pid, monkeypatch):
    from app.services import briefs
    monkeypatch.setattr(briefs, "MAX_FILE_BYTES", 1024)
    resp = upload(client, pid, [("small.txt", b"ok"), ("big.bin", b"x" * 4096)], links=[PUBLIC_LINK])
    assert resp.status_code == 413
    assert all_files(app) == [], "файл, сохранённый раньше в том же запросе, не должен остаться на диске"
    assert brief_rows(app) == []
    assert messages_of(app, pid) == []


def test_post_limit_counts_actual_bytes_not_declared_length(app, client, pid, monkeypatch):
    from app.services import briefs
    monkeypatch.setattr(briefs, "MAX_FILE_BYTES", 1024)
    body = (b"--B\r\nContent-Disposition: form-data; name=\"files\"; filename=\"liar.bin\"\r\n"
            b"Content-Type: application/octet-stream\r\n\r\n" + b"x" * 5000 + b"\r\n--B--\r\n")
    resp = client.post(url(pid), content=body, headers={"Content-Type": "multipart/form-data; boundary=B"})
    assert resp.status_code == 413
    assert all_files(app) == [] and brief_rows(app) == []


def test_post_empty_request_is_422(app, client, pid):
    resp = client.post(url(pid))
    assert resp.status_code == 422
    assert error_of(resp)["code"] == "invalid"
    assert brief_rows(app) == []


@pytest.mark.parametrize("links", ["[]", "  [ ] "])
def test_post_empty_links_array_is_422(client, pid, links):
    assert upload(client, pid, links=links).status_code == 422


def test_post_too_many_files_is_422_and_saves_nothing(app, client, pid):
    ok = [(f"f{i}.txt", b"x") for i in range(20)]
    assert upload(client, pid, ok).status_code == 201
    before_files, before_rows = len(all_files(app)), len(brief_rows(app))
    resp = upload(client, pid, ok + [("f20.txt", b"x")])
    assert resp.status_code == 422
    assert len(all_files(app)) == before_files and len(brief_rows(app)) == before_rows


def test_post_too_many_links_is_422_and_saves_nothing(app, client, pid):
    links = [f"https://93.184.216.34/p{i}" for i in range(21)]
    resp = upload(client, pid, [("a.txt", b"x")], links=links)
    assert resp.status_code == 422
    assert all_files(app) == [] and brief_rows(app) == []
    assert upload(client, pid, links=links[:20]).status_code == 201


@pytest.mark.parametrize("links", ["not json", "{\"a\": 1}", "\"https://93.184.216.34/\"", "[1, 2]", "[null]",
                                   "[\"\"]", "[[\"https://93.184.216.34/\"]]"])
def test_post_malformed_links_field_is_422(app, client, pid, links):
    resp = upload(client, pid, [("a.txt", b"x")], links=links)
    assert resp.status_code == 422
    assert error_of(resp)["code"] == "invalid"
    assert all_files(app) == [] and brief_rows(app) == []


@pytest.mark.parametrize("bad", UNSAFE_LINKS)
def test_post_unsafe_link_rejects_whole_request_before_saving_anything(app, client, pid, bad):
    resp = upload(client, pid, [("a.txt", b"x")], links=[PUBLIC_LINK, bad])
    assert resp.status_code == 422
    assert error_of(resp)["code"] == "invalid"
    assert all_files(app) == [] and brief_rows(app) == []
    assert messages_of(app, pid) == []


# ─────────────────────────────── POST: ссылки ───────────────────────────────

def test_post_links_create_extracted_briefs_without_text(app, client, pid):
    resp = upload(client, pid, links=[PUBLIC_LINK, PUBLIC_LINK_2])
    assert resp.status_code == 201
    items = resp.json()["items"]
    assert [i["name"] for i in items] == [PUBLIC_LINK, PUBLIC_LINK_2]
    for item in items:
        assert_matches("Brief", item)
        assert (item["source"], item["status"], item["reason"]) == ("url", "extracted", LINK_REASON)
    rows = brief_rows(app, pid)
    assert all(r["source"] == "url" and r["extracted_text_path"] is None and r["path"] is None for r in rows)
    assert all_files(app) == []


def test_post_files_and_links_together_files_first(app, client, pid):
    resp = upload(client, pid, [("a.txt", b"x")], links=[PUBLIC_LINK])
    assert resp.status_code == 201
    assert [(i["source"], i["name"]) for i in resp.json()["items"]] == [("upload", "a.txt"), ("url", PUBLIC_LINK)]


def test_post_link_is_stored_normalized(client, pid):
    resp = upload(client, pid, links=["HTTPS://93.184.216.34"])
    assert resp.status_code == 201
    assert resp.json()["items"][0]["name"] == "https://93.184.216.34/"


def test_post_links_do_not_publish_chat_messages(app, client, pid):
    upload(client, pid, links=[PUBLIC_LINK])
    assert messages_of(app, pid) == []
    assert app.state.event_bus.events == []


# ─────────────────────────────── фоновое извлечение ───────────────────────────────

def test_extraction_success_updates_row_and_listing(app, client, pid):
    item = one_file(client, pid, "Положение.txt", "Критерии оценки".encode())
    row = next(r for r in brief_rows(app, pid) if r["id"] == item["id"])
    assert row["status"] == "extracted" and row["reason"] is None
    material_dir = row["path"].rsplit("/", 1)[0]
    assert row["extracted_text_path"] == f"{material_dir}/extracted/text.txt"
    assert (data_dir(app) / row["extracted_text_path"]).read_text(encoding="utf-8") == "EXTRACTED:Критерии оценки"
    listed = client.get(url(pid)).json()["items"]
    assert [(i["id"], i["status"]) for i in listed] == [(item["id"], "extracted")]


def test_extraction_posts_system_message_and_publishes_event(app, client, pid):
    one_file(client, pid, "Положение.txt")
    messages = messages_of(app, pid)
    assert len(messages) == 1
    assert (messages[0]["author"], messages[0]["kind"], messages[0]["text"]) == (
        "system", "brief_extracted", "Положение.txt: текст извлечён")
    assert app.state.event_bus.events == [(pid, "message.created", {"message_id": messages[0]["id"]})]
    listed = client.get(f"{PROJECTS}/{pid}/messages").json()["items"]
    assert [m["kind"] for m in listed] == ["brief_extracted"]


def test_extraction_runs_per_file_on_its_own_material_directory(app, client, pid):
    resp = upload(client, pid, [("a.txt", b"AAA"), ("b.txt", b"BBB")])
    assert resp.status_code == 201
    rows = {r["name"]: r for r in brief_rows(app, pid)}
    assert (data_dir(app) / rows["a.txt"]["extracted_text_path"]).read_text(encoding="utf-8") == "EXTRACTED:AAA"
    assert (data_dir(app) / rows["b.txt"]["extracted_text_path"]).read_text(encoding="utf-8") == "EXTRACTED:BBB"
    assert {m["text"] for m in messages_of(app, pid)} == {"a.txt: текст извлечён", "b.txt: текст извлечён"}


def test_extraction_takes_first_material_with_text_path(app, client, pid, tmp_path):
    install_intake(app, tmp_path, "second_material")
    one_file(client, pid)
    row = brief_rows(app, pid)[0]
    assert row["status"] == "extracted"
    assert row["extracted_text_path"].endswith("/extracted/text.txt")


@pytest.mark.parametrize("mode", ["crash", "no_text", "outside_rel", "outside_abs", "other_project",
                                  "not_in_extracted", "missing_file", "symlink"])
def test_extraction_failure_marks_brief_failed_with_safe_reason(app, client, pid, tmp_path, mode):
    install_intake(app, tmp_path, mode)
    item = one_file(client, pid, "Положение.txt")
    row = next(r for r in brief_rows(app, pid) if r["id"] == item["id"])
    assert row["status"] == "failed", mode
    assert row["extracted_text_path"] is None
    reason = row["reason"]
    assert reason and len(reason) <= 200
    assert STDERR_MARK not in reason and str(tmp_path) not in reason and "Traceback" not in reason
    assert "/" not in reason
    messages = messages_of(app, pid)
    assert [(m["kind"], m["text"]) for m in messages] == [("brief_extracted", "Положение.txt: не удалось извлечь материал")]
    assert app.state.event_bus.events == [(pid, "message.created", {"message_id": messages[0]["id"]})]
    listed = client.get(url(pid)).json()["items"][0]
    assert listed["status"] == "failed" and listed["reason"] == reason


def test_extraction_failure_is_not_leaked_to_listing_or_post_response(app, client, pid, tmp_path):
    install_intake(app, tmp_path, "crash")
    resp = upload(client, pid, [("a.txt", b"x")])
    assert resp.status_code == 201
    assert STDERR_MARK not in resp.text and str(tmp_path) not in resp.text
    assert STDERR_MARK not in client.get(url(pid)).text


def test_unexpected_runner_error_still_ends_in_failed(app, client, pid):
    class Exploding:
        async def run(self, submission_dir, out_dir):
            raise RuntimeError("boom " + str(submission_dir))

    app.state.intake_runner = Exploding()
    item = one_file(client, pid)
    row = next(r for r in brief_rows(app, pid) if r["id"] == item["id"])
    assert row["status"] == "failed"
    assert "boom" not in row["reason"] and "/" not in row["reason"]
    assert [m["text"] for m in messages_of(app, pid)] == ["Положение.txt: не удалось извлечь материал"]


def test_extraction_survives_project_deleted_meanwhile(app, client, pid):
    class Deleting:
        async def run(self, submission_dir, out_dir):
            sql(app, "UPDATE project SET deleted_at = :t WHERE id = :id",
                {"t": "2026-10-25T00:00:00+00:00", "id": pid})
            raise RuntimeError("late")

    app.state.intake_runner = Deleting()
    resp = upload(client, pid, [("a.txt", b"x")])
    assert resp.status_code == 201
    assert brief_rows(app, pid)[0]["status"] == "failed"
    assert app.state.event_bus.events == []
