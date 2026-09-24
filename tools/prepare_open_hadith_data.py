#!/usr/bin/env python3
"""Prepare the vendored Open-Hadith-Data Arabic corpus for Aaris.

This tool is deliberately network-free. It verifies the archived plain and vocalized upstream CSVs,
matches every narration by number and wording, imports the published vocalization, and writes a
SHA-256 locked manifest consumable by build_hadith.py. The plain CSVs are identity checks only;
they must never silently become the displayed text again.

It does not invent books, chapters, translations, grades or commentary that are absent upstream.
"""
import argparse
import csv
import gzip
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source-vault" / "hadith" / "open-hadith-data"
DEFAULT_OUTPUT = ROOT / "build" / "generated" / "hadith-source"
CATALOG = ROOT / "tools" / "hadith-catalog.json"
VOWEL_MARKS = re.compile(r"[\u064b-\u0652\u0670]")


def display_text(value):
    """Only remove upstream layout markers/extra spaces, never letters or vowel marks."""
    return re.sub(r"\s+", " ", value.replace("\u200f", "")).strip()


def plain_identity(value):
    # Deliberately stricter than search: no folding hamza, alef, ya, punctuation or word order.
    return VOWEL_MARKS.sub("", display_text(value))


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def source_paths(source: Path, local_name: str):
    candidate = source / local_name
    if candidate.is_file():
        return [candidate]
    if candidate.is_dir():
        parts = sorted(p for p in candidate.iterdir() if p.is_file())
        if not parts:
            raise ValueError(f"No source parts found in {candidate}")
        return parts
    raise ValueError(f"Missing vendored source: {candidate}")


def git_blob_sha1(paths):
    total = sum(p.stat().st_size for p in paths)
    h = hashlib.sha1()
    h.update(f"blob {total}\0".encode("ascii"))
    for path in paths:
        with path.open("rb") as f:
            for chunk in iter(lambda: f.read(1024 * 1024), b""):
                h.update(chunk)
    return h.hexdigest()


def verify_vocalized(source, definition):
    meta = definition.get("vocalized")
    if not isinstance(meta, dict):
        raise ValueError("Missing vocalized source; refusing to fall back to plain Arabic")
    path = source / meta["local"]
    if sha256(path) != meta["compressed_sha256"]:
        raise ValueError(f"Vocalized archive checksum mismatch: {path}")
    size = int(meta["uncompressed_bytes"])
    blob = hashlib.sha1(f"blob {size}\0".encode("ascii"))
    digest = hashlib.sha256()
    actual_size = 0
    with gzip.open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            blob.update(chunk)
            digest.update(chunk)
            actual_size += len(chunk)
    if (actual_size != size or blob.hexdigest() != meta["git_blob_sha1"]
            or digest.hexdigest() != meta["sha256"]):
        raise ValueError(f"Vocalized CSV does not reconstruct pinned upstream bytes: {path}")
    return path


def plain_records(paths):
    records = {}
    for row in csv.reader(joined_lines(paths), strict=True):
        if not row or all(not v.strip() for v in row):
            continue
        if len(row) != 2 or not re.fullmatch(r"[0-9]+", row[0].strip()):
            raise ValueError("Malformed plain Arabic identity source")
        number = row[0].strip()
        if number in records or not row[1].strip():
            raise ValueError(f"Duplicate/empty plain Arabic identity: {number}")
        records[number] = display_text(row[1])
    return records


def vocalized_records(path, columns, baseline):
    seen = set()
    with gzip.open(path, "rt", encoding="utf-8-sig", newline="") as f:
        for row_no, row in enumerate(csv.reader(f, strict=True), 1):
            if not row or all(not v.strip() for v in row):
                continue
            if len(row) != columns:
                raise ValueError(f"{path.name}: wrong column count at row {row_no}")
            number, arabic = row[0].strip(), display_text(row[1])
            if number in seen or not re.fullmatch(r"[0-9]+", number):
                raise ValueError(f"{path.name}: duplicate/invalid record {number!r}")
            if not VOWEL_MARKS.search(arabic):
                raise ValueError(f"{path.name}:{number}: source vowel marks missing")
            if plain_identity(arabic) != baseline.get(number):
                raise ValueError(f"{path.name}:{number}: vocalized wording differs from plain identity")
            seen.add(number)
            # Column 3, where present, is Arabic commentary, NOT a translation or narration.
            yield number, arabic
    if seen != set(baseline):
        raise ValueError(f"{path.name}: plain/vocalized record coverage differs")


