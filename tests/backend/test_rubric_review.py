"""Находка ревью T027 (P0 про безопасность). Тест написан ДО правки (RED).

Перед запуском роли backend удаляет файл прошлого запуска ``projects/<id>/rubric-draft.json``; делать это через
символическую ссылку на каталог проекта нельзя: файл за пределами data_dir остаётся нетронутым.
"""
from __future__ import annotations

import json

import pytest
from test_rubric import PID, Env, draft_doc, run_build


@pytest.fixture
def env(tmp_path):
    e = Env(tmp_path)
    e.add_project()
    return e


def lazy_gateway(data_dir):
    from app.services.gateway import FakeAgentGateway, RoleResult

    class Lazy(FakeAgentGateway):
        async def run_role(self, run):
            return RoleResult(status="completed", hermes_run_id="x")

    return Lazy(data_dir)


def test_stale_draft_cleanup_does_not_follow_a_symlinked_project_directory(env):
    outside = env.tmp / "outside"
    outside.mkdir()
    victim = outside / "rubric-draft.json"
    victim.write_text(json.dumps(draft_doc()), encoding="utf-8")
    projects = env.data_dir / "projects"
    projects.mkdir()
    (projects / PID).symlink_to(outside, target_is_directory=True)
    result = run_build(env, lazy_gateway(env.data_dir))
    assert isinstance(result, str)
    assert victim.exists()
    assert env.versions() == []


def test_draft_inside_a_symlinked_project_directory_is_not_read(env):
    real = env.data_dir / "real"
    real.mkdir()
    (real / "rubric-draft.json").write_text(json.dumps(draft_doc()), encoding="utf-8")
    projects = env.data_dir / "projects"
    projects.mkdir()
    (projects / PID).symlink_to(real, target_is_directory=True)
    from app.services.gateway import FakeAgentGateway, RoleResult

    class Writes(FakeAgentGateway):
        async def run_role(self, run):
            return RoleResult(status="completed", hermes_run_id="x")

    result = run_build(env, Writes(env.data_dir))
    assert isinstance(result, str)
    assert env.versions() == []
