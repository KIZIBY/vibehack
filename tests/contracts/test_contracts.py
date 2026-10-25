"""Тесты контрактов платформы (задачи T011 и T013, спека 001-ai-judge-platform).

Проверяется:
  * каждая specs/001-ai-judge-platform/contracts/*.schema.json — валидная JSON Schema 2020-12;
  * contracts/openapi.yaml — валидный OpenAPI (включая относительную ссылку на journal-event.schema.json);
  * фикстуры tests/fixtures/<каталог>/*.json: файлы `invalid-*.json` обязаны НЕ проходить схему,
    остальные — проходить; состав фикстур и их согласованность зафиксированы константами ниже
    (это контракт с исполнителем, который пишет фикстуры).

Правила файла:
  * чистый python, без сети; время и случайность не используются;
  * отсутствие фикстуры — явный FAIL с понятным сообщением, а не ошибка коллекции и не skip
    (skip != pass: pytest.skip и importorskip не используются, параметры строятся как объединение
    «обязательные имена + найденные на диске файлы», чтобы набор параметров никогда не был пустым);
  * переменная окружения FIXTURES_DIR (необязательная) переопределяет каталог фикстур — нужна только
    для самопроверки логики на временном наборе файлов; по умолчанию tests/fixtures.
"""
from __future__ import annotations

import json
import os
import re
from datetime import datetime
from functools import lru_cache
from pathlib import Path

import pytest
import yaml
from jsonschema import Draft202012Validator, FormatChecker
from jsonschema.exceptions import ValidationError, best_match
from openapi_spec_validator import validate as validate_openapi

# ── пути ──
REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACTS_DIR = REPO_ROOT / "specs" / "001-ai-judge-platform" / "contracts"
OPENAPI_PATH = CONTRACTS_DIR / "openapi.yaml"
FIXTURES_DIR = Path(os.environ.get("FIXTURES_DIR") or (REPO_ROOT / "tests" / "fixtures")).resolve()

SCHEMA_2020_12 = "https://json-schema.org/draft/2020-12/schema"

# ── явное сопоставление «каталог фикстур -> схема» ──
FIXTURE_DIR_TO_SCHEMA = {
    "inventories": "inventory.schema.json",
    "agent-reports": "agent-report.schema.json",
    # документы kind=rubric_draft и kind=ux_metrics — ветки oneOf схемы agent-report
    "rubrics": "agent-report.schema.json",
    "journal": "journal-event.schema.json",
    "similarity": "similarity.schema.json",
}

# ── обязательный состав фикстур (контракт с исполнителем T013): каталог -> имена файлов ──
REQUIRED_FIXTURES = {
    "inventories": [
        "complete.json",
        "incomplete.json",
        "host-unavailable.json",
        "invalid-missing-completeness.json",
    ],
    "agent-reports": [
        "code.json",
        "business.json",
        "design.json",
        "critic-uniqueness.json",
        "critic-honesty.json",
        "no-data-and-flags.json",
        "invalid-scored-without-evidence.json",
        "invalid-no-data-without-reason.json",
        "invalid-unknown-role.json",
    ],
    "rubrics": [
        "rubric-draft.json",
        "ux-metrics.json",
        "invalid-rubric-empty-criteria.json",
    ],
    "journal": [
        "tool-call.json",
        "invalid-unknown-event.json",
    ],
    "similarity": [
        "pairs.json",
        "invalid-similarity-above-one.json",
    ],
}

ROLE_REPORTS = ["code", "business", "design", "critic-uniqueness", "critic-honesty"]
ALL_ROLES = set(ROLE_REPORTS)
INVALID_PREFIX = "invalid-"


