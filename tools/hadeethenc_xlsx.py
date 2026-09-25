#!/usr/bin/env python3
"""Dependency-free reader/validator for official HadeethEnc XLSX downloads.

Only source cells are read. No translation or Arabic wording is generated or rewritten.
"""
from __future__ import annotations

import re
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

SHEET_NS = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
DOC_REL_NS = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
PKG_REL_NS = "http://schemas.openxmlformats.org/package/2006/relationships"
NS = {"x": SHEET_NS, "r": DOC_REL_NS}
VERSION_RE = re.compile(r"\(v([0-9]+(?:\.[0-9]+)*)\)", re.I)


def _column_index(reference: str) -> int:
    letters = []
    for ch in reference:
        if "A" <= ch.upper() <= "Z":
            letters.append(ch.upper())
        else:
            break
    if not letters:
        raise ValueError(f"Cell has no column reference: {reference!r}")
    value = 0
    for ch in letters:
        value = value * 26 + (ord(ch) - ord("A") + 1)
    return value - 1


def _shared_strings(zf: ZipFile) -> list[str]:
    name = "xl/sharedStrings.xml"
    if name not in zf.namelist():
        return []
    root = ET.fromstring(zf.read(name))
    values = []
    for item in root.findall(f"{{{SHEET_NS}}}si"):
        values.append("".join(node.text or "" for node in item.iter(f"{{{SHEET_NS}}}t")))
    return values


def _first_sheet_path(zf: ZipFile) -> str:
    workbook = ET.fromstring(zf.read("xl/workbook.xml"))
    sheet = workbook.find("x:sheets/x:sheet", NS)
    if sheet is None:
        raise ValueError("XLSX contains no worksheet")
    relationship = sheet.attrib.get(f"{{{DOC_REL_NS}}}id")
    if relationship and "xl/_rels/workbook.xml.rels" in zf.namelist():
        rels = ET.fromstring(zf.read("xl/_rels/workbook.xml.rels"))
        for rel in rels.findall(f"{{{PKG_REL_NS}}}Relationship"):
            if rel.attrib.get("Id") == relationship:
                target = rel.attrib.get("Target", "")
                if target.startswith("/"):
                    target = target.lstrip("/")
                elif not target.startswith("xl/"):
                    target = "xl/" + target
                if target in zf.namelist():
                    return target
    fallback = "xl/worksheets/sheet1.xml"
    if fallback not in zf.namelist():
        raise ValueError("Could not resolve first XLSX worksheet")
    return fallback


def _cell_text(cell, shared: list[str]) -> str:
    kind = cell.attrib.get("t")
    if kind == "inlineStr":
        inline = cell.find(f"{{{SHEET_NS}}}is")
        if inline is None:
            return ""
        return "".join(node.text or "" for node in inline.iter(f"{{{SHEET_NS}}}t"))
    value = cell.find(f"{{{SHEET_NS}}}v")
    if value is None or value.text is None:
        formula_text = cell.find(f"{{{SHEET_NS}}}f")
        return "" if formula_text is None or formula_text.text is None else formula_text.text
    raw = value.text
    if kind == "s":
        index = int(raw)
        if index < 0 or index >= len(shared):
            raise ValueError("Shared-string index outside XLSX table")
        return shared[index]
    if kind == "b":
        return "1" if raw == "1" else "0"
    return raw


def read_rows(path: Path) -> list[list[str]]:
    """Read the first worksheet while preserving sparse Excel column positions."""
    with ZipFile(path) as zf:
        shared = _shared_strings(zf)
        root = ET.fromstring(zf.read(_first_sheet_path(zf)))
        sheet_data = root.find(f"{{{SHEET_NS}}}sheetData")
        if sheet_data is None:
            return []
        rows = []
        for row in sheet_data.findall(f"{{{SHEET_NS}}}row"):
            values: dict[int, str] = {}
            highest = -1
            fallback_index = 0
            for cell in row.findall(f"{{{SHEET_NS}}}c"):
                ref = cell.attrib.get("r")
                index = _column_index(ref) if ref else fallback_index
                fallback_index = index + 1
                values[index] = _cell_text(cell, shared)
                highest = max(highest, index)
            rows.append([values.get(i, "") for i in range(highest + 1)] if highest >= 0 else [])
        return rows


def _clean(value) -> str:
    return str(value or "").strip()


def source_identity(value: str) -> str:
    """Comparison-only identity; display text remains byte-for-byte from the workbook cell."""
    return " ".join(_clean(value).replace("\u200e", "").replace("\u200f", "").split())


def _find_header(rows: list[list[str]]) -> tuple[int, list[str]]:
    for index, row in enumerate(rows[:12]):
        values = [_clean(value) for value in row]
        if "id" in values and "hadith_text" in values:
            return index, values
    raise ValueError("HadeethEnc workbook header was not found")


