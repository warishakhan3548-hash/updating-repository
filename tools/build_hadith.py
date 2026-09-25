#!/usr/bin/env python3
"""Deterministic, network-free builder for an Aaris offline Hadith pack.

The builder imports only source files already present under source-vault. Every imported file must
be declared by SHA-256 and at least one license/permission artifact must be present. It never
scrapes, downloads, guesses a grade, or rewrites source display text.
"""
import argparse
import hashlib
import json
import re
import sqlite3
import unicodedata
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
CATALOG = ROOT / "tools" / "hadith-catalog.json"
BUILDER_VERSION = "9"


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


def normalize_arabic(value: str) -> str:
    value = unicodedata.normalize("NFC", value)
    value = (value.replace("ٱ", "ا").replace("أ", "ا").replace("إ", "ا").replace("آ", "ا")
                  .replace("ى", "ي").replace("ؤ", "و").replace("ئ", "ي").replace("ـ", ""))
    out = []
    for ch in value:
        if not unicodedata.category(ch).startswith("M"):
            out.append(ch)
    return re.sub(r"\s+", " ", "".join(out)).strip()


def normalize_latin(value):
    if not value:
        return ""
    value = unicodedata.normalize("NFKD", value).lower()
    value = "".join(ch for ch in value if not unicodedata.category(ch).startswith("M"))
    return re.sub(r"\s+", " ", value).strip()



def search_text(value):
    # Match Java TextMatch.normalize without stripping Devanagari vowel signs.
    value = re.sub(r'\[\d+\]', ' ', str(value or '')).replace("'", '').replace('’', '')
    value = unicodedata.normalize('NFKC', value).lower()
    for original, normalized in [('ٱ','ا'),('أ','ا'),('إ','ا'),('آ','ا'),('ى','ي'),('ی','ي'),('ک','ك')]:
        value=value.replace(original,normalized)
    chars=[]
    for ch in value:
        cp=ord(ch)
        if (0x610 <= cp <= 0x61a or 0x64b <= cp <= 0x65f or 0x6d6 <= cp <= 0x6ed
                or 0x8d3 <= cp <= 0x8ff or 0x898 <= cp <= 0x89f
                or cp in (0x670,0x640) or unicodedata.category(ch) == 'Cf'):
            continue
        if ch.isdecimal():
            ch=str(unicodedata.decimal(ch))
        if ch.isalpha() and 'LATIN' in unicodedata.name(ch,''):
            chars.extend(c for c in unicodedata.normalize('NFD',ch) if not unicodedata.category(c).startswith('M'))
        else:
            chars.append(ch if ch.isalnum() or unicodedata.category(ch).startswith('M') else ' ')
    return ' '.join(''.join(chars).split())


DEV_CONSONANTS = {
    'क':'k','ख':'kh','ग':'g','घ':'gh','ङ':'ng','च':'ch','छ':'chh','ज':'j','झ':'jh','ञ':'ny',
    'ट':'t','ठ':'th','ड':'d','ढ':'dh','ण':'n','त':'t','थ':'th','द':'d','ध':'dh','न':'n',
    'प':'p','फ':'ph','ब':'b','भ':'bh','म':'m','य':'y','र':'r','ल':'l','ळ':'l','व':'v',
    'श':'sh','ष':'sh','स':'s','ह':'h','क़':'q','ख़':'kh','ग़':'gh','ज़':'z','ड़':'d','ढ़':'dh','फ़':'f','य़':'y',
}
DEV_VOWELS = {'अ':'a','आ':'a','इ':'i','ई':'i','उ':'u','ऊ':'u','ऋ':'ri','ए':'e','ऐ':'ai','ओ':'o','औ':'au'}
DEV_MATRAS = {'ा':'a','ि':'i','ी':'i','ु':'u','ू':'u','ृ':'ri','े':'e','ै':'ai','ो':'o','ौ':'au'}