# ── вспомогательные функции ──
def _rel(path: Path) -> str:
    """Путь для сообщений: относительно корня репозитория, иначе как есть (без путей машины)."""
    try:
        return path.relative_to(REPO_ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def _fixture_path(directory: str, name: str) -> Path:
    return FIXTURES_DIR / directory / name


def _fixture_id(directory: str, name: str) -> str:
    return f"{directory}/{name}"


def _discovered_fixtures() -> set[tuple[str, str]]:
    """Все .json в известных каталогах фикстур (rglob): пары (каталог, относительное имя)."""
    found: set[tuple[str, str]] = set()
    for directory in FIXTURE_DIR_TO_SCHEMA:
        base = FIXTURES_DIR / directory
        if base.is_dir():
            for path in base.rglob("*.json"):
                found.add((directory, path.relative_to(base).as_posix()))
    return found


def _all_fixture_params() -> list[tuple[str, str]]:
    """Обязательные + найденные на диске: набор никогда не пуст, отсутствующие дают понятный FAIL."""
    required = {(d, n) for d, names in REQUIRED_FIXTURES.items() for n in names}
    return sorted(required | _discovered_fixtures())


FIXTURE_PARAMS = _all_fixture_params()
FIXTURE_IDS = [_fixture_id(d, n) for d, n in FIXTURE_PARAMS]


def _is_invalid(name: str) -> bool:
    return Path(name).name.startswith(INVALID_PREFIX)


def _rfc3339_date_time(value: object) -> bool:
    """Строгая проверка date-time (RFC 3339) без зависимости от необязательного пакета rfc3339-validator."""
    if not isinstance(value, str):
        return True
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}[Tt ]\d{2}:\d{2}:\d{2}(\.\d+)?([Zz]|[+-]\d{2}:\d{2})", value):
        raise ValueError(f"не RFC 3339 date-time: {value!r}")
    datetime.fromisoformat(value.replace("z", "Z"))
    return True


def _format_checker() -> FormatChecker:
    checker = FormatChecker()
    checker.checks("date-time", raises=ValueError)(_rfc3339_date_time)
    return checker


FORMAT_CHECKER = _format_checker()


@lru_cache(maxsize=None)
def _load_schema(schema_name: str) -> dict:
    path = CONTRACTS_DIR / schema_name
    assert path.is_file(), f"схема контракта не найдена: {_rel(path)}"
    return json.loads(path.read_text(encoding="utf-8"))


def _validator(schema_name: str) -> Draft202012Validator:
    # Схемы грузятся файлом (не по $id); ссылки внутри — только локальные (#/$defs), registry не нужен
    # (это отдельно утверждает test_schema_refs_are_local).
    return Draft202012Validator(_load_schema(schema_name), format_checker=FORMAT_CHECKER)


def _load_fixture(directory: str, name: str):
    """Читает фикстуру; отсутствие и битый JSON — явный FAIL с путём файла."""
    path = _fixture_path(directory, name)
    assert path.is_file(), f"нет обязательной фикстуры {_rel(path)} (T013): создай файл"
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        pytest.fail(f"{_rel(path)}: не является корректным JSON: {exc}")


def _walk_refs(node: object):
    if isinstance(node, dict):
        for key, value in node.items():
            if key == "$ref" and isinstance(value, str):
                yield value
            else:
                yield from _walk_refs(value)
    elif isinstance(node, list):
        for item in node:
            yield from _walk_refs(item)


def _score_documents(directory: str = "agent-reports"):
    """Валидные (не invalid-*) документы kind=scores каталога: (имя, документ)."""
    names = sorted({n for d, n in _all_fixture_params() if d == directory and not _is_invalid(n)})
    for name in names:
        doc = _load_fixture(directory, name)
        if isinstance(doc, dict) and doc.get("kind") == "scores":
            yield name, doc


# ── 1. схемы контрактов ──
SCHEMA_FILES = sorted(CONTRACTS_DIR.glob("*.schema.json"))


def test_schema_files_found():
    """Glob находит схемы; все схемы из сопоставления фикстур присутствуют."""
    names = {p.name for p in SCHEMA_FILES}
    assert names, f"в {_rel(CONTRACTS_DIR)} нет ни одной *.schema.json"
    missing = sorted(set(FIXTURE_DIR_TO_SCHEMA.values()) - names)
    assert not missing, f"схемы из сопоставления фикстур не найдены в контрактах: {missing}"


