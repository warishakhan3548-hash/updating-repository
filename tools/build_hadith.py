#!/usr/bin/env python3
"""Deterministic builder for an Aaris offline Hadith pack.

This tool intentionally performs no network access. It only imports source files that already
exist locally and whose hashes/license metadata are declared by the pack manifest.
"""
import argparse
import hashlib
import json
import sqlite3
from pathlib import Path

BUILDER_VERSION = "1"

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def require_string(obj, key):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing/invalid {key}")
    return value.strip()

def load_manifest(source_dir: Path):
    path = source_dir / "manifest.json"
    if not path.is_file():
        raise ValueError("Missing hadith manifest.json")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    require_string(manifest, "pack_id")
    require_string(manifest, "content_version")
    require_string(manifest, "source_name")
    require_string(manifest, "source_version")
    require_string(manifest, "redistribution_basis")
    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("Manifest must declare source files and SHA-256 hashes")
    license_files = manifest.get("license_files")
    if not isinstance(license_files, list) or not license_files:
        raise ValueError("At least one license/permission file must be declared")
    for rel in license_files:
        p = source_dir / rel
        if not p.is_file():
            raise ValueError(f"Missing license/permission file: {rel}")
    for rel, expected in files.items():
        p = source_dir / rel
        if not p.is_file():
            raise ValueError(f"Missing source file: {rel}")
        actual = digest(p)
        if actual != expected:
            raise ValueError(f"Source hash mismatch: {rel}")
    return manifest