def romanize_hindi(value):
    """Lossy search-only Devanagari -> Hinglish shadow; never used for display."""
    out=[]; consonant=False
    def finish():
        nonlocal consonant
        if consonant and out and out[-1].endswith('a'):
            out[-1]=out[-1][:-1]
        consonant=False
    for ch in str(value or ''):
        if ch in DEV_CONSONANTS:
            out.append(DEV_CONSONANTS[ch]+'a'); consonant=True; continue
        if ch in DEV_VOWELS:
            out.append(DEV_VOWELS[ch]); consonant=False; continue
        if ch in DEV_MATRAS:
            if consonant and out and out[-1].endswith('a'): out[-1]=out[-1][:-1]
            out.append(DEV_MATRAS[ch]); consonant=False; continue
        if ch=='्':
            if consonant and out and out[-1].endswith('a'): out[-1]=out[-1][:-1]
            consonant=False; continue
        if ch=='़':
            if out:
                if out[-1].endswith('ja'): out[-1]=out[-1][:-2]+'za'
                elif out[-1].endswith('pha'): out[-1]=out[-1][:-3]+'fa'
                elif out[-1].endswith('ka'): out[-1]=out[-1][:-2]+'qa'
            consonant=True; continue
        if ch in ('ं','ँ'):
            out.append('n'); consonant=False; continue
        if ch=='ः':
            out.append('h'); consonant=False; continue
        if ch.isdecimal():
            finish(); out.append(str(unicodedata.decimal(ch))); continue
        if ch.isalnum():
            finish(); out.append(ch.lower())
        else:
            finish(); out.append(' ')
    finish()
    return ' '.join(''.join(out).split())


def search_tokens(value):
    return set(search_text(value).split())


def build_search_index(db):
    editorial = {}
    for hadith_id,text in db.execute(
            "SELECT hadith_id,text FROM editorial_translation WHERE status IN ('reviewed','released') ORDER BY hadith_id,rowid"):
        editorial.setdefault(hadith_id, []).append(text)
    contexts = {}
    for hadith_id,text,roman in db.execute(
            "SELECT hadith_id,text,roman FROM search_context ORDER BY hadith_id,id"):
        contexts.setdefault(hadith_id, []).extend(v for v in (text, roman) if v)

    # Keep the phrase lane multilingual too. FTS is built from immutable source/display strings;
    # it never rewrites a translation or calls a runtime service.
    for rowid,hadith_id,collection_id,record_number,ar,en,ur,bn in db.execute(
            'SELECT rowid,id,collection_id,record_number,arabic,english,urdu,bangla FROM hadith'):
        translated = ' '.join(str(v or '') for v in (en,ur,bn))
        extra = ' '.join(editorial.get(hadith_id, []) + contexts.get(hadith_id, []))
        db.execute(
            'INSERT INTO hadith_fts(hadith_id,collection_id,record_number,arabic,latin) VALUES(?,?,?,?,?)',
            (hadith_id, collection_id, record_number, search_text(ar), search_text((translated+' '+extra).strip()))
        )
        terms=search_tokens(' '.join(str(v or '') for v in (ar,en,ur,bn))+' '+extra)
        db.executemany('INSERT OR IGNORE INTO search_token VALUES(?,?)', ((t,rowid) for t in sorted(terms)))
    db.execute('INSERT INTO search_vocabulary SELECT token,count(*) FROM search_token GROUP BY token')
    for (token,) in db.execute('SELECT token FROM search_vocabulary ORDER BY token'):
        value = "^" + token + chr(36)
        grams = sorted({value[i:i+3] for i in range(max(0, len(value)-2))})
        db.executemany('INSERT OR IGNORE INTO search_gram VALUES(?,?)', ((g,token) for g in grams))


def title_key(value):
    value = unicodedata.normalize("NFKD", str(value or "")).casefold()
    return "".join(ch for ch in value if ch.isalnum())


def safe_source_path(source_dir: Path, rel: str) -> Path:
    if not isinstance(rel, str) or not rel or rel.startswith("/") or ".." in Path(rel).parts:
        raise ValueError(f"Unsafe source path: {rel!r}")
    root = source_dir.resolve()
    path = (source_dir / rel).resolve()
    if path != root and root not in path.parents:
        raise ValueError(f"Source path escapes pack: {rel}")
    return path