@pytest.mark.parametrize("schema_path", SCHEMA_FILES, ids=lambda p: p.name)
def test_schema_is_valid_2020_12(schema_path: Path):
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    assert schema.get("$schema") == SCHEMA_2020_12, (
        f"{_rel(schema_path)}: $schema должен быть {SCHEMA_2020_12}, а не {schema.get('$schema')!r}"
    )
    Draft202012Validator.check_schema(schema)


@pytest.mark.parametrize("schema_path", SCHEMA_FILES, ids=lambda p: p.name)
def test_schema_refs_are_local(schema_path: Path):
    """Все $ref локальные (#/...): внешнему registry нечего резолвить."""
    schema = json.loads(schema_path.read_text(encoding="utf-8"))
    external = sorted({ref for ref in _walk_refs(schema) if not ref.startswith("#")})
    assert not external, f"{_rel(schema_path)}: нелокальные $ref {external} — валидация фикстур требует registry"


def test_format_checker_checks_date_time():
    """Формат date-time реально проверяется (иначе невалидные даты в фикстурах прошли бы молча)."""
    assert FORMAT_CHECKER.conforms("2026-01-02T03:04:05Z", "date-time")
    assert FORMAT_CHECKER.conforms("2026-01-02T03:04:05.123+03:00", "date-time")
    assert not FORMAT_CHECKER.conforms("вчера", "date-time")
    assert not FORMAT_CHECKER.conforms("2026-13-45T00:00:00Z", "date-time")


# ── 2. OpenAPI ──
def test_openapi_is_valid():
    assert OPENAPI_PATH.is_file(), f"нет {_rel(OPENAPI_PATH)}"
    spec = yaml.safe_load(OPENAPI_PATH.read_text(encoding="utf-8"))
    assert isinstance(spec, dict) and spec.get("openapi"), f"{_rel(OPENAPI_PATH)}: нет поля openapi"
    # base_uri нужен, чтобы относительная ссылка на journal-event.schema.json резолвилась из каталога контрактов
    validate_openapi(spec, base_uri=CONTRACTS_DIR.as_uri() + "/")


# ── 3. фикстуры: валидные проходят схему, invalid-* — падают ──
@pytest.mark.parametrize(("directory", "name"), FIXTURE_PARAMS, ids=FIXTURE_IDS)
def test_fixture_matches_schema(directory: str, name: str):
    schema_name = FIXTURE_DIR_TO_SCHEMA.get(directory)
    assert schema_name, f"каталог фикстур {directory!r} без записи в сопоставлении каталог->схема"
    path = _fixture_path(directory, name)
    doc = _load_fixture(directory, name)  # невалидный файл обязан быть корректным JSON
    validator = _validator(schema_name)
    if _is_invalid(name):
        try:
            validator.validate(doc)
        except ValidationError:
            return
        pytest.fail(f"{_rel(path)}: файл invalid-* прошёл валидацию по {schema_name}, а обязан её не пройти")
    error = best_match(validator.iter_errors(doc))
    assert error is None, (
        f"{_rel(path)}: не проходит {schema_name}: {error.message} "
        f"(путь в документе: {'/'.join(str(p) for p in error.absolute_path) or '<корень>'})"
    )


# ── 4. страж полноты каталога фикстур ──
# Каталоги зон B и C: исходные материалы для intake (архивы, PDF, репозитории) и рабочие каталоги агентского слоя.
# Это не фикстуры контрактов, схемами они не проверяются (docs/backlog.md B-014).
ZONE_FIXTURE_DIRS = frozenset({"submissions", "workspaces"})


def test_fixtures_dir_exists():
    assert FIXTURES_DIR.is_dir(), f"нет каталога фикстур {_rel(FIXTURES_DIR)} (T013)"