def open_db(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""
    PRAGMA page_size=4096;
    PRAGMA user_version=1;

    CREATE TABLE collection(
      id TEXT PRIMARY KEY,
      group_name TEXT NOT NULL,
      name_en TEXT NOT NULL,
      name_ar TEXT NOT NULL,
      edition TEXT NOT NULL,
      source_name TEXT NOT NULL,
      source_version TEXT NOT NULL
    );

    CREATE TABLE book(
      id TEXT PRIMARY KEY,
      collection_id TEXT NOT NULL,
      number TEXT NOT NULL,
      name_en TEXT,
      name_ar TEXT,
      UNIQUE(collection_id, number),
      FOREIGN KEY(collection_id) REFERENCES collection(id)
    );

    CREATE TABLE chapter(
      id TEXT PRIMARY KEY,
      collection_id TEXT NOT NULL,
      book_id TEXT,
      number TEXT NOT NULL,
      name_en TEXT,
      name_ar TEXT,
      FOREIGN KEY(collection_id) REFERENCES collection(id),
      FOREIGN KEY(book_id) REFERENCES book(id)
    );

    CREATE TABLE hadith(
      id TEXT PRIMARY KEY,
      collection_id TEXT NOT NULL,
      book_id TEXT,
      chapter_id TEXT,
      record_number TEXT NOT NULL,
      arabic TEXT NOT NULL,
      english TEXT,
      urdu TEXT,
      bangla TEXT,
      narrator_en TEXT,
      isnad_ar TEXT,
      isnad_en TEXT,
      matn_ar TEXT,
      matn_en TEXT,
      source_ref TEXT NOT NULL,
      source_sha256 TEXT NOT NULL,
      FOREIGN KEY(collection_id) REFERENCES collection(id),
      FOREIGN KEY(book_id) REFERENCES book(id),
      FOREIGN KEY(chapter_id) REFERENCES chapter(id)
    );

    CREATE TABLE hadith_reference(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      hadith_id TEXT NOT NULL,
      scheme TEXT NOT NULL,
      value TEXT NOT NULL,
      UNIQUE(hadith_id, scheme, value),
      FOREIGN KEY(hadith_id) REFERENCES hadith(id)
    );

    CREATE TABLE grade_assertion(
      id TEXT PRIMARY KEY,
      hadith_id TEXT NOT NULL,
      grade TEXT NOT NULL,
      grader TEXT NOT NULL,
      source_version TEXT NOT NULL,
      FOREIGN KEY(hadith_id) REFERENCES hadith(id)
    );

    CREATE TABLE provenance(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE INDEX hadith_by_collection ON hadith(collection_id, record_number);
    CREATE INDEX hadith_by_book ON hadith(book_id, record_number);
    CREATE INDEX hadith_by_chapter ON hadith(chapter_id, record_number);
    """)
    return db, tmp

def canonical_text_hash(arabic: str) -> str:
    return hashlib.sha256(arabic.encode("utf-8")).hexdigest()

def import_jsonl(db, source_dir: Path, manifest):
    total = 0
    seen = set()
    for rel in manifest["files"]:
        if not rel.endswith(".jsonl"):
            continue
        path = source_dir / rel
        with path.open(encoding="utf-8") as f:
            for line_no, raw in enumerate(f, 1):
                if not raw.strip():
                    continue
                row = json.loads(raw)
                kind = row.get("type", "hadith")
                if kind == "collection":
                    values = (
                        require_string(row, "id"), require_string(row, "group"),
                        require_string(row, "name_en"), require_string(row, "name_ar"),
                        require_string(row, "edition"), manifest["source_name"],
                        manifest["source_version"],
                    )
                    db.execute("INSERT INTO collection VALUES(?,?,?,?,?,?,?)", values)
                elif kind == "book":
                    db.execute("INSERT INTO book VALUES(?,?,?,?,?)", (
                        require_string(row, "id"), require_string(row, "collection_id"),
                        require_string(row, "number"), row.get("name_en"), row.get("name_ar")))
                elif kind == "chapter":
                    db.execute("INSERT INTO chapter VALUES(?,?,?,?,?,?)", (
                        require_string(row, "id"), require_string(row, "collection_id"),
                        row.get("book_id"), require_string(row, "number"),
                        row.get("name_en"), row.get("name_ar")))
                elif kind == "hadith":
                    hid = require_string(row, "id")
                    if hid in seen:
                        raise ValueError(f"Duplicate hadith id {hid} at {rel}:{line_no}")
                    seen.add(hid)
                    arabic = require_string(row, "arabic")
                    declared = row.get("source_sha256")
                    actual = canonical_text_hash(arabic)
                    if declared is not None and declared != actual:
                        raise ValueError(f"Arabic text hash mismatch for {hid}")
                    db.execute("""INSERT INTO hadith VALUES(
                        ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (
                        hid, require_string(row, "collection_id"), row.get("book_id"),
                        row.get("chapter_id"), require_string(row, "record_number"),
                        arabic, row.get("english"), row.get("urdu"), row.get("bangla"),
                        row.get("narrator_en"), row.get("isnad_ar"), row.get("isnad_en"),
                        row.get("matn_ar"), row.get("matn_en"),
                        require_string(row, "source_ref"), actual))
                    for ref in row.get("references", []):
                        db.execute("INSERT INTO hadith_reference(hadith_id,scheme,value) VALUES(?,?,?)",
                                   (hid, require_string(ref, "scheme"), require_string(ref, "value")))
                    for grade in row.get("grades", []):
                        gid = require_string(grade, "id")
                        db.execute("INSERT INTO grade_assertion VALUES(?,?,?,?,?)", (
                            gid, hid, require_string(grade, "grade"),
                            require_string(grade, "grader"),
                            require_string(grade, "source_version")))
                    total += 1
                else:
                    raise ValueError(f"Unknown record type {kind} at {rel}:{line_no}")
    if total == 0:
        raise ValueError("No Hadith records imported; refusing to create an empty installed pack")
    return total

def build(source_dir: Path, output: Path):
    manifest = load_manifest(source_dir)
    db, tmp = open_db(output)
    try:
        total = import_jsonl(db, source_dir, manifest)
        provenance = {
            "pack_id": manifest["pack_id"],
            "content_version": manifest["content_version"],
            "source_name": manifest["source_name"],
            "source_version": manifest["source_version"],
            "redistribution_basis": manifest["redistribution_basis"],
            "builder_version": BUILDER_VERSION,
            "record_count": str(total),
        }
        db.executemany("INSERT INTO provenance VALUES(?,?)", provenance.items())
        db.commit()
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("SQLite integrity check failed")
        broken = db.execute("PRAGMA foreign_key_check").fetchall()
        if broken:
            raise ValueError(f"Broken foreign keys: {broken[:5]}")
        db.execute("VACUUM")
        db.close()
        tmp.replace(output)
        print(json.dumps({"records": total, "output": str(output),
                          "sha256": digest(output)}, indent=2))
    except Exception:
        db.close()
        tmp.unlink(missing_ok=True)
        raise

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", default=Path("app/src/main/assets/hadith.sqlite"), type=Path)
    args = parser.parse_args()
    build(args.source.resolve(), args.output.resolve())

if __name__ == "__main__":
    main()