def load_manifest(source_dir: Path):
    path = source_dir / "manifest.json"
    if not path.is_file():
        raise ValueError("Missing hadith manifest.json")
    manifest = json.loads(path.read_text(encoding="utf-8"))
    for key in ("pack_id", "content_version", "source_name", "source_version", "redistribution_basis"):
        require_string(manifest, key)
    if manifest.get("runtime_network_required") is True:
        raise ValueError("Offline Hadith pack may not require runtime network access")

    files = manifest.get("files")
    if not isinstance(files, dict) or not files:
        raise ValueError("Manifest must declare source files and SHA-256 hashes")
    license_files = manifest.get("license_files")
    if not isinstance(license_files, list) or not license_files:
        raise ValueError("At least one license/permission file must be declared")

    declared = set(files)
    for rel in license_files:
        if not isinstance(rel, str) or not rel:
            raise ValueError("Invalid license file entry")
        if rel not in files:
            raise ValueError(f"License/permission file must also be SHA-256 locked in files: {rel}")
        p = safe_source_path(source_dir, rel)
        if not p.is_file():
            raise ValueError(f"Missing license/permission file: {rel}")

    for rel, expected in files.items():
        if not isinstance(rel, str) or not isinstance(expected, str) or len(expected) != 64:
            raise ValueError(f"Invalid source declaration: {rel!r}")
        p = safe_source_path(source_dir, rel)
        if not p.is_file():
            raise ValueError(f"Missing source file: {rel}")
        actual = digest(p)
        if actual != expected:
            raise ValueError(f"Source hash mismatch: {rel}")

    undeclared_jsonl = {
        str(p.relative_to(source_dir))
        for p in source_dir.rglob("*.jsonl")
        if str(p.relative_to(source_dir)) not in declared
    }
    if undeclared_jsonl:
        raise ValueError("Undeclared JSONL source files: " + ", ".join(sorted(undeclared_jsonl)))
    return manifest


def open_db(path: Path):
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.unlink(missing_ok=True)
    db = sqlite3.connect(tmp)
    db.execute("PRAGMA foreign_keys=ON")
    db.executescript("""
    PRAGMA page_size=4096;
    PRAGMA user_version=2;

    CREATE TABLE collection(
      id TEXT PRIMARY KEY,
      group_name TEXT NOT NULL,
      name_en TEXT NOT NULL,
      name_ar TEXT NOT NULL,
      kind TEXT NOT NULL,
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
      record_kind TEXT NOT NULL,
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

    CREATE VIRTUAL TABLE hadith_fts USING fts4(
      hadith_id,
      collection_id,
      record_number,
      arabic,
      latin,
      tokenize=unicode61
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

    CREATE TABLE editorial_translation(
      id TEXT PRIMARY KEY,
      hadith_id TEXT NOT NULL,
      language TEXT NOT NULL,
      text TEXT NOT NULL,
      revision TEXT NOT NULL,
      status TEXT NOT NULL,
      source_ref TEXT NOT NULL,
      UNIQUE(hadith_id, language, revision),
      FOREIGN KEY(hadith_id) REFERENCES hadith(id)
    );

    CREATE TABLE search_context(
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      hadith_id TEXT NOT NULL,
      language TEXT NOT NULL,
      kind TEXT NOT NULL,
      text TEXT NOT NULL,
      roman TEXT NOT NULL,
      source_ref TEXT NOT NULL,
      FOREIGN KEY(hadith_id) REFERENCES hadith(id)
    );

    CREATE TABLE search_token(token TEXT NOT NULL,hadith_rowid INTEGER NOT NULL,PRIMARY KEY(token,hadith_rowid)) WITHOUT ROWID;
    CREATE TABLE search_vocabulary(token TEXT PRIMARY KEY,df INTEGER NOT NULL) WITHOUT ROWID;
    CREATE TABLE search_gram(gram TEXT NOT NULL,token TEXT NOT NULL,PRIMARY KEY(gram,token)) WITHOUT ROWID;
    CREATE TABLE provenance(
      key TEXT PRIMARY KEY,
      value TEXT NOT NULL
    );

    CREATE INDEX hadith_by_collection ON hadith(collection_id, record_number);
    CREATE INDEX hadith_by_number ON hadith(record_number);
    CREATE INDEX hadith_by_book ON hadith(book_id, record_number);
    CREATE INDEX hadith_by_chapter ON hadith(chapter_id, record_number);
    CREATE INDEX hadith_reference_lookup ON hadith_reference(scheme, value);
    CREATE INDEX hadith_reference_value ON hadith_reference(value, hadith_id);
    -- Legacy whole-text B-tree shadows were never used by runtime retrieval. FTS/search_token
    -- are the bounded search paths; omitting these duplicate indexes saves substantial storage.
    CREATE INDEX editorial_translation_lookup
      ON editorial_translation(hadith_id,language,status,revision);
    CREATE INDEX search_context_lookup ON search_context(hadith_id,language,kind);
    """)
    return db, tmp