def test_no_unmapped_fixture_dirs():
    assert FIXTURES_DIR.is_dir(), f"нет каталога фикстур {_rel(FIXTURES_DIR)} (T013)"
    unmapped = sorted(p.name for p in FIXTURES_DIR.iterdir() if p.is_dir() and p.name not in FIXTURE_DIR_TO_SCHEMA
                      and p.name not in ZONE_FIXTURE_DIRS)
    assert not unmapped, (
        f"подкаталоги {_rel(FIXTURES_DIR)} без записи в сопоставлении каталог->схема: {unmapped}. "
        f"Добавь запись в FIXTURE_DIR_TO_SCHEMA (tests/contracts/test_contracts.py) или убери каталог"
    )


def test_fixtures_are_json_only():
    assert FIXTURES_DIR.is_dir(), f"нет каталога фикстур {_rel(FIXTURES_DIR)} (T013)"
    foreign = sorted(_rel(p) for p in FIXTURES_DIR.rglob("*")
                     if p.is_file() and p.suffix != ".json" and p.relative_to(FIXTURES_DIR).parts[0] not in ZONE_FIXTURE_DIRS)
    assert not foreign, f"в каталоге фикстур допустимы только *.json, найдено лишнее: {foreign}"


def test_no_fixture_files_outside_mapped_dirs():
    assert FIXTURES_DIR.is_dir(), f"нет каталога фикстур {_rel(FIXTURES_DIR)} (T013)"
    stray = sorted(_rel(p) for p in FIXTURES_DIR.iterdir() if p.is_file())
    assert not stray, f"файлы фикстур лежат вне каталогов из сопоставления: {stray}"


@pytest.mark.parametrize("directory", sorted(FIXTURE_DIR_TO_SCHEMA))
def test_fixture_dir_has_valid_file(directory: str):
    base = FIXTURES_DIR / directory
    assert base.is_dir(), f"нет каталога фикстур {_rel(base)} (T013)"
    schema_name = FIXTURE_DIR_TO_SCHEMA[directory]
    validator = _validator(schema_name)
    valid_files = sorted(p for p in base.rglob("*.json") if not p.name.startswith(INVALID_PREFIX))
    assert valid_files, f"в {_rel(base)} нет ни одного валидного (не invalid-*) файла фикстуры"
    passing = [p for p in valid_files if validator.is_valid(json.loads(p.read_text(encoding="utf-8")))]
    assert passing, f"в {_rel(base)} ни один файл не проходит {schema_name}"


def test_required_fixtures_present():
    """Сводка: все обязательные файлы на месте (одно сообщение со всем списком недостающих)."""
    missing = sorted(
        _rel(_fixture_path(d, n)) for d, names in REQUIRED_FIXTURES.items() for n in names
        if not _fixture_path(d, n).is_file()
    )
    assert not missing, f"отсутствуют обязательные фикстуры ({len(missing)}): {missing}"


# ── 5. содержательные требования к фикстурам (T013) ──
def test_inventory_complete():
    doc = _load_fixture("inventories", "complete.json")
    assert doc["completeness"]["status"] == "complete", "complete.json: completeness.status должен быть complete"
    assert doc["completeness"]["missing"] == [], "complete.json: completeness.missing должен быть пустым"


def test_inventory_incomplete():
    doc = _load_fixture("inventories", "incomplete.json")
    completeness = doc["completeness"]
    assert completeness["status"] == "incomplete", "incomplete.json: completeness.status должен быть incomplete"
    assert completeness["missing"], "incomplete.json: completeness.missing не должен быть пустым"
    not_available = [m for m in doc["materials"] if m.get("status") != "available"]
    assert not_available, "incomplete.json: нужен хотя бы один материал со статусом не available"


def test_inventory_host_unavailable():
    doc = _load_fixture("inventories", "host-unavailable.json")
    hosts = [m for m in doc["materials"] if m.get("type") == "host" and m.get("status") == "unavailable"]
    assert hosts, "host-unavailable.json: нужен материал type=host со статусом unavailable"
    assert any(str(m.get("reason", "")).strip() for m in hosts), (
        "host-unavailable.json: у недоступного host должна быть непустая reason"
    )


def test_inventory_invalid_has_no_completeness():
    doc = _load_fixture("inventories", "invalid-missing-completeness.json")
    assert isinstance(doc, dict) and "completeness" not in doc, (
        "invalid-missing-completeness.json: должен быть невалиден именно из-за отсутствия completeness"
    )