def joined_lines(paths):
    """Yield logical text lines without inserting bytes at split-part boundaries."""
    pending = ""
    first = True
    for path in paths:
        with path.open("r", encoding="utf-8-sig" if first else "utf-8", newline="") as f:
            first = False
            while True:
                chunk = f.read(1024 * 1024)
                if not chunk:
                    break
                pending += chunk
                while True:
                    nl = pending.find("\n")
                    if nl < 0:
                        break
                    yield pending[: nl + 1]
                    pending = pending[nl + 1 :]
    if pending:
        yield pending


def compact(obj):
    return json.dumps(obj, ensure_ascii=False, separators=(",", ":"))


def load_catalog():
    data = json.loads(CATALOG.read_text(encoding="utf-8"))
    return {item["id"]: item for item in data["collections"]}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", type=Path, default=DEFAULT_SOURCE)
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    args = parser.parse_args()

    source = args.source.resolve()
    output = args.output.resolve()
    inventory_path = source / "SOURCE.json"
    license_path = source / "LICENSE"
    if not inventory_path.is_file() or not license_path.is_file():
        raise SystemExit("Vendored Hadith source is missing SOURCE.json or LICENSE")

    inventory = json.loads(inventory_path.read_text(encoding="utf-8"))
    if inventory.get("schema") != 2 or inventory.get("display_variant") != "upstream-vocalized":
        raise SystemExit("Vocalized inventory required; refusing an unvocalized fallback")
    upstream_commit = str(inventory.get("upstream_commit") or "").strip()
    if not re.fullmatch(r"[0-9a-f]{40}", upstream_commit):
        raise SystemExit("SOURCE.json has no valid pinned upstream commit")

    definitions = inventory.get("collections")
    if not isinstance(definitions, dict) or not definitions:
        raise SystemExit("SOURCE.json has no collection inventory")

    expected_ids = ["bukhari", "muslim", "nasai", "abudawud", "tirmidhi",
                    "ibnmajah", "malik", "ahmad", "darimi"]
    if set(definitions) != set(expected_ids):
        raise SystemExit("Open-Hadith-Data inventory must contain exactly the pinned nine collections")

    verified = {}
    resolved = {}
    vocalized = {}
    for key in ("upstream_license", "upstream_readme"):
        evidence = inventory[key]
        if git_blob_sha1([source / evidence["local"]]) != evidence["git_blob_sha1"]:
            raise SystemExit(f"Upstream attribution checksum mismatch: {key}")
    for collection_id in expected_ids:
        item = definitions[collection_id]
        paths = source_paths(source, str(item["local"]))
        actual = git_blob_sha1(paths)
        expected = str(item.get("git_blob_sha1") or "")
        if actual != expected:
            raise SystemExit(
                f"{collection_id}: vendored bytes do not reconstruct pinned upstream Git blob; "
                f"expected {expected}, got {actual}")
        resolved[collection_id] = paths
        vocalized[collection_id] = verify_vocalized(source, item)
        verified[collection_id] = {
            "upstream_path": item["path"],
            "git_blob_sha1": actual,
            "local_files": [str(p.relative_to(source)) for p in paths],
            "bytes": sum(p.stat().st_size for p in paths),
            "vocalized": item["vocalized"],
        }

    if output.exists():
        shutil.rmtree(output)
    records_dir = output / "records"
    licenses_dir = output / "LICENSES"
    meta_dir = output / "META"
    records_dir.mkdir(parents=True)
    licenses_dir.mkdir()
    meta_dir.mkdir()

    shutil.copyfile(license_path, licenses_dir / "ODBL.txt")
    shutil.copyfile(inventory_path, meta_dir / "SOURCE.json")
    shutil.copyfile(source / "UPSTREAM_README.md", meta_dir / "UPSTREAM_README.md")

    catalog = load_catalog()
    edition = "open-hadith-data-" + upstream_commit[:12]
    records_path = records_dir / "open-hadith-data.jsonl"
    counts = {}
    mark_counts = {}

    with records_path.open("w", encoding="utf-8", newline="\n") as out:
        for collection_id in expected_ids:
            item = catalog.get(collection_id)
            if not item:
                raise SystemExit(f"Catalog metadata missing for {collection_id}")
            out.write(compact({
                "type": "collection",
                "id": collection_id,
                "group": item.get("group") or "nine_books",
                "name_en": item["name_en"],
                "name_ar": item["name_ar"],
                "kind": item.get("kind") or "hadith",
                "edition": edition,
            }) + "\n")

            seen = set()
            count = 0
            first_number = None
            last_number = None
            marks = 0
            baseline = plain_records(resolved[collection_id])
            reader = vocalized_records(vocalized[collection_id],
                definitions[collection_id]["vocalized"]["columns"], baseline)
            for number, arabic in reader:
                seen.add(number)
                marks += len(VOWEL_MARKS.findall(arabic))
                if first_number is None:
                    first_number = number
                last_number = number

                hid = f"H:{collection_id}:{edition}:0:{number}"
                out.write(compact({
                    "type": "hadith",
                    "id": hid,
                    "collection_id": collection_id,
                    "book_id": None,
                    "chapter_id": None,
                    "record_number": number,
                    "record_kind": "hadith",
                    "arabic": arabic,
                    "source_ref": f"Open-Hadith-Data:{collection_id}:{number}",
                    "references": [
                        {"scheme": "open-hadith-data", "value": f"{collection_id}:{number}"}
                    ],
                }) + "\n")
                count += 1

            if count == 0:
                raise SystemExit(f"{collection_id}: no records parsed")

            definition = definitions[collection_id]
            expected_count = int(definition.get("expected_record_count") or 0)
            expected_first = str(definition.get("expected_first_record") or "")
            expected_last = str(definition.get("expected_last_record") or "")
            if expected_count and count != expected_count:
                raise SystemExit(
                    f"{collection_id}: record coverage mismatch; expected {expected_count}, got {count}")
            if expected_first and first_number != expected_first:
                raise SystemExit(
                    f"{collection_id}: first record mismatch; expected {expected_first}, got {first_number}")
            if expected_last and last_number != expected_last:
                raise SystemExit(
                    f"{collection_id}: last record mismatch; expected {expected_last}, got {last_number}")
            if expected_count and expected_first == "1" and expected_last == str(expected_count):
                missing = [str(n) for n in range(1, expected_count + 1) if str(n) not in seen]
                if missing:
                    preview = ", ".join(missing[:10])
                    raise SystemExit(
                        f"{collection_id}: contiguous record coverage has gaps: {preview}" +
                        (" …" if len(missing) > 10 else ""))

            counts[collection_id] = count
            mark_counts[collection_id] = marks

    files = {
        "records/open-hadith-data.jsonl": sha256(records_path),
        "LICENSES/ODBL.txt": sha256(licenses_dir / "ODBL.txt"),
        "META/SOURCE.json": sha256(meta_dir / "SOURCE.json"),
        "META/UPSTREAM_README.md": sha256(meta_dir / "UPSTREAM_README.md"),
    }
    manifest = {
        "pack_id": "aaris-open-hadith-data-arabic-nine",
        "content_version": upstream_commit[:12] + "-vocalized-v1",
        "source_name": "Open-Hadith-Data",
        "source_version": upstream_commit,
        "redistribution_basis": "ODbL 1.0 database; individual contents under Database Contents License, as declared by upstream LICENSE.",
        "license_files": ["LICENSES/ODBL.txt"],
        "files": files,
        "required_collection_ids": expected_ids,
        "exact_collection_set": True,
        "record_number_unique_within_collection": True,
        "require_catalog_complete": False,
        "runtime_network_required": False,
        "language_coverage": ["ar"],
        "require_vowel_marks": True,
        "vocalization": {
            "origin": "published-upstream",
            "generated": False,
            "display_cleanup": inventory["display_cleanup"],
            "records_with_vowel_marks": sum(counts.values()),
            "collection_vowel_mark_counts": mark_counts,
            "identity_check": "All record numbers and words match the pinned plain edition after removing vowel marks and layout-only whitespace/RTL markers.",
        },
        "collection_record_counts": counts,
        "source_inventory": verified,
    }
    (output / "manifest.json").write_text(
        json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    print(json.dumps({
        "pack_id": manifest["pack_id"],
        "source_version": upstream_commit,
        "collections": len(counts),
        "records": sum(counts.values()),
        "counts": counts,
        "output": str(output),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
