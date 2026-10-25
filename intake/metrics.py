from __future__ import annotations

import csv
import re
import zipfile
from pathlib import Path
from xml.etree import ElementTree


class MetricsError(ValueError):
    pass


def _csv_rows(path: Path) -> list[dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig", errors="replace") as handle:
        rows = list(csv.DictReader(handle))
    return [{str(key).strip(): (value or "").strip() for key, value in row.items()} for row in rows]


def _xlsx_rows(path: Path) -> list[dict[str, str]]:
    with zipfile.ZipFile(path) as archive:
        names = archive.namelist()
        shared: list[str] = []
        if "xl/sharedStrings.xml" in names:
            shared = [" ".join(value.strip() for value in item.itertext() if value.strip()) for item in ElementTree.fromstring(archive.read("xl/sharedStrings.xml"))]
        sheet = next((name for name in sorted(names) if re.fullmatch(r"xl/worksheets/sheet\d+\.xml", name)), None)
        if not sheet:
            return []
        raw_rows: list[list[str]] = []
        for node in ElementTree.fromstring(archive.read(sheet)).iter():
            if not node.tag.endswith("}row"):
                continue
            values = []
            for cell in node:
                if not cell.tag.endswith("}c"):
                    continue
                value = next((child.text or "" for child in cell if child.tag.endswith("}v")), "")
                if cell.attrib.get("t") == "s" and value.isdigit() and int(value) < len(shared):
                    value = shared[int(value)]
                values.append(value.strip())
            raw_rows.append(values)
        if not raw_rows:
            return []
        headers = [item or f"column_{index}" for index, item in enumerate(raw_rows[0])]
        return [dict(zip(headers, row + [""] * (len(headers) - len(row)))) for row in raw_rows[1:]]


def parse_metrics(path: str | Path) -> dict[str, object]:
    path = Path(path)
    if path.suffix.lower() == ".csv":
        rows = _csv_rows(path)
    elif path.suffix.lower() in {".xlsx", ".xlsm"}:
        rows = _xlsx_rows(path)
    else:
        raise MetricsError("metrics input must be CSV or XLSX")
    team_key = next((key for key in ("team", "team_name", "команда", "название команды") if rows and key in rows[0]), None)
    normalized = [{"team_name": row.get(team_key, "") if team_key else "", "metrics": {key: value for key, value in row.items() if key != team_key}} for row in rows]
    return {"source": path.name, "rows": normalized, "unmatched": [], "row_count": len(normalized)}