@pytest.mark.parametrize("role", ROLE_REPORTS)
def test_role_report_kind_and_role(role: str):
    doc = _load_fixture("agent-reports", f"{role}.json")
    assert doc.get("kind") == "scores", f"{role}.json: kind должен быть scores"
    assert doc.get("role") == role, f"{role}.json: поле role должно совпадать с именем файла ({role!r})"


def test_business_report_has_experts_with_scores():
    doc = _load_fixture("agent-reports", "business.json")
    assert doc.get("kind") == "scores", "business.json: kind должен быть scores"
    assert doc.get("role") == "business", "business.json: role должен быть business"
    experts = doc.get("experts")
    assert experts, "business.json: experts не должен быть пустым"
    for expert in experts:
        assert expert.get("scores"), f"business.json: у эксперта {expert.get('name')!r} нет scores"


def test_critic_honesty_has_claims_with_distinct_verdicts():
    doc = _load_fixture("agent-reports", "critic-honesty.json")
    assert doc.get("role") == "critic-honesty", "critic-honesty.json: role должен быть critic-honesty"
    claims = doc.get("claims")
    assert claims, "critic-honesty.json: claims не должен быть пустым"
    verdicts = {c.get("verdict") for c in claims}
    assert len(verdicts) >= 2, f"critic-honesty.json: нужно минимум два разных verdict, есть {sorted(verdicts)}"


def test_no_data_and_flags_report():
    doc = _load_fixture("agent-reports", "no-data-and-flags.json")
    assert doc.get("kind") == "scores", "no-data-and-flags.json: kind должен быть scores"
    no_data = [s for s in doc.get("scores", []) if s.get("status") == "no_data"]
    assert no_data, "no-data-and-flags.json: нужен score со status=no_data"
    assert all(str(s.get("no_data_reason", "")).strip() for s in no_data), (
        "no-data-and-flags.json: у каждого no_data-score должен быть непустой no_data_reason"
    )
    flags = doc.get("flags")
    assert flags, "no-data-and-flags.json: flags не должен быть пустым"
    types = {f.get("type") for f in flags}
    assert len(types) >= 2, f"no-data-and-flags.json: нужно минимум два разных type флага, есть {sorted(types)}"


def test_invalid_scored_without_evidence_is_invalid_for_declared_reason():
    doc = _load_fixture("agent-reports", "invalid-scored-without-evidence.json")
    scores = doc.get("scores", []) if isinstance(doc, dict) else []
    assert any(s.get("status") == "scored" and not s.get("evidence") for s in scores), (
        "invalid-scored-without-evidence.json: нужен score status=scored без evidence (отсутствует или пустой)"
    )


def test_invalid_no_data_without_reason_is_invalid_for_declared_reason():
    doc = _load_fixture("agent-reports", "invalid-no-data-without-reason.json")
    scores = doc.get("scores", []) if isinstance(doc, dict) else []
    assert any(s.get("status") == "no_data" and "no_data_reason" not in s for s in scores), (
        "invalid-no-data-without-reason.json: нужен score status=no_data без поля no_data_reason"
    )


def test_invalid_unknown_role_is_invalid_for_declared_reason():
    doc = _load_fixture("agent-reports", "invalid-unknown-role.json")
    assert isinstance(doc, dict) and doc.get("role") not in ALL_ROLES, (
        "invalid-unknown-role.json: role должен быть вне списка code/business/design/critic-uniqueness/critic-honesty"
    )


def test_rubric_draft():
    doc = _load_fixture("rubrics", "rubric-draft.json")
    assert doc.get("kind") == "rubric_draft", "rubric-draft.json: kind должен быть rubric_draft"
    criteria = doc.get("criteria", [])
    assert len(criteria) == 5, f"rubric-draft.json: критериев должно быть ровно 5, а не {len(criteria)}"
    agents = {c.get("agent") for c in criteria}
    assert agents == ALL_ROLES, (
        f"rubric-draft.json: agent должны покрывать роли {sorted(ALL_ROLES)}, а покрывают {sorted(map(str, agents))}"
    )


