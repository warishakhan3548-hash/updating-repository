#!/usr/bin/env python3
"""Convert checked-in official HadeethEnc XLSX snapshots to Aaris Hadith JSONL.

No network access is used here. Source identity is HadeethEnc's own numeric id; translated rows
are joined to the current Arabic workbook only by that source id and an official hadith URL.
"""
from __future__ import annotations

import hashlib
import json
import re
import shutil
import unicodedata
import xml.etree.ElementTree as ET
from pathlib import Path
from zipfile import ZipFile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source-vault" / "hadith" / "hadeethenc" / "current"
POLICY = ROOT / "source-vault" / "hadith" / "hadeethenc" / "README.md"
NS = {"x": "http://schemas.openxmlformats.org/spreadsheetml/2006/main"}
LANGS = ("ar", "en", "ur", "hi")
BILINGUAL_REQUIRED = {
    "id", "title_ar", "title", "hadith_text_ar", "hadith_text",
    "grade_ar", "takhrij_ar", "grade", "takhrij", "lang", "link",
}
ARABIC_REQUIRED = {"id", "title", "hadith_text", "grade", "takhrij", "link"}


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def column_index(ref: str) -> int:
    letters = "".join(ch for ch in ref if ch.isalpha())
    if not letters:
        raise ValueError(f"Missing XLSX column reference: {ref!r}")
    result = 0
    for ch in letters.upper():
        result = result * 26 + (ord(ch) - ord("A") + 1)
    return result - 1


def shared_strings(zf: ZipFile) -> list[str]:
    try:
        root = ET.fromstring(zf.read("xl/sharedStrings.xml"))
    except KeyError:
        return []
    values = []
    for node in root.findall("x:si", NS):
        values.append("".join(part.text or "" for part in node.iter("{%s}t" % NS["x"])))
    return values


def cell_text(cell, shared: list[str]) -> str:
    kind = cell.attrib.get("t")
    if kind == "inlineStr":
        inline = cell.find("x:is", NS)
        return "" if inline is None else "".join(
            part.text or "" for part in inline.iter("{%s}t" % NS["x"])
        )
    value = cell.find("x:v", NS)
    if value is None or value.text is None:
        return ""
    if kind == "s":
        return shared[int(value.text)]
    return value.text


def rows(path: Path) -> list[list[str]]:
    with ZipFile(path) as zf:
        shared = shared_strings(zf)
        sheet = ET.fromstring(zf.read("xl/worksheets/sheet1.xml"))
    data = sheet.find("x:sheetData", NS)
    if data is None:
        raise ValueError(f"No sheet data in {path}")
    result = []
    for row in data.findall("x:row", NS):
        cells = {}
        for cell in row.findall("x:c", NS):
            ref = cell.attrib.get("r", "")
            cells[column_index(ref)] = cell_text(cell, shared)
        width = max(cells, default=-1) + 1
        result.append([cells.get(i, "") for i in range(width)])
    return result


def workbook(path: Path, language: str, version: str) -> dict[str, dict[str, str]]:
    all_rows = rows(path)
    if len(all_rows) < 3:
        raise ValueError(f"Unexpected HadeethEnc workbook layout: {path}")
    metadata = " ".join(all_rows[0]).strip()
    if f"v{version}" not in metadata:
        raise ValueError(f"{language}: workbook metadata does not contain expected v{version}")
    headers = [value.strip() for value in all_rows[1]]
    index = {name: i for i, name in enumerate(headers) if name}
    required = ARABIC_REQUIRED if language == "ar" else BILINGUAL_REQUIRED
    missing = sorted(required - set(index))
    if missing:
        raise ValueError(f"{language}: missing HadeethEnc columns: {missing}")

    def get(values, name):
        idx = index[name]
        return values[idx].strip() if idx < len(values) else ""

    result = {}
    for values in all_rows[2:]:
        raw_id = get(values, "id")
        if not raw_id:
            continue
        if not re.fullmatch(r"[0-9]+", raw_id):
            raise ValueError(f"{language}: invalid HadeethEnc id {raw_id!r}")
        hid = str(int(raw_id))
        if hid in result:
            raise ValueError(f"{language}: duplicate HadeethEnc id {hid}")
        row = {name: get(values, name) for name in index}
        link = row.get("link", "")
        if link and not re.search(rf"/hadith/{re.escape(hid)}(?:[/?#]|$)", link):
            raise ValueError(f"{language}:{hid}: official link/id mismatch")
        if language != "ar":
            declared = row.get("lang", "").lower()
            if declared and declared != language:
                raise ValueError(f"{language}:{hid}: workbook language is {declared!r}")
        text_key = "hadith_text" if language == "ar" else "hadith_text"
        if not row.get(text_key, "").strip():
            raise ValueError(f"{language}:{hid}: empty Hadith text")
        result[hid] = row
    if not result:
        raise ValueError(f"{language}: no HadeethEnc records")
    return result