def canonical_text_hash(arabic: str) -> str:
    return hashlib.sha256(arabic.encode("utf-8")).hexdigest()


def insert_collection(db, row, manifest):
    values = (
        require_string(row, "id"),
        require_string(row, "group"),
        require_string(row, "name_en"),
        require_string(row, "name_ar"),
        str(row.get("kind") or "hadith"),
        require_string(row, "edition"),
        manifest["source_name"],
        manifest["source_version"],
    )
    db.execute("INSERT INTO collection VALUES(?,?,?,?,?,?,?,?)", values)


def insert_hadith(db, row, seen):
    hid = require_string(row, "id")
    if hid in seen:
        raise ValueError(f"Duplicate hadith id {hid}")
    seen.add(hid)
    arabic = require_string(row, "arabic")
    declared = row.get("source_sha256")
    actual = canonical_text_hash(arabic)
    if declared is not None and declared != actual:
        raise ValueError(f"Arabic text hash mismatch for {hid}")
    english = row.get("english")
    db.execute("""INSERT INTO hadith VALUES(
        ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""", (
        hid,
        require_string(row, "collection_id"),
        row.get("book_id"),
        row.get("chapter_id"),
        require_string(row, "record_number"),
        str(row.get("record_kind") or "hadith"),
        arabic,
        english,
        row.get("urdu"),
        row.get("bangla"),
        row.get("narrator_en"),
        row.get("isnad_ar"),
        row.get("isnad_en"),
        row.get("matn_ar"),
        row.get("matn_en"),
        require_string(row, "source_ref"),
        actual,
        normalize_arabic(arabic),
        normalize_latin(english),
    ))
    for ref in row.get("references", []):
        db.execute(
            "INSERT INTO hadith_reference(hadith_id,scheme,value) VALUES(?,?,?)",
            (hid, require_string(ref, "scheme"), require_string(ref, "value")),
        )
    for grade in row.get("grades", []):
        db.execute(
            "INSERT INTO grade_assertion VALUES(?,?,?,?,?)",
            (
                require_string(grade, "id"),
                hid,
                require_string(grade, "grade"),
                require_string(grade, "grader"),
                require_string(grade, "source_version"),
            ),
        )
    for item in row.get("editorial_translations", []):
        language = require_string(item, "language").lower()
        revision = require_string(item, "revision")
        status = require_string(item, "status").lower()
        if status not in {"draft", "reviewed", "released"}:
            raise ValueError(f"Unsupported editorial translation status {status!r} for {hid}")
        eid = str(item.get("id") or f"{hid}:T:{language}:{revision}")
        db.execute(
            "INSERT INTO editorial_translation VALUES(?,?,?,?,?,?,?)",
            (
                eid,
                hid,
                language,
                require_string(item, "text"),
                revision,
                status,
                require_string(item, "source_ref"),
            ),
        )
    for item in row.get("search_contexts", []):
        language = require_string(item, "language").lower()
        kind = require_string(item, "kind").lower()
        text = require_string(item, "text")
        if kind not in {"title", "explanation", "benefits", "word_meanings"}:
            raise ValueError(f"Unsupported search context kind {kind!r} for {hid}")
        db.execute(
            "INSERT INTO search_context(hadith_id,language,kind,text,roman,source_ref) VALUES(?,?,?,?,?,?)",
            (
                hid, language, kind, text,
                romanize_hindi(text) if language == "hi" else "",
                require_string(item, "source_ref"),
            ),
        )