def test_ux_metrics():
    doc = _load_fixture("rubrics", "ux-metrics.json")
    assert doc.get("kind") == "ux_metrics", "ux-metrics.json: kind должен быть ux_metrics"


def test_invalid_rubric_empty_criteria_is_invalid_for_declared_reason():
    doc = _load_fixture("rubrics", "invalid-rubric-empty-criteria.json")
    assert isinstance(doc, dict) and doc.get("kind") == "rubric_draft" and doc.get("criteria") == [], (
        "invalid-rubric-empty-criteria.json: нужен kind=rubric_draft с criteria=[]"
    )


def test_journal_tool_call():
    doc = _load_fixture("journal", "tool-call.json")
    assert doc.get("event") == "tool_call", "tool-call.json: event должен быть tool_call"


def test_invalid_journal_unknown_event_is_invalid_for_declared_reason():
    doc = _load_fixture("journal", "invalid-unknown-event.json")
    schema_events = set(_load_schema("journal-event.schema.json")["properties"]["event"]["enum"])
    assert isinstance(doc, dict) and doc.get("event") not in schema_events, (
        "invalid-unknown-event.json: event должен быть вне enum схемы журнала"
    )


def test_similarity_pairs():
    doc = _load_fixture("similarity", "pairs.json")
    pairs = doc.get("pairs", [])
    assert any(p.get("fragments") for p in pairs), "pairs.json: нужна минимум одна пара с непустыми fragments"


def test_invalid_similarity_above_one_is_invalid_for_declared_reason():
    doc = _load_fixture("similarity", "invalid-similarity-above-one.json")
    pairs = doc.get("pairs", []) if isinstance(doc, dict) else []
    assert any(
        isinstance(p.get("similarity"), (int, float)) and p["similarity"] > 1 for p in pairs
    ), "invalid-similarity-above-one.json: нужна пара с similarity > 1"


# ── 6. согласованность фикстур между каталогами ──
def test_agent_reports_share_submission_id_with_inventory():
    expected = _load_fixture("inventories", "complete.json")["submission_id"]
    checked = 0
    for name, doc in _score_documents():
        checked += 1
        assert doc.get("submission_id") == expected, (
            f"agent-reports/{name}: submission_id {doc.get('submission_id')!r} "
            f"не совпадает с inventories/complete.json ({expected!r})"
        )
    assert checked >= len(ROLE_REPORTS), f"ожидались score-документы ролей, найдено лишь {checked}"


@pytest.mark.parametrize("name", ["rubric-draft.json", "ux-metrics.json"])
def test_rubrics_share_project_id_with_inventory(name: str):
    expected = _load_fixture("inventories", "complete.json")["project_id"]
    doc = _load_fixture("rubrics", name)
    assert doc.get("project_id") == expected, (
        f"rubrics/{name}: project_id {doc.get('project_id')!r} не совпадает с inventories/complete.json ({expected!r})"
    )


# ─────────────────────────────── agent-run.md: scope отчёта и сессии ───────────────────────────────

def _agent_run_text() -> str:
    return re.sub(r"\s+", " ", (CONTRACTS_DIR / "agent-run.md").read_text(encoding="utf-8"))


def test_agent_run_fixes_scope_formats():
    text = _agent_run_text()
    for fragment in ('"session_id": "<run_id>:<role>:<scope>"', "`Idempotency-Key: <run_id>:<role>:<scope>:<attempt>`",
                     "reports/<role>__<scope>.json", "`project`"):
        assert fragment in text, fragment
    assert "reports/<role>.json" not in text


def test_agent_run_takes_run_id_role_and_scope_from_session_not_from_model_arguments():
    """Аргументы инструмента заполняет модель, читающая материалы участников: путь отчёта нельзя строить из них."""
    text = _agent_run_text()
    assert "вычисляет его из аргументов инструмента" not in text
    assert "только из `session_id`" in text
    assert "`report_rejected`" in text and "не совпада" in text
