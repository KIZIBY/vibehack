from __future__ import annotations

import csv
import io
import re
import shutil
import subprocess
import zipfile
from pathlib import Path
from xml.etree import ElementTree


MAX_SLIDES = 40


class DocumentExtractionError(RuntimeError):
    pass


def _write_text(output: Path, text: str) -> str:
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(text.strip() + "\n", encoding="utf-8")
    return output.as_posix()


def _xml_text(data: bytes) -> str:
    root = ElementTree.fromstring(data)
    return " ".join(value.strip() for value in root.itertext() if value.strip())


def _ooxml(path: Path, output: Path, kind: str) -> dict:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        if kind == "docx":
            text = _xml_text(archive.read("word/document.xml"))
            return {"text_path": _write_text(output / "text.txt", text)}
        if kind == "pptx":
            slide_names = sorted((name for name in names if re.fullmatch(r"ppt/slides/slide\d+\.xml", name)), key=lambda name: int(re.search(r"\d+", name).group()))
            slides = slide_names[:MAX_SLIDES]
            slide_dir = output / "slides"
            text_parts = []
            for index, name in enumerate(slides, 1):
                text = _xml_text(archive.read(name))
                text_parts.append(f"[Слайд {index}] {text}")
            for index, name in enumerate((name for name in names if name.startswith("ppt/media/") and Path(name).suffix.lower() in {".png", ".jpg", ".jpeg"}), 1):
                if index > MAX_SLIDES:
                    break
                slide_dir.mkdir(parents=True, exist_ok=True)
                (slide_dir / f"{index:03d}{Path(name).suffix.lower()}").write_bytes(archive.read(name))
            return {"text_path": _write_text(output / "text.txt", "\n".join(text_parts)), "slides_dir": slide_dir.as_posix(), "slide_count": len(slide_names), "slides_truncated": len(slide_names) > MAX_SLIDES}
        if kind == "xlsx":
            shared = []
            if "xl/sharedStrings.xml" in names:
                shared = [text for item in ElementTree.fromstring(archive.read("xl/sharedStrings.xml")) for text in [" ".join(value.strip() for value in item.itertext() if value.strip())]]
            rows: list[str] = []
            for sheet in sorted(name for name in names if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", name)):
                for row in ElementTree.fromstring(archive.read(sheet)).iter():
                    if row.tag.endswith("}row"):
                        values = []
                        for cell in row:
                            if not cell.tag.endswith("}c"):
                                continue
                            value = next((node.text for node in cell if node.tag.endswith("}v")), "") or ""
                            if cell.attrib.get("t") == "s" and value.isdigit() and int(value) < len(shared):
                                value = shared[int(value)]
                            values.append(value)
                        if values:
                            rows.append("\t".join(values))
            return {"text_path": _write_text(output / "text.txt", "\n".join(rows))}
    raise DocumentExtractionError(f"unsupported OOXML document: {path}")


def extract_document(path: str | Path, output: str | Path) -> dict:
    path, output = Path(path), Path(output)
    suffix = path.suffix.lower()
    if suffix in {".md", ".txt"}:
        return {"text_path": _write_text(output / "text.txt", path.read_text(encoding="utf-8", errors="replace"))}
    if suffix == ".csv":
        with path.open(newline="", encoding="utf-8-sig", errors="replace") as handle:
            text = "\n".join("\t".join(row) for row in csv.reader(handle))
        return {"text_path": _write_text(output / "text.txt", text)}
    if suffix in {".docx", ".pptx", ".xlsx"}:
        return _ooxml(path, output, suffix[1:])
    if suffix == ".pdf":
        try:
            from pypdf import PdfReader
        except ImportError:
            if not shutil.which("pdftotext"):
                raise DocumentExtractionError("PDF extraction requires pypdf or pdftotext")
            text = subprocess.run(["pdftotext", str(path), "-"], check=True, capture_output=True, text=True).stdout
        else:
            text = "\n".join(page.extract_text() or "" for page in PdfReader(str(path)).pages)
        return {"text_path": _write_text(output / "text.txt", text)}
    raise DocumentExtractionError(f"unsupported document type: {suffix or 'none'}")