def import_jsonl(db, source_dir: Path, manifest):
    seen = set()
    counters = {"collection": 0, "book": 0, "chapter": 0, "hadith": 0, "translation": 0, "context": 0}
    for rel in manifest["files"]:
        if not rel.endswith(".jsonl"):
            continue
        path = safe_source_path(source_dir, rel)
        with path.open(encoding="utf-8") as f:
            for line_no, raw in enumerate(f, 1):
                if not raw.strip():
                    continue
                try:
                    row = json.loads(raw)
                    kind = row.get("type", "hadith")
                    if kind == "collection":
                        insert_collection(db, row, manifest)
                        counters["collection"] += 1
                    elif kind == "book":
                        db.execute(
                            "INSERT INTO book VALUES(?,?,?,?,?)",
                            (
                                require_string(row, "id"),
                                require_string(row, "collection_id"),
                                require_string(row, "number"),
                                row.get("name_en"),
                                row.get("name_ar"),
                            ),
                        )
                        counters["book"] += 1
                    elif kind == "chapter":
                        db.execute(
                            "INSERT INTO chapter VALUES(?,?,?,?,?,?)",
                            (
                                require_string(row, "id"),
                                require_string(row, "collection_id"),
                                row.get("book_id"),
                                require_string(row, "number"),
                                row.get("name_en"),
                                row.get("name_ar"),
                            ),
                        )
                        counters["chapter"] += 1
                    elif kind == "hadith":
                        insert_hadith(db, row, seen)
                        counters["hadith"] += 1
                        counters["translation"] += len(row.get("editorial_translations", []))
                        counters["context"] += len(row.get("search_contexts", []))
                    else:
                        raise ValueError(f"Unknown record type {kind}")
                except Exception as e:
                    raise ValueError(f"{rel}:{line_no}: {e}") from e

    if counters["collection"] == 0:
        raise ValueError("No collections imported")
    if counters["hadith"] == 0:
        raise ValueError("No Hadith records imported; refusing to create an empty installed pack")

    required = manifest.get("required_collection_ids")
    if required is not None:
        if not isinstance(required, list) or not required:
            raise ValueError("required_collection_ids must be a non-empty list")
        actual = {row[0] for row in db.execute("SELECT id FROM collection")}
        missing = sorted(set(required) - actual)
        extra = sorted(actual - set(required))
        if missing or (manifest.get("exact_collection_set", False) and extra):
            raise ValueError(f"Collection coverage mismatch; missing={missing}, extra={extra}")

    if manifest.get("require_catalog_complete", False):
        catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
        expected_titles = {
            title_key(item["name_en"])
            for item in catalog.get("collections", [])
            if str(item.get("name_en") or "").strip() and item.get("kind") != "group"
        }
        expected_titles.update(
            title_key(item["name_en"])
            for item in catalog.get("nested_collections", [])
            if str(item.get("name_en") or "").strip()
        )
        actual_titles = {
            title_key(row[0])
            for row in db.execute("SELECT name_en FROM collection")
            if str(row[0] or "").strip()
        }
        missing_titles = sorted(expected_titles - actual_titles)
        if missing_titles:
            raise ValueError("Full Hadith catalog not present; missing titles: " + ", ".join(missing_titles))
    return counters