def prepare(output: Path) -> dict:
    manifest_path = SOURCE / "manifest.json"
    if not manifest_path.is_file() or not POLICY.is_file():
        raise ValueError("HadeethEnc source snapshot/policy is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("provider") != "HadeethEnc.com":
        raise ValueError("Unsupported HadeethEnc source manifest")
    if manifest.get("runtime_network_required") is not False:
        raise ValueError("HadeethEnc build source must be offline")
    declared = {item["language"]: item for item in manifest.get("languages", [])}
    if set(declared) != set(LANGS):
        raise ValueError("HadeethEnc snapshot must contain ar/en/ur/hi")

    parsed = {}
    for language in LANGS:
        meta = declared[language]
        path = SOURCE / f"{language}.xlsx"
        if not path.is_file():
            raise ValueError(f"Missing HadeethEnc workbook: {language}")
        if path.stat().st_size != int(meta["bytes"]) or sha256(path) != meta["sha256"]:
            raise ValueError(f"HadeethEnc {language} source checksum mismatch")
        parsed[language] = workbook(path, language, str(meta["version"]))

    canonical = parsed["ar"]
    for language in ("en", "ur", "hi"):
        extra = sorted(set(parsed[language]) - set(canonical), key=int)
        if extra:
            raise ValueError(f"{language}: translated ids absent from current Arabic source: {extra[:10]}")

    records_dir = output / "records"
    licenses_dir = output / "LICENSES"
    meta_dir = output / "META"
    records_dir.mkdir(parents=True, exist_ok=True)
    licenses_dir.mkdir(parents=True, exist_ok=True)
    meta_dir.mkdir(parents=True, exist_ok=True)
    record_path = records_dir / "hadeethenc.jsonl"
    policy_out = licenses_dir / "HADEETHENC_POLICY.md"
    meta_out = meta_dir / "HADEETHENC_SOURCE.json"
    shutil.copyfile(POLICY, policy_out)
    shutil.copyfile(manifest_path, meta_out)

    versions = {language: str(declared[language]["version"]) for language in LANGS}
    counts = {language: len(parsed[language]) for language in LANGS}
    vowel_marked = 0
    with record_path.open("w", encoding="utf-8", newline="\n") as out:
        out.write(compact({
            "type": "collection",
            "id": "hadeethenc",
            "group": "translated_evidence",
            "name_en": "HadeethEnc – Verified Translated Hadiths",
            "name_ar": "موسوعة الأحاديث النبوية المترجمة",
            "kind": "translated_hadith",
            "edition": "HadeethEnc ar v" + versions["ar"],
        }) + "\n")
        for hid in sorted(canonical, key=int):
            row = canonical[hid]
            arabic = row["hadith_text"].strip()
            if any(unicodedata.category(ch).startswith("M") for ch in arabic):
                vowel_marked += 1
            source_link = row.get("link") or f"https://hadeethenc.com/ar/browse/hadith/{hid}"
            editorial = []
            for language in ("en", "ur", "hi"):
                translated = parsed[language].get(hid)
                if not translated:
                    continue
                text = translated["hadith_text"].strip()
                link = translated.get("link") or f"https://hadeethenc.com/{language}/browse/hadith/{hid}"
                editorial.append({
                    "id": f"H:hadeethenc:{hid}:T:{language}:v{versions[language]}",
                    "language": language,
                    "text": text,
                    "revision": "v" + versions[language],
                    "status": "released",
                    "source_ref": f"HadeethEnc.com · v{versions[language]} · {link}",
                })

            english = parsed["en"].get(hid)
            grade = (english or {}).get("grade", "").strip() if english else ""
            if not grade:
                grade = row.get("grade", "").strip()
            grades = []
            if grade:
                grade_version = versions["en"] if english else versions["ar"]
                grades.append({
                    "id": f"grade:hadeethenc:{hid}:v{grade_version}",
                    "grade": grade,
                    "grader": "HadeethEnc.com",
                    "source_version": "v" + grade_version,
                })
            out.write(compact({
                "type": "hadith",
                "id": f"H:hadeethenc:{hid}",
                "collection_id": "hadeethenc",
                "book_id": None,
                "chapter_id": None,
                "record_number": hid,
                "record_kind": "translated_hadith",
                "arabic": arabic,
                "source_ref": f"HadeethEnc.com · ar v{versions['ar']} · {source_link}",
                "references": [{"scheme": "hadeethenc", "value": hid}],
                "grades": grades,
                "editorial_translations": editorial,
            }) + "\n")

    return {
        "collection_id": "hadeethenc",
        "records": len(canonical),
        "translation_counts": {k: counts[k] for k in ("en", "ur", "hi")},
        "versions": versions,
        "vowel_marked_records": vowel_marked,
        "files": {
            "records/hadeethenc.jsonl": sha256(record_path),
            "LICENSES/HADEETHENC_POLICY.md": sha256(policy_out),
            "META/HADEETHENC_SOURCE.json": sha256(meta_out),
        },
        "license_file": "LICENSES/HADEETHENC_POLICY.md",
        "source_manifest": manifest,
    }
