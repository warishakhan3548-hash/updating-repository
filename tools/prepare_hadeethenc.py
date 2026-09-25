#!/usr/bin/env python3
"""Convert checked-in official HadeethEnc snapshots into Aaris Hadith JSONL.

This step is network-free. Arabic stays immutable. Published translations are attached as
versioned source translations and remain independently attributable to HadeethEnc.com.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import shutil
from pathlib import Path
from urllib.parse import urlparse

from hadeethenc_xlsx import parse_workbook, source_identity

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source-vault" / "hadith" / "hadeethenc" / "current"
TERMS = ROOT / "source-vault" / "hadith" / "hadeethenc" / "TERMS.md"
DEFAULT_PACK = ROOT / "build" / "generated" / "hadith-source"
LANGUAGES = ("ar", "en", "ur", "hi")


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compact(value) -> str:
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def _official_url(value: str) -> bool:
    try:
        parsed = urlparse(value)
        return parsed.scheme == "https" and parsed.hostname == "hadeethenc.com"
    except Exception:
        return False


def load_snapshot(source: Path) -> tuple[dict, dict[str, dict]]:
    manifest_path = source / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError("Missing checked-in HadeethEnc manifest")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    if manifest.get("schema") != 1 or manifest.get("provider") != "HadeethEnc.com":
        raise ValueError("Unsupported HadeethEnc snapshot manifest")
    if manifest.get("runtime_network_required") is not False:
        raise ValueError("HadeethEnc source snapshot may not require runtime network")

    entries = manifest.get("languages")
    if not isinstance(entries, list):
        raise ValueError("HadeethEnc manifest has no language inventory")
    by_language = {}
    for item in entries:
        language = str(item.get("language") or "").lower()
        if language in by_language:
            raise ValueError(f"Duplicate HadeethEnc language {language}")
        if language not in LANGUAGES:
            raise ValueError(f"Unexpected HadeethEnc language {language}")
        version = str(item.get("version") or "").strip()
        expected_hash = str(item.get("sha256") or "")
        expected_bytes = int(item.get("bytes") or 0)
        if not version or len(expected_hash) != 64 or expected_bytes < 1024:
            raise ValueError(f"Incomplete HadeethEnc manifest entry for {language}")
        if not _official_url(str(item.get("source_url") or "")) or not _official_url(str(item.get("download_url") or "")):
            raise ValueError(f"Untrusted HadeethEnc source URL for {language}")

        path = source / f"{language}.xlsx"
        if not path.is_file():
            raise ValueError(f"Missing HadeethEnc workbook: {path.name}")
        if path.stat().st_size != expected_bytes:
            raise ValueError(f"HadeethEnc byte-size mismatch: {path.name}")
        if sha256(path) != expected_hash:
            raise ValueError(f"HadeethEnc SHA-256 mismatch: {path.name}")
        parsed = parse_workbook(path, language)
        if parsed.get("version") and parsed["version"] != version:
            raise ValueError(
                f"HadeethEnc workbook/manifest version mismatch for {language}: "
                f"{parsed['version']} != {version}"
            )
        by_language[language] = {"meta": item, "parsed": parsed, "path": path}

    if set(by_language) != set(LANGUAGES):
        raise ValueError(
            "HadeethEnc snapshot must contain Arabic, English, Urdu and Hindi together; "
            f"found {sorted(by_language)}"
        )
    return manifest, by_language


def create_records(source: Path, target: Path) -> dict:
    manifest, layers = load_snapshot(source)
    arabic_records = layers["ar"]["parsed"]["records"]
    translation_layers = {language: layers[language]["parsed"]["records"] for language in ("en", "ur", "hi")}

    mismatch = []
    for language, records in translation_layers.items():
        unknown = sorted(set(records) - set(arabic_records), key=int)
        if unknown:
            raise ValueError(
                f"HadeethEnc {language} contains ids absent from the current Arabic source: "
                + ", ".join(unknown[:10])
            )
        for hadith_id, translated in records.items():
            if source_identity(translated["arabic"]) != source_identity(arabic_records[hadith_id]["arabic"]):
                mismatch.append((language, hadith_id))
    if mismatch:
        preview = ", ".join(f"{language}:{hadith_id}" for language, hadith_id in mismatch[:12])
        raise ValueError(
            f"HadeethEnc translation/Arabic identity drift at {len(mismatch)} records: {preview}"
        )

    versions = {language: layers[language]["meta"]["version"] for language in LANGUAGES}
    edition = "hadeethenc-" + "-".join(f"{language}{versions[language]}" for language in LANGUAGES)
    target.parent.mkdir(parents=True, exist_ok=True)

    translation_counts = {language: 0 for language in ("en", "ur", "hi")}
    with target.open("w", encoding="utf-8", newline="\n") as out:
        out.write(compact({
            "type": "collection",
            "id": "hadeethenc",
            "group": "verified_translations",
            "name_en": "HadeethEnc — Translated Hadiths",
            "name_ar": "موسوعة الأحاديث النبوية",
            "kind": "hadith",
            "edition": edition,
            "source_name": "HadeethEnc.com",
            "source_version": "; ".join(f"{language}=v{versions[language]}" for language in LANGUAGES),
        }) + "\n")

        for hadith_id in sorted(arabic_records, key=int):
            source_record = arabic_records[hadith_id]
            source_link = source_record.get("link") or f"HadeethEnc.com:ar:{hadith_id}:v{versions['ar']}"
            translations = []
            for language in ("en", "ur", "hi"):
                item = translation_layers[language].get(hadith_id)
                if not item:
                    continue
                text = str(item.get("translation") or "").strip()
                if not text:
                    continue
                translation_counts[language] += 1
                ref = item.get("link") or f"HadeethEnc.com:{language}:{hadith_id}:v{versions[language]}"
                translations.append({
                    "id": f"H:hadeethenc:{edition}:0:{hadith_id}:T:{language}:v{versions[language]}",
                    "language": language,
                    "text": text,
                    "revision": versions[language],
                    "status": "released",
                    "source_ref": ref,
                })

            grades = []
            grade = str(source_record.get("grade") or "").strip()
            if grade:
                gid = hashlib.sha256(
                    f"hadeethenc|{hadith_id}|{versions['ar']}|{grade}".encode("utf-8")
                ).hexdigest()[:24]
                grades.append({
                    "id": f"G:hadeethenc:{gid}",
                    "grade": grade,
                    "grader": "HadeethEnc.com",
                    "source_version": f"ar-v{versions['ar']}",
                })

            out.write(compact({
                "type": "hadith",
                "id": f"H:hadeethenc:{edition}:0:{hadith_id}",
                "collection_id": "hadeethenc",
                "book_id": None,
                "chapter_id": None,
                "record_number": hadith_id,
                "record_kind": "translated_hadith",
                "arabic": source_record["arabic"],
                "source_ref": source_link,
                "references": [{"scheme": "hadeethenc-id", "value": hadith_id}],
                "grades": grades,
                "editorial_translations": translations,
            }) + "\n")

    return {
        "provider": "HadeethEnc.com",
        "captured_on": manifest.get("captured_on"),
        "edition": edition,
        "versions": versions,
        "records": len(arabic_records),
        "translations": translation_counts,
        "source_manifest_sha256": sha256(source / "manifest.json"),
        "source_files": {
            f"{language}.xlsx": sha256(layers[language]["path"])
            for language in LANGUAGES
        },
    }


def merge_into_pack(source: Path, pack: Path) -> dict:
    manifest_path = pack / "manifest.json"
    if not manifest_path.is_file():
        raise ValueError("Prepare the base Hadith pack before merging HadeethEnc")
    manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    records_path = pack / "records" / "hadeethenc.jsonl"
    report = create_records(source, records_path)

    meta_dir = pack / "META"
    licenses_dir = pack / "LICENSES"
    meta_dir.mkdir(exist_ok=True)
    licenses_dir.mkdir(exist_ok=True)
    shutil.copyfile(source / "manifest.json", meta_dir / "HADEETHENC_MANIFEST.json")
    if not TERMS.is_file():
        raise ValueError("Missing repository HadeethEnc terms/provenance note")
    shutil.copyfile(TERMS, licenses_dir / "HADEETHENC_TERMS.md")

    manifest["pack_id"] = "aaris-open-hadith-data-plus-hadeethenc"
    manifest["content_version"] = (
        str(manifest["content_version"]) + "+hadeethenc-" + report["source_manifest_sha256"][:12]
    )
    manifest["source_name"] = "Open-Hadith-Data + HadeethEnc.com"
    manifest["source_version"] = (
        str(manifest["source_version"]) + " + " +
        "; ".join(f"{k}=v{v}" for k, v in report["versions"].items())
    )
    manifest["redistribution_basis"] = (
        str(manifest["redistribution_basis"]) +
        " HadeethEnc translated content is preserved under the publisher's documented "
        "download/republication conditions recorded in LICENSES/HADEETHENC_TERMS.md."
    )

    required = list(manifest.get("required_collection_ids") or [])
    if "hadeethenc" not in required:
        required.append("hadeethenc")
    manifest["required_collection_ids"] = required
    manifest["exact_collection_set"] = True
    manifest["language_coverage"] = ["ar", "en", "hi", "ur"]
    counts = dict(manifest.get("collection_record_counts") or {})
    counts["hadeethenc"] = report["records"]
    manifest["collection_record_counts"] = counts

    # The source-vocalization requirement belongs only to the vendored core-nine collections.
    manifest["vowel_mark_collection_ids"] = [
        cid for cid in required if cid != "hadeethenc"
    ]

    manifest["license_files"] = list(dict.fromkeys(
        list(manifest.get("license_files") or []) + ["LICENSES/HADEETHENC_TERMS.md"]
    ))
    files = dict(manifest.get("files") or {})
    files["records/hadeethenc.jsonl"] = sha256(records_path)
    files["LICENSES/HADEETHENC_TERMS.md"] = sha256(licenses_dir / "HADEETHENC_TERMS.md")
    files["META/HADEETHENC_MANIFEST.json"] = sha256(meta_dir / "HADEETHENC_MANIFEST.json")
    manifest["files"] = files
    inventory = dict(manifest.get("source_inventory") or {})
    inventory["hadeethenc"] = report
    manifest["source_inventory"] = inventory

    manifest_path.write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )
    return report


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--pack", type=Path, default=DEFAULT_PACK)
    args = parser.parse_args()
    report = merge_into_pack(args.source.resolve(), args.pack.resolve())
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