def build(source_dir: Path, output: Path):
    manifest = load_manifest(source_dir)
    db, tmp = open_db(output)
    try:
        counters = import_jsonl(db, source_dir, manifest)
        build_search_index(db)
        # Report actual per-record language coverage, combining imported source columns and
        # reviewed/released editorial source layers without double-counting the same Hadith id.
        coverage = {"ar": counters["hadith"]}
        source_columns = {"en": "english", "ur": "urdu", "bn": "bangla"}
        editorial_languages = {
            row[0] for row in db.execute(
                "SELECT DISTINCT language FROM editorial_translation WHERE status IN ('reviewed','released')")
        }
        for language in sorted(set(source_columns) | editorial_languages):
            column = source_columns.get(language)
            if column:
                coverage[language] = db.execute(
                    f"""SELECT count(*) FROM (
                        SELECT id AS hadith_id FROM hadith
                        WHERE {column} IS NOT NULL AND trim({column})<>''
                        UNION
                        SELECT hadith_id FROM editorial_translation
                        WHERE language=? AND status IN ('reviewed','released')
                    )""", (language,)
                ).fetchone()[0]
            else:
                coverage[language] = db.execute(
                    "SELECT count(DISTINCT hadith_id) FROM editorial_translation "
                    "WHERE language=? AND status IN ('reviewed','released')", (language,)
                ).fetchone()[0]

        marked = sum(bool(re.search(r"[\u064b-\u0652\u0670]", text)) for (text,) in db.execute("SELECT arabic FROM hadith"))
        if manifest.get("require_vowel_marks") and marked != counters["hadith"]:
            raise ValueError("Vocalized pack contains records without source vowel marks")
        required_mark_collections = manifest.get("require_vowel_marks_collection_ids", [])
        if required_mark_collections:
            if not isinstance(required_mark_collections, list):
                raise ValueError("require_vowel_marks_collection_ids must be a list")
            for collection_id in required_mark_collections:
                total = db.execute("SELECT count(*) FROM hadith WHERE collection_id=?", (collection_id,)).fetchone()[0]
                vocalized = sum(
                    bool(re.search(r"[\u064b-\u0652\u0670]", text))
                    for (text,) in db.execute("SELECT arabic FROM hadith WHERE collection_id=?", (collection_id,))
                )
                if total < 1 or vocalized != total:
                    raise ValueError(f"{collection_id}: required source vowel marks are incomplete")
        languages = {code for code, count in coverage.items() if count}
        provenance = {
            "pack_id": manifest["pack_id"],
            "content_version": manifest["content_version"],
            "source_name": manifest["source_name"],
            "source_version": manifest["source_version"],
            "redistribution_basis": manifest["redistribution_basis"],
            "builder_version": BUILDER_VERSION,
            "record_count": str(counters["hadith"]),
        }
        db.executemany("INSERT INTO provenance VALUES(?,?)", provenance.items())
        db.commit()
        if db.execute("PRAGMA integrity_check").fetchone()[0] != "ok":
            raise ValueError("SQLite integrity check failed")
        broken = db.execute("PRAGMA foreign_key_check").fetchall()
        if broken:
            raise ValueError(f"Broken foreign keys: {broken[:5]}")
        duplicate_refs = db.execute(
            "SELECT collection_id,record_number,COUNT(*) FROM hadith GROUP BY collection_id,record_number HAVING COUNT(*)>1 LIMIT 5"
        ).fetchall()
        if duplicate_refs and manifest.get("record_number_unique_within_collection", False):
            raise ValueError(f"Duplicate collection record numbers: {duplicate_refs}")
        db.execute("VACUUM")
        db.close()
        tmp.replace(output)

        output_hash = digest(output)
        generated = {
            "schema_version": 2,
            "pack_id": manifest["pack_id"],
            "content_version": manifest["content_version"],
            "source_name": manifest["source_name"],
            "source_version": manifest["source_version"],
            "redistribution_basis": manifest["redistribution_basis"],
            "builder_version": BUILDER_VERSION,
            "sqlite_sha256": output_hash,
            "sqlite_bytes": output.stat().st_size,
            "collections": counters["collection"],
            "books": counters["book"],
            "chapters": counters["chapter"],
            "records": counters["hadith"],
            "editorial_translations": counters["translation"],
            "search_contexts": counters["context"],
            "language_coverage": sorted(languages),
            "imported_translation_record_counts": coverage,
            "arabic_records_with_vowel_marks": marked,
            "vocalization_note": "Presence of some marks does not establish complete or reviewed vocalization.",
            "vocalization": manifest.get("vocalization"),
            "vocalized_required_collection_ids": manifest.get("require_vowel_marks_collection_ids", []),
            "hadeethenc_translation_record_counts": manifest.get("hadeethenc_translation_record_counts", {}),
            "hadeethenc_withheld_translation_ids": manifest.get("hadeethenc_withheld_translation_ids", {}),
            "source_files": {rel: digest(safe_source_path(source_dir, rel)) for rel in manifest["files"]},
            "license_files": list(manifest["license_files"]),
            "runtime_network_required": False,
        }
        manifest_output = output.parent / "hadith-manifest.json"
        manifest_output.write_text(json.dumps(generated, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        print(json.dumps(generated, ensure_ascii=False, indent=2))
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
    args = parser.parse_args()
    build(args.source.resolve(), args.output.resolve())


if __name__ == "__main__":
    main()
