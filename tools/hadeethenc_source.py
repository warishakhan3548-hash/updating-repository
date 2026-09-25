#!/usr/bin/env python3
"""Convert checked-in official HadeethEnc XLSX snapshots to Aaris Hadith JSONL.

Network-free build step. The Arabic record is canonical for this HadeethEnc lane; English,
Urdu and Hindi rows are joined only by HadeethEnc's own numeric id and must carry the same
Arabic source wording. No fuzzy cross-edition mapping is allowed.
"""
from __future__ import annotations

import hashlib
import json
import shutil
import unicodedata
from pathlib import Path
from urllib.parse import urlparse

from hadeethenc_xlsx import parse_workbook, source_identity

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / "source-vault" / "hadith" / "hadeethenc" / "current"
TERMS = ROOT / "source-vault" / "hadith" / "hadeethenc" / "TERMS.md"
LANGS = ("ar", "en", "ur", "hi")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def official_url(value: str) -> bool:
    parsed = urlparse(str(value or ""))
    return parsed.scheme == "https" and parsed.hostname == "hadeethenc.com"


def prepare(output: Path) -> dict:
    manifest_path = SOURCE / "manifest.json"
    if not manifest_path.is_file() or not TERMS.is_file():
        raise ValueError("HadeethEnc source snapshot/terms evidence is missing")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("provider") != "HadeethEnc.com":
        raise ValueError("Unsupported HadeethEnc source manifest")
    if manifest.get("runtime_network_required") is not False:
        raise ValueError("HadeethEnc build source must be offline")

    declared = {}
    for item in manifest.get("languages", []):
        language = str(item.get("language") or "").lower()
        if language in declared:
            raise ValueError(f"Duplicate HadeethEnc language {language}")
        declared[language] = item
    if set(declared) != set(LANGS):
        raise ValueError("HadeethEnc snapshot must contain exactly ar/en/ur/hi")

    parsed = {}
    for language in LANGS:
        meta = declared[language]
        path = SOURCE / f"{language}.xlsx"
        if not path.is_file():
            raise ValueError(f"Missing HadeethEnc workbook: {language}")
        if path.stat().st_size != int(meta.get("bytes") or 0) or sha256(path) != meta.get("sha256"):
            raise ValueError(f"HadeethEnc {language} source checksum mismatch")
        if not official_url(meta.get("source_url")) or not official_url(meta.get("download_url")):
            raise ValueError(f"HadeethEnc {language} source is not the official HTTPS host")
        workbook = parse_workbook(path, language)
        expected_version = str(meta.get("version") or "").strip()
        if workbook.get("version") and workbook["version"] != expected_version:
            raise ValueError(
                f"HadeethEnc {language} version mismatch: {workbook['version']} != {expected_version}"
            )
        parsed[language] = workbook["records"]

    canonical = parsed["ar"]
    withheld = {}
    for language in ("en", "ur", "hi"):
        translated = parsed[language]
        extra = sorted(set(translated) - set(canonical), key=int)
        if extra:
            raise ValueError(
                f"HadeethEnc {language} contains ids absent from Arabic source: {extra[:10]}"
            )
        # A translated row is attached only when the Arabic evidence embedded in that same
        # official workbook agrees with the current official Arabic workbook. Source snapshots
        # are still archived losslessly, but mismatching rows are withheld rather than guessed.
        withheld[language] = [
            hid for hid, row in translated.items()
            if source_identity(row["arabic"]) != source_identity(canonical[hid]["arabic"])
        ]

    records_dir = output / "records"
    licenses_dir = output / "LICENSES"
    meta_dir = output / "META"
    records_dir.mkdir(parents=True, exist_ok=True)
    licenses_dir.mkdir(parents=True, exist_ok=True)
    meta_dir.mkdir(parents=True, exist_ok=True)
    record_path = records_dir / "hadeethenc.jsonl"
    terms_out = licenses_dir / "HADEETHENC_TERMS.md"
    meta_out = meta_dir / "HADEETHENC_SOURCE.json"
    shutil.copyfile(TERMS, terms_out)
    shutil.copyfile(manifest_path, meta_out)

    versions = {language: str(declared[language]["version"]) for language in LANGS}
    translation_counts = {language: 0 for language in ("en", "ur", "hi")}
    vowel_marked = 0
    with record_path.open("w", encoding="utf-8", newline="\n") as out:
        out.write(compact({
            "type": "collection",
            "id": "hadeethenc",
            "group": "translated_evidence",
            "name_en": "HadeethEnc — Verified Translated Hadiths",
            "name_ar": "موسوعة الأحاديث النبوية",
            "kind": "translated_hadith",
            "edition": "HadeethEnc official",
        }) + "\n")

        for hid in sorted(canonical, key=int):
            source = canonical[hid]
            arabic = source["arabic"]
            if any(unicodedata.category(ch).startswith("M") for ch in arabic):
                vowel_marked += 1

            editorial = []
            for language in ("en", "ur", "hi"):
                translated = parsed[language].get(hid)
                if not translated or hid in withheld[language]:
                    continue
                text = str(translated.get("translation") or "").strip()
                if not text:
                    continue
                translation_counts[language] += 1
                link = translated.get("link") or f"https://hadeethenc.com/{language}/browse/hadith/{hid}"
                editorial.append({
                    "id": f"H:hadeethenc:official:{hid}:T:{language}:v{versions[language]}",
                    "language": language,
                    "text": text,
                    "revision": "v" + versions[language],
                    "status": "released",
                    "source_ref": f"HadeethEnc.com · v{versions[language]} · {link}",
                })

            grade = str(source.get("grade") or "").strip()
            grades = []
            if grade:
                grade_key = hashlib.sha256(
                    f"hadeethenc|{hid}|{versions['ar']}|{grade}".encode("utf-8")
                ).hexdigest()[:24]
                grades.append({
                    "id": f"G:hadeethenc:{grade_key}",
                    "grade": grade,
                    "grader": "HadeethEnc.com",
                    "source_version": "ar-v" + versions["ar"],
                })

            source_link = source.get("link") or f"https://hadeethenc.com/ar/browse/hadith/{hid}"
            out.write(compact({
                "type": "hadith",
                "id": f"H:hadeethenc:official:{hid}",
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
        "translation_counts": translation_counts,
        "withheld_translation_ids": withheld,
        "versions": versions,
        "vowel_marked_records": vowel_marked,
        "files": {
            "records/hadeethenc.jsonl": sha256(record_path),
            "LICENSES/HADEETHENC_TERMS.md": sha256(terms_out),
            "META/HADEETHENC_SOURCE.json": sha256(meta_out),
        },
        "license_file": "LICENSES/HADEETHENC_TERMS.md",
        "source_manifest": manifest,
    }
