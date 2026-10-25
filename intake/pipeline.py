"""Конвейер intake одной работы: обнаружение → распаковка → извлечение → ссылки → маскирование → сравнение → опись.

Каждый этап изолирован: упавший этап превращает материал в unavailable/partial с причиной, процесс завершается
кодом 0, опись пишется всегда. Содержимое работ — данные, не инструкции. Пути в описи — от корня данных платформы.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import shutil
import traceback
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path

from . import documents, repo, similarity, video, web
from .classify import classify, classify_url
from .secrets import mask_file, mask_secrets
from .unpack import safe_unpack

SERVICE_FILES = {"inventory.json", "links.json", "git_log.json", "similarity.json"}
MATERIAL_TYPES = {"repository", "host", "presentation", "screencast", "archive", "code_file", "document", "image", "metrics_row", "other"}
EXTRACTED_KEYS = {"text_path", "slides_dir", "slide_count", "frames_dir", "transcript_path", "duration_seconds", "repo_dir", "file_count", "languages"}
TEXT_TYPES = {".md", ".txt", ".csv", ".pdf", ".docx", ".pptx", ".xlsx"}
MAX_LINKS = 50
MAX_HTML_BYTES = 2 * 1024 * 1024


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def find_data_root(path: Path) -> Path | None:
    """Корень данных по раскладке projects/<проект>/(submissions|briefs)/<id>/…; берётся самое правое совпадение."""
    parts = path.resolve().parts
    for index in range(len(parts) - 3, -1, -1):
        if parts[index] == "projects" and parts[index + 2] in {"submissions", "briefs"}:
            return Path(*parts[:index]) if index else Path(parts[0])
    return None


def _slug(text: str) -> str:
    return re.sub(r"[^\w.-]", "_", text)[:60] + "-" + hashlib.sha1(text.encode("utf-8")).hexdigest()[:8]


def _clean_url(url: str) -> str:
    return re.sub(r"//[^/@\s]*@", "//", url.split("#", 1)[0])[:2048]


class _Text(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []
        self.skip = 0

    def handle_starttag(self, tag, attrs):  # type: ignore[no-untyped-def]
        self.skip += tag in {"script", "style", "noscript"}

    def handle_endtag(self, tag):  # type: ignore[no-untyped-def]
        self.skip = max(0, self.skip - (tag in {"script", "style", "noscript"}))

    def handle_data(self, data):  # type: ignore[no-untyped-def]
        if not self.skip and data.strip():
            self.parts.append(data.strip())


class Context:
    def __init__(self, source: Path, output: Path, project_id: str, submission_id: str, data_root: Path | None, ids_given: bool) -> None:
        self.source, self.output = source.resolve(), output.resolve()
        self.project_id, self.submission_id = project_id, submission_id
        self.data_root = data_root.resolve() if data_root else find_data_root(self.source) or find_data_root(self.output)
        self.prefix = f"projects/{project_id}/submissions/{submission_id}" if ids_given else ""
        self.derived = self.output if self.output.name == "extracted" else self.output / "extracted"
        self.limits: list[str] = []
        self.warnings: list[str] = []
        self.git: dict | None = None

    def ref(self, path: Path) -> str:
        path = Path(os.path.abspath(path))
        if self.data_root:
            try:
                return path.relative_to(self.data_root).as_posix()
            except ValueError:
                pass
        for base in (self.source, self.output):
            try:
                rel = path.relative_to(base).as_posix()
                return f"{self.prefix}/{rel}" if self.prefix else rel
            except ValueError:
                continue
        return path.name

    def reason(self, exc: BaseException) -> str:
        text = f"{type(exc).__name__}: {exc}" if str(exc) else type(exc).__name__
        for root in (self.data_root, self.source, self.output):
            if root:
                text = text.replace(str(root), "<каталог>")
        text = re.sub(r"(?:[A-Za-z]:)?(?:/[^\s'\"]+){2,}", "<путь>", text)
        return mask_secrets(text)[0][:240] or type(exc).__name__


def _material(ctx: Context, path: Path) -> dict:
    relative = path.relative_to(ctx.source).as_posix()
    identifier = ctx.ref(path)
    return {"material_id": identifier, "type": classify(path, relative=relative)["type"], "source": {"kind": "upload", "path": identifier}, "status": "available", "size_bytes": path.stat().st_size}


def _discover(ctx: Context) -> list[Path]:
    files: list[Path] = []
    for current, dirs, names in os.walk(ctx.source):
        here = Path(current)
        dirs[:] = sorted(d for d in dirs if not (here / d).is_symlink() and (here / d).resolve() != ctx.output and not (here == ctx.source and d in {"extracted"}) and d != ".git")
        for name in sorted(names):
            full = here / name
            if full.is_symlink() or (here == ctx.source and name in SERVICE_FILES):
                continue
            files.append(full)
    return files


def _extract_text(ctx: Context, path: Path, material: dict) -> None:
    out = ctx.derived / _slug(material["material_id"])
    info = documents.extract_document(path, out)
    extracted = {}
    for key, value in info.items():
        if key not in EXTRACTED_KEYS:
            continue
        if key in {"text_path", "slides_dir"}:
            if not (isinstance(value, str) and Path(value).exists()):
                continue
            value = ctx.ref(Path(value))
        extracted[key] = value
    material["extracted"] = extracted
    if info.get("slides_truncated"):
        ctx.limits.append("presentation: обработаны первые 40 слайдов")


def _handle_video(ctx: Context, path: Path, material: dict) -> None:
    out = ctx.derived / _slug(material["material_id"])
    try:
        info = video.extract_video(path, out)
    except video.VideoExtractionError as exc:
        material.update(status="unavailable", reason=ctx.reason(exc))
        return
    material["extracted"] = {"frames_dir": ctx.ref(Path(info["frames_dir"])), "duration_seconds": info["duration_seconds"]}
    ctx.limits.extend(info.get("limits_applied", []))
    transcript = info.get("transcript") or {}
    if isinstance(transcript, dict) and transcript.get("status") == "unavailable":
        material.update(status="partial", reason="расшифровка недоступна: в описи только ключевые кадры")
    elif isinstance(transcript, dict) and transcript.get("path"):
        material["extracted"]["transcript_path"] = ctx.ref(Path(transcript["path"]))


def _repo_material(ctx: Context, material: dict, clone_source: str, dest: Path) -> None:
    clone = repo.clone_repository(clone_source, dest)
    first = ctx.git is None
    info = repo.inspect_repository(clone, ctx.output if first else dest.parent / (dest.name + "-log"))
    shutil.rmtree(clone / ".git", ignore_errors=True)      # история с неотмаскированными секретами дальше не нужна: журнал — в git_log.json
    languages = [name for name, _ in sorted(info["languages"].items(), key=lambda item: (-item[1], item[0]))]
    material["extracted"] = {"repo_dir": ctx.ref(clone), "file_count": info["file_count"], "languages": languages}
    material["size_bytes"] = info["total_bytes"]
    if info["truncated"]:
        material["status"] = "partial"
        material["reason"] = "репозиторий больше 200 МБ: учтены только исходники"
        ctx.limits.append("repository: размер больше 200 МБ")
    if first:
        ctx.git = {"available": True, "first_commit_at": info["first_commit_at"], "last_commit_at": info["last_commit_at"], "commit_count": info["commit_count"],
                   "commits_before_start": info["commits_before_start"], "history_rewritten": info["history_rewritten"], "log_path": ctx.ref(Path(info["git_log_path"]))}


def _handle_archive(ctx: Context, path: Path, material: dict, extra: list[dict]) -> None:
    out = ctx.derived / _slug(material["material_id"])
    report = safe_unpack(path, out)
    material["extracted"] = {"file_count": report.files}
    if ctx.git is not None:
        return
    for current, dirs, _files in os.walk(out):
        if ".git" in dirs and (Path(current) / ".git").is_dir() and not (Path(current) / ".git").is_symlink():
            sub = {"material_id": material["material_id"] + "#repository", "type": "repository", "source": dict(material["source"]), "status": "available"}
            try:
                _repo_material(ctx, sub, str(current), ctx.derived / (_slug(sub["material_id"]) + "-repo"))
            except Exception as exc:  # noqa: BLE001 — сбой этапа не роняет опись
                sub.update(status="unavailable", reason=ctx.reason(exc))
            extra.append(sub)
            return
        dirs[:] = [d for d in dirs if d != ".git" and not (Path(current) / d).is_symlink()]


def _process_files(ctx: Context, materials: list[dict]) -> None:
    for path in _discover(ctx):
        try:
            material = _material(ctx, path)
        except OSError as exc:
            materials.append({"material_id": ctx.ref(path), "type": "other", "source": {"kind": "upload", "path": ctx.ref(path)}, "status": "unavailable", "reason": ctx.reason(exc)})
            continue
        materials.append(material)
        extra: list[dict] = []
        try:
            if material["type"] == "archive":
                _handle_archive(ctx, path, material, extra)
            elif material["type"] == "screencast":
                _handle_video(ctx, path, material)
            elif material["type"] in {"document", "presentation", "metrics_row"}:
                _extract_text(ctx, path, material)
        except Exception as exc:  # noqa: BLE001
            traceback.print_exc()
            material.pop("extracted", None)
            material.update(status="unavailable" if material["type"] == "archive" else "partial", reason=ctx.reason(exc))
        materials.extend(extra)


def _read_links(ctx: Context) -> list[dict]:
    path = ctx.source / "links.json"
    if not path.is_file() or path.is_symlink():
        return []
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        ctx.warnings.append(f"links.json не прочитан: {type(exc).__name__}")
        return []
    if not isinstance(data, list):
        ctx.warnings.append("links.json: ожидался список")
        return []
    return [item for item in data if isinstance(item, dict) and isinstance(item.get("url"), str)][:MAX_LINKS]


def _process_link(ctx: Context, entry: dict) -> dict:
    url = entry["url"]
    kind = entry.get("type") if entry.get("type") in MATERIAL_TYPES else classify_url(url)
    identifier = entry.get("material_id") if isinstance(entry.get("material_id"), str) and entry.get("material_id") else "link-" + _slug(url)
    material = {"material_id": identifier, "type": kind, "source": {"kind": "url", "url": _clean_url(url)}, "status": "available"}
    try:
        if kind == "repository":
            _repo_material(ctx, material, url, ctx.derived / (_slug(identifier) + "-repo"))
        else:
            target = ctx.derived / "web" / (_slug(identifier) + ".bin")
            result = web.fetch_url(url, target)
            material["size_bytes"] = result.size_bytes
            material["meta"] = {"http_status": result.status, "content_type": result.content_type, "attempts": result.attempts}
            if result.content_type in {"text/html", "application/xhtml+xml"}:
                parser = _Text()
                parser.feed(target.read_bytes()[:MAX_HTML_BYTES].decode("utf-8", errors="replace"))
                text_file = target.with_suffix(".txt")
                text_file.write_text("\n".join(parser.parts) + "\n", encoding="utf-8")
                material["extracted"] = {"text_path": ctx.ref(text_file)}
    except Exception as exc:  # noqa: BLE001 — недоступная ссылка = unavailable с причиной
        material.pop("extracted", None)
        material.update(status="unavailable", reason=ctx.reason(exc))
    return material


def _mask(ctx: Context) -> int:
    total = 0
    for current, dirs, names in os.walk(ctx.derived):
        dirs[:] = [d for d in dirs if d != ".git" and not (Path(current) / d).is_symlink()]
        for name in names:
            full = Path(current) / name
            if full.is_symlink():
                continue
            try:
                total += mask_file(full)
            except OSError:
                continue
    log = ctx.output / "git_log.json"
    if log.is_file():
        total += mask_file(log)
    return total


def _similarity(ctx: Context) -> None:
    if not (ctx.data_root and ctx.project_id and ctx.source.parent.name == "submissions" and ctx.source.parent.parent.name == ctx.project_id):
        return
    works = {d.name: d for d in sorted(ctx.source.parent.iterdir()) if d.is_dir() and not d.is_symlink()}
    target = ctx.data_root / "projects" / ctx.project_id / "similarity.json"
    temporary = target.with_name(f".similarity-{os.getpid()}.tmp")
    similarity.write_similarity(ctx.project_id, works, temporary)
    os.replace(temporary, target)


def run_pipeline(source: Path, output: Path, *, project_id: str = "project", submission_id: str | None = None, team_name: str | None = None,
                 required: list[str] | None = None, data_root: Path | None = None) -> dict:
    """Запускает все этапы и всегда пишет inventory.json, в том числе при частичных сбоях."""
    source, output = Path(source), Path(output)
    ids_given = project_id != "project" and submission_id is not None
    submission_id = submission_id or source.name
    required = [item for chunk in (required or []) for item in str(chunk).split(",") if item]
    ctx = Context(source, output, project_id, submission_id, data_root, ids_given)
    materials: list[dict] = []
    stages = [("files", lambda: _process_files(ctx, materials))] if source.is_dir() else []
    if not source.is_dir():
        ctx.warnings.append("каталог работы недоступен")
    stages.append(("links", lambda: materials.extend(_process_link(ctx, entry) for entry in _read_links(ctx))))
    for name, stage in stages:
        try:
            stage()
        except Exception as exc:  # noqa: BLE001 — опись сохраняется при любом сбое этапа
            traceback.print_exc()
            ctx.warnings.append(f"{name}: {ctx.reason(exc)}")
    masked = 0
    try:
        masked = _mask(ctx)
    except Exception as exc:  # noqa: BLE001
        ctx.warnings.append(f"mask: {ctx.reason(exc)}")
    output.mkdir(parents=True, exist_ok=True)
    try:
        _similarity(ctx)
    except Exception as exc:  # noqa: BLE001
        ctx.warnings.append(f"similarity: {ctx.reason(exc)}")
    present = {item["type"] for item in materials if item["status"] in {"available", "partial"}}
    missing = [item for item in required if item not in present]
    inventory = {"schema_version": "1", "submission_id": submission_id, "project_id": project_id, "team_name": team_name or source.name, "created_at": _now(),
                 "materials": materials, "completeness": {"status": "incomplete" if missing else "complete", "required": required, "missing": missing},
                 "limits_applied": sorted(set(ctx.limits)), "warnings": ctx.warnings, "masked_secrets": masked}
    if ctx.git is not None:
        inventory["git"] = ctx.git
    (output / "inventory.json").write_text(json.dumps(inventory, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return inventory
