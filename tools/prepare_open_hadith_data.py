#!/usr/bin/env python3
"""Prepare the vendored Open-Hadith-Data Arabic corpus for Aaris.

This tool is deliberately network-free. It reconstructs any split repository files, verifies their
original upstream Git blob SHA-1 values, converts the nine Arabic collections to Aaris JSONL, copies
license/provenance evidence, and writes a SHA-256 locked manifest consumable by build_hadith.py.

It does not invent books, chapters, translations, grades or commentary that are absent upstream.
"""
import argparse
import csv
import hashlib
import json
import re
import shutil
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_SOURCE = ROOT / "source-vault" / "hadith" / "open-hadith-data"
DEFAULT_OUTPUT = ROOT / "build" / "generated" / "hadith-source"
CATALOG = ROOT / "tools" / "hadith-catalog.json"


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
        verified[collection_id] = {
            "upstream_path": item["path"],
            "git_blob_sha1": actual,
            "local_files": [str(p.relative_to(source)) for p in paths],
            "bytes": sum(p.stat().st_size for p in paths),
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

    catalog = load_catalog()
    edition = "open-hadith-data-" + upstream_commit[:12]
    records_path = records_dir / "open-hadith-data.jsonl"
    counts = {}

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
            reader = csv.reader(joined_lines(resolved[collection_id]), strict=True)
            for row_no, row in enumerate(reader, 1):
                if not row or all(not str(v).strip() for v in row):
                    continue
                if len(row) != 2:
                    raise SystemExit(
                        f"{collection_id}: expected two CSV columns at logical row {row_no}, got {len(row)}")
                number = str(row[0]).strip()
                arabic = str(row[1]).strip()
                if not re.fullmatch(r"[0-9]+", number):
                    raise SystemExit(f"{collection_id}: invalid record number {number!r} at row {row_no}")
                if not arabic:
                    raise SystemExit(f"{collection_id}:{number}: empty Arabic source text")
                if number in seen:
                    raise SystemExit(f"{collection_id}: duplicate record number {number}")
                seen.add(number)

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
            counts[collection_id] = count

    files = {
        "records/open-hadith-data.jsonl": sha256(records_path),
        "LICENSES/ODBL.txt": sha256(licenses_dir / "ODBL.txt"),
        "META/SOURCE.json": sha256(meta_dir / "SOURCE.json"),
    }
    manifest = {
        "pack_id": "aaris-open-hadith-data-arabic-nine",
        "content_version": upstream_commit[:12],
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
