#!/usr/bin/env python3
"""Deterministic, network-free builder for an Aaris offline Hadith pack.

The builder imports only files already present in source-vault. Every input is hash-locked by the
pack manifest. Display/source text is preserved; normalized shadows are generated only for search.
"""
import argparse
import hashlib
import json
import re
import sqlite3
import unicodedata
from pathlib import Path

BUILDER_VERSION = "2"
SCHEMA_VERSION = 2

def digest(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()

def required(obj, key):
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        raise ValueError(f"Missing/invalid {key}")
    return value.strip()

def norm_ar(text):
    text = unicodedata.normalize("NFC", text or "")
    out = []
    for ch in text:
        if unicodedata.category(ch).startswith("M") or ch == "\u0640":
            continue
        out.append({"ٱ":"ا","أ":"ا","إ":"ا","آ":"ا","ى":"ي","ؤ":"و","ئ":"ي"}.get(ch, ch))
    return re.sub(r"\s+", " ", "".join(out)).strip()

def norm_latin(text):
    text = unicodedata.normalize("NFKD", text or "").casefold()
    text = "".join(ch for ch in text if not unicodedata.category(ch).startswith("M"))
    return re.sub(r"\s+", " ", text).strip()

def load_manifest(source_dir: Path):
    path = source_dir / "manifest.json"
    if not path.is_file():
        raise ValueError("Missing hadith manifest.json")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    for key in ("pack_id","content_version","source_name","source_version","redistribution_basis"):
        required(manifest, key)
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
        if not isinstance(expected, str) or len(expected) != 64:
            raise ValueError(f"Invalid SHA-256 declaration: {rel}")
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
    db.executescript(f"""
    PRAGMA page_size=4096;
    PRAGMA user_version={SCHEMA_VERSION};

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
      search_ar TEXT NOT NULL,
      search_latin TEXT NOT NULL,
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

    CREATE TABLE provenance(key TEXT PRIMARY KEY, value TEXT NOT NULL);

    CREATE INDEX hadith_by_collection ON hadith(collection_id, record_number);
    CREATE INDEX hadith_by_book ON hadith(book_id, record_number);
    CREATE INDEX hadith_by_chapter ON hadith(chapter_id, record_number);
    CREATE INDEX reference_by_value ON hadith_reference(value);
    """)
    return db, tmp

def text_hash(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()

def import_jsonl(db, source_dir: Path, manifest):
    total = 0
    seen = set()
    collections = set()
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
                    cid = required(row, "id")
                    if cid in collections:
                        raise ValueError(f"Duplicate collection {cid} at {rel}:{line_no}")
                    collections.add(cid)
                    db.execute("INSERT INTO collection VALUES(?,?,?,?,?,?,?)", (
                        cid, required(row, "group"), required(row, "name_en"),
                        required(row, "name_ar"), required(row, "edition"),
                        manifest["source_name"], manifest["source_version"]))
                elif kind == "book":
                    db.execute("INSERT INTO book VALUES(?,?,?,?,?)", (
                        required(row, "id"), required(row, "collection_id"),
                        required(row, "number"), row.get("name_en"), row.get("name_ar")))
                elif kind == "chapter":
                    db.execute("INSERT INTO chapter VALUES(?,?,?,?,?,?)", (
                        required(row, "id"), required(row, "collection_id"), row.get("book_id"),
                        required(row, "number"), row.get("name_en"), row.get("name_ar")))
                elif kind == "hadith":
                    hid = required(row, "id")
                    if hid in seen:
                        raise ValueError(f"Duplicate hadith id {hid} at {rel}:{line_no}")
                    seen.add(hid)
                    arabic = required(row, "arabic")
                    actual = text_hash(arabic)
                    declared = row.get("source_sha256")
                    if declared is not None and declared != actual:
                        raise ValueError(f"Arabic text hash mismatch for {hid}")
                    english = row.get("english")
                    urdu = row.get("urdu")
                    bangla = row.get("bangla")
                    narrator = row.get("narrator_en")
                    matn_ar = row.get("matn_ar")
                    matn_en = row.get("matn_en")
                    search_ar = norm_ar(" ".join(x for x in (arabic, matn_ar) if x))
                    search_latin = norm_latin(" ".join(x for x in
                        (english, urdu, bangla, narrator, matn_en, row.get("source_ref")) if x))
                    db.execute("""INSERT INTO hadith VALUES(
                        ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (
                        hid, required(row, "collection_id"), row.get("book_id"),
                        row.get("chapter_id"), required(row, "record_number"), arabic,
                        english, urdu, bangla, narrator, row.get("isnad_ar"), row.get("isnad_en"),
                        matn_ar, matn_en, required(row, "source_ref"), actual,
                        search_ar, search_latin))
                    for ref in row.get("references", []):
                        db.execute("INSERT INTO hadith_reference(hadith_id,scheme,value) VALUES(?,?,?)",
                                   (hid, required(ref, "scheme"), required(ref, "value")))
                    for grade in row.get("grades", []):
                        db.execute("INSERT INTO grade_assertion VALUES(?,?,?,?,?)", (
                            required(grade, "id"), hid, required(grade, "grade"),
                            required(grade, "grader"), required(grade, "source_version")))
                    total += 1
                else:
                    raise ValueError(f"Unknown record type {kind} at {rel}:{line_no}")
    if total == 0:
        raise ValueError("No Hadith records imported; refusing to create an empty installed pack")
    if not collections:
        raise ValueError("No Hadith collections imported")
    return total, len(collections)

def build(source_dir: Path, output: Path, manifest_output: Path):
    manifest = load_manifest(source_dir)
    db, tmp = open_db(output)
    try:
        total, collection_count = import_jsonl(db, source_dir, manifest)
        provenance = {
            "pack_id": manifest["pack_id"],
            "content_version": manifest["content_version"],
            "source_name": manifest["source_name"],
            "source_version": manifest["source_version"],
            "redistribution_basis": manifest["redistribution_basis"],
            "builder_version": BUILDER_VERSION,
            "record_count": str(total),
            "collection_count": str(collection_count),
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
        result = {
            "schema_version": SCHEMA_VERSION,
            "pack_id": manifest["pack_id"],
            "content_version": manifest["content_version"],
            "source_name": manifest["source_name"],
            "source_version": manifest["source_version"],
            "redistribution_basis": manifest["redistribution_basis"],
            "builder_version": BUILDER_VERSION,
            "collections": collection_count,
            "records": total,
            "sqlite_sha256": digest(output),
            "update_policy": "APK_BUNDLED_ONLY",
        }
        manifest_output.parent.mkdir(parents=True, exist_ok=True)
        manifest_output.write_text(json.dumps(result, indent=2, ensure_ascii=False)+"\n",
                                   encoding="utf-8")
        print(json.dumps(result, indent=2, ensure_ascii=False))
    except Exception:
        try:
            db.close()
        except Exception:
            pass
        tmp.unlink(missing_ok=True)
        raise

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--output", default=Path("app/src/main/assets/hadith.sqlite"), type=Path)
    parser.add_argument("--manifest-output",
                        default=Path("app/src/main/assets/hadith-manifest.json"), type=Path)
    args = parser.parse_args()
    build(args.source.resolve(), args.output.resolve(), args.manifest_output.resolve())

if __name__ == "__main__":
    main()