def _value(row: list[str], columns: dict[str, int], name: str) -> str:
    index = columns[name]
    return _clean(row[index] if index < len(row) else "")


def parse_workbook(path: Path, expected_language: str | None = None) -> dict:
    rows = read_rows(path)
    if len(rows) < 3:
        raise ValueError(f"Unexpectedly short HadeethEnc workbook: {path}")
    header_index, header = _find_header(rows)
    columns = {name: index for index, name in enumerate(header) if name}
    bilingual = {
        "id", "title_ar", "title", "hadith_text_ar", "hadith_text",
        "explanation_ar", "explanation", "benefits_ar", "benefits",
        "grade_ar", "takhrij_ar", "grade", "takhrij", "lang", "link",
    }
    arabic = {
        "id", "title", "hadith_text", "explanation", "word_meanings",
        "benefits", "grade", "takhrij", "link",
    }
    if bilingual <= set(columns):
        kind = "bilingual"
    elif arabic <= set(columns):
        kind = "arabic"
    else:
        missing_bilingual = sorted(bilingual - set(columns))
        missing_arabic = sorted(arabic - set(columns))
        raise ValueError(
            f"Unsupported HadeethEnc columns; bilingual missing={missing_bilingual}; "
            f"arabic missing={missing_arabic}"
        )

    metadata = "\n".join(
        _clean(value)
        for row in rows[:header_index]
        for value in row
        if _clean(value)
    )
    version_match = VERSION_RE.search(metadata)
    version = version_match.group(1) if version_match else None

    records = {}
    workbook_language = "ar" if kind == "arabic" else None
    for row_number, row in enumerate(rows[header_index + 1 :], header_index + 2):
        raw_id = _value(row, columns, "id")
        if not raw_id:
            continue
        if not re.fullmatch(r"[0-9]+(?:\.0+)?", raw_id):
            raise ValueError(f"{path.name}:{row_number}: invalid HadeethEnc id {raw_id!r}")
        hadith_id = str(int(float(raw_id)))
        if hadith_id in records:
            raise ValueError(f"{path.name}:{row_number}: duplicate HadeethEnc id {hadith_id}")

        if kind == "arabic":
            language = "ar"
            arabic_text = _value(row, columns, "hadith_text")
            translation = arabic_text
            record = {
                "id": hadith_id,
                "language": language,
                "title_ar": _value(row, columns, "title"),
                "title": _value(row, columns, "title"),
                "arabic": arabic_text,
                "translation": translation,
                "grade_ar": _value(row, columns, "grade"),
                "grade": _value(row, columns, "grade"),
                "takhrij_ar": _value(row, columns, "takhrij"),
                "takhrij": _value(row, columns, "takhrij"),
                "explanation": _value(row, columns, "explanation"),
                "benefits": _value(row, columns, "benefits"),
                "word_meanings": _value(row, columns, "word_meanings"),
                "link": _value(row, columns, "link"),
            }
        else:
            language = _value(row, columns, "lang").lower() or (expected_language or "")
            if expected_language and language != expected_language:
                raise ValueError(
                    f"{path.name}:{row_number}: expected language {expected_language}, found {language}"
                )
            workbook_language = workbook_language or language
            if workbook_language != language:
                raise ValueError(f"{path.name}: mixed language codes in one workbook")
            arabic_text = _value(row, columns, "hadith_text_ar")
            translation = _value(row, columns, "hadith_text")
            record = {
                "id": hadith_id,
                "language": language,
                "title_ar": _value(row, columns, "title_ar"),
                "title": _value(row, columns, "title"),
                "arabic": arabic_text,
                "translation": translation,
                "grade_ar": _value(row, columns, "grade_ar"),
                "grade": _value(row, columns, "grade"),
                "takhrij_ar": _value(row, columns, "takhrij_ar"),
                "takhrij": _value(row, columns, "takhrij"),
                "explanation_ar": _value(row, columns, "explanation_ar"),
                "explanation": _value(row, columns, "explanation"),
                "benefits_ar": _value(row, columns, "benefits_ar"),
                "benefits": _value(row, columns, "benefits"),
                "link": _value(row, columns, "link"),
            }

        if not record["arabic"]:
            raise ValueError(f"{path.name}:{row_number}: empty Arabic source text for id {hadith_id}")
        if kind == "bilingual" and not record["translation"]:
            raise ValueError(f"{path.name}:{row_number}: empty translation for id {hadith_id}")
        records[hadith_id] = record

    if not records:
        raise ValueError(f"No HadeethEnc records parsed from {path}")
    if expected_language and workbook_language != expected_language:
        raise ValueError(
            f"{path.name}: workbook language {workbook_language!r} does not match {expected_language!r}"
        )
    return {
        "kind": kind,
        "language": workbook_language,
        "version": version,
        "metadata": metadata,
        "records": records,
    }
