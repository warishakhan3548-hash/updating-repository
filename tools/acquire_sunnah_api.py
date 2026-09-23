#!/usr/bin/env python3
"""One-time, resumable importer for the official Sunnah.com API.

This is NOT a website scraper. It uses the documented https://api.sunnah.com/v1/ API and requires
an API key plus explicit permission/license evidence supplied by the operator. The resulting source
vault is self-contained; Aaris never needs the API at runtime.

The script intentionally defaults to fail-closed behavior:
- no API key on disk;
- no source pack without a permission file;
- no silent missing Arabic;
- no duplicate canonical IDs;
- no final manifest until every discovered collection finishes.
"""
import argparse
import hashlib
import json
import os
import shutil
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DEFAULT_CATALOG = ROOT / "tools" / "hadith-catalog.json"
DEFAULT_OUTPUT = ROOT / "source-vault" / "hadith" / "active"


def sha256(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def compact(value):
    return json.dumps(value, ensure_ascii=False, separators=(",", ":"))


def safe_component(value: str) -> str:
    out = []
    for ch in value:
        out.append(ch if ch.isalnum() or ch in "-_." else "_")
    return "".join(out).strip("._") or "item"


def language_map(items):
    out = {}
    for item in items or []:
        lang = str(item.get("lang") or "").lower()
        if lang:
            out[lang] = item
    return out


def text_for(languages, *codes):
    for code in codes:
        item = languages.get(code)
        if item:
            body = item.get("body")
            if isinstance(body, str) and body.strip():
                return body.strip()
    return None


def translated_field(items, field, *codes):
    by_lang = language_map(items)
    for code in codes:
        item = by_lang.get(code)
        if item:
            value = item.get(field)
            if isinstance(value, str) and value.strip():
                return value.strip()
    return None


class Api:
    def __init__(self, base, key, delay):
        self.base = base.rstrip("/") + "/"
        self.key = key
        self.delay = max(0.25, delay)
        self.last = 0.0

    def get(self, path, params=None):
        target = urllib.parse.urljoin(self.base, path.lstrip("/"))
        if params:
            target += "?" + urllib.parse.urlencode(params)
        for attempt in range(6):
            wait = self.delay - (time.monotonic() - self.last)
            if wait > 0:
                time.sleep(wait)
            req = urllib.request.Request(
                target,
                headers={"X-API-Key": self.key, "Accept": "application/json", "User-Agent": "Aaris-Quran-offline-importer/1"},
            )
            try:
                with urllib.request.urlopen(req, timeout=45) as response:
                    self.last = time.monotonic()
                    return json.loads(response.read().decode("utf-8"))
            except urllib.error.HTTPError as e:
                self.last = time.monotonic()
                if e.code in (401, 403):
                    raise RuntimeError("Sunnah API key was rejected") from e
                if e.code == 429 or 500 <= e.code < 600:
                    if attempt == 5:
                        raise
                    retry = e.headers.get("Retry-After")
                    time.sleep(float(retry) if retry and retry.isdigit() else min(60, 2 ** attempt))
                    continue
                raise
            except (urllib.error.URLError, TimeoutError):
                self.last = time.monotonic()
                if attempt == 5:
                    raise
                time.sleep(min(60, 2 ** attempt))
        raise RuntimeError("API request did not complete")

    def pages(self, path, params=None):
        page = 1
        params = dict(params or {})
        while True:
            params["limit"] = 100
            params["page"] = page
            payload = self.get(path, params)
            for item in payload.get("data", []):
                yield item
            nxt = payload.get("next")
            if nxt is None:
                break
            page = int(nxt)


def catalog_groups(path: Path):
    data = json.loads(path.read_text(encoding="utf-8"))
    mapping = {}
    expected_titles = set()
    for item in data.get("collections", []):
        title = str(item.get("name_en") or "").strip()
        if title:
            expected_titles.add(title.casefold())
            mapping[title.casefold()] = str(item.get("group") or "other")
    return mapping, expected_titles


def collection_titles(collection):
    items = language_map(collection.get("collection"))
    en = items.get("en") or {}
    ar = items.get("ar") or {}
    return (
        str(en.get("title") or collection.get("name") or "").strip(),
        str(ar.get("title") or "").strip(),
    )


def fetch_raw_collection(api: Api, collection, raw_dir: Path):
    slug = str(collection["name"])
    folder = raw_dir / safe_component(slug)
    folder.mkdir(parents=True, exist_ok=True)
    complete = folder / "complete.json"
    if complete.is_file():
        return

    (folder / "collection.json").write_text(json.dumps(collection, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    books = list(api.pages(f"collections/{urllib.parse.quote(slug, safe='')}/books")) if collection.get("hasBooks") else []
    (folder / "books.json").write_text(json.dumps(books, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    chapters = []
    if collection.get("hasChapters"):
        for book in books:
            number = str(book.get("bookNumber"))
            for chapter in api.pages(
                f"collections/{urllib.parse.quote(slug, safe='')}/books/{urllib.parse.quote(number, safe='')}/chapters"
            ):
                chapters.append(chapter)
    (folder / "chapters.json").write_text(json.dumps(chapters, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")

    hadith_path = folder / "hadiths.jsonl.raw"
    seen = set()
    with hadith_path.open("w", encoding="utf-8") as out:
        if books:
            for book in books:
                number = str(book.get("bookNumber"))
                endpoint = f"collections/{urllib.parse.quote(slug, safe='')}/books/{urllib.parse.quote(number, safe='')}/hadiths"
                for hadith in api.pages(endpoint):
                    key = (str(hadith.get("collection")), str(hadith.get("hadithNumber")), str(hadith.get("bookNumber")))
                    if key in seen:
                        continue
                    seen.add(key)
                    out.write(compact(hadith) + "\n")
        else:
            for hadith in api.pages("hadiths", {"collection": slug}):
                key = (str(hadith.get("collection")), str(hadith.get("hadithNumber")), str(hadith.get("bookNumber")))
                if key in seen:
                    continue
                seen.add(key)
                out.write(compact(hadith) + "\n")

    complete.write_text(
        json.dumps({"collection": slug, "records": len(seen), "completed_at": datetime.now(timezone.utc).isoformat()}, indent=2) + "\n",
        encoding="utf-8",
    )


def normalize_collection(folder: Path, group_by_title, edition, source_version, out):
    collection = json.loads((folder / "collection.json").read_text(encoding="utf-8"))
    slug = str(collection["name"])
    title_en, title_ar = collection_titles(collection)
    group = group_by_title.get(title_en.casefold(), "other")
    out.write(compact({
        "type": "collection", "id": slug, "group": group,
        "name_en": title_en or slug, "name_ar": title_ar or slug,
        "kind": "hadith", "edition": edition,
    }) + "\n")

    books = json.loads((folder / "books.json").read_text(encoding="utf-8"))
    for book in books:
        number = str(book.get("bookNumber"))
        variants = language_map(book.get("book"))
        out.write(compact({
            "type": "book", "id": f"{slug}:book:{number}", "collection_id": slug, "number": number,
            "name_en": (variants.get("en") or {}).get("name"),
            "name_ar": (variants.get("ar") or {}).get("name"),
        }) + "\n")

    chapters = json.loads((folder / "chapters.json").read_text(encoding="utf-8"))
    chapter_ids = set()
    for chapter in chapters:
        book_number = str(chapter.get("bookNumber"))
        chapter_id = str(chapter.get("chapterId"))
        cid = f"{slug}:book:{book_number}:chapter:{chapter_id}"
        chapter_ids.add((book_number, chapter_id))
        variants = language_map(chapter.get("chapter"))
        out.write(compact({
            "type": "chapter", "id": cid, "collection_id": slug,
            "book_id": f"{slug}:book:{book_number}", "number": chapter_id,
            "name_en": (variants.get("en") or {}).get("chapterTitle"),
            "name_ar": (variants.get("ar") or {}).get("chapterTitle"),
        }) + "\n")

    count = 0
    with (folder / "hadiths.jsonl.raw").open(encoding="utf-8") as raw:
        for line_no, line in enumerate(raw, 1):
            if not line.strip():
                continue
            item = json.loads(line)
            number = str(item.get("hadithNumber") or "").strip()
            book_number = str(item.get("bookNumber") or "").strip()
            chapter_id = str(item.get("chapterId") or "").strip()
            if not number:
                raise ValueError(f"{slug} raw line {line_no}: missing hadithNumber")
            languages = language_map(item.get("hadith"))
            arabic = text_for(languages, "ar", "ara", "arabic")
            if not arabic:
                raise ValueError(f"{slug}:{number}: official API response has no Arabic body")

            references = [{"scheme": "sunnah-api-ref", "value": f"{slug}:{number}"}]
            grades = []
            grade_seen = set()
            for lang, variant in languages.items():
                urn = variant.get("urn")
                if urn is not None:
                    references.append({"scheme": f"sunnah-api-urn-{lang}", "value": str(urn)})
                for grade in variant.get("grades") or []:
                    grader = str(grade.get("graded_by") or "").strip()
                    value = str(grade.get("grade") or "").strip()
                    if not grader or not value or (grader, value) in grade_seen:
                        continue
                    grade_seen.add((grader, value))
                    gid = hashlib.sha256(f"{slug}|{number}|{grader}|{value}|{source_version}".encode()).hexdigest()[:24]
                    grades.append({
                        "id": f"G:{gid}", "grade": value, "grader": grader, "source_version": source_version
                    })

            chapter_fk = None
            if book_number and chapter_id and (book_number, chapter_id) in chapter_ids:
                chapter_fk = f"{slug}:book:{book_number}:chapter:{chapter_id}"
            book_fk = f"{slug}:book:{book_number}" if book_number else None
            hid = f"H:{slug}:{edition}:{book_number or '0'}:{number}"
            out.write(compact({
                "type": "hadith", "id": hid, "collection_id": slug,
                "book_id": book_fk, "chapter_id": chapter_fk, "record_number": number,
                "record_kind": "hadith", "arabic": arabic,
                "english": text_for(languages, "en", "eng", "english"),
                "urdu": text_for(languages, "ur", "urd", "urdu"),
                "bangla": text_for(languages, "bn", "ben", "bangla", "bengali"),
                "source_ref": f"sunnah-api:{slug}:{number}",
                "references": references, "grades": grades,
            }) + "\n")
            count += 1
    return slug, title_en, count


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--base-url", default="https://api.sunnah.com/v1/")
    parser.add_argument("--key-env", default="SUNNAH_API_KEY")
    parser.add_argument("--permission-file", type=Path, required=True,
                        help="Written API/offline redistribution permission or applicable license evidence.")
    parser.add_argument("--redistribution-basis", required=True,
                        help="Short factual description of the permission/license recorded in the vault.")
    parser.add_argument("--source-version", default=None)
    parser.add_argument("--delay-seconds", type=float, default=1.1)
    parser.add_argument("--allow-partial-catalog", action="store_true")
    parser.add_argument("--refresh", action="store_true", help="Discard cached raw API snapshots and reacquire them.")
    args = parser.parse_args()

    key = os.environ.get(args.key_env, "").strip()
    if not key:
        raise SystemExit(f"Set {args.key_env} in the environment; API keys are never stored in git.")
    if not args.permission_file.is_file():
        raise SystemExit("Permission/license evidence file does not exist.")

    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    raw_dir = output / "raw"
    records_dir = output / "records"
    licenses_dir = output / "LICENSES"
    if args.refresh and raw_dir.exists():
        shutil.rmtree(raw_dir)
    if records_dir.exists():
        shutil.rmtree(records_dir)
    raw_dir.mkdir(exist_ok=True)
    records_dir.mkdir(exist_ok=True)
    licenses_dir.mkdir(exist_ok=True)
    permission_copy = licenses_dir / "SUNNAH_API_PERMISSION.txt"
    shutil.copyfile(args.permission_file, permission_copy)

    group_by_title, expected_titles = catalog_groups(args.catalog)
    api = Api(args.base_url, key, args.delay_seconds)
    collections = list(api.pages("collections"))
    if not collections:
        raise SystemExit("The official API returned no collections.")

    returned_titles = {collection_titles(c)[0].casefold() for c in collections if collection_titles(c)[0]}
    missing_titles = sorted(expected_titles - returned_titles)
    if missing_titles and not args.allow_partial_catalog:
        raise SystemExit(
            "Official API does not currently expose every catalog target. Missing: " + ", ".join(missing_titles) +
            ". No active pack was finalized. Use --allow-partial-catalog only for development."
        )

    (raw_dir / "collections.json").write_text(json.dumps(collections, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    for index, collection in enumerate(collections, 1):
        slug = collection.get("name")
        print(f"[{index}/{len(collections)}] acquiring {slug}", flush=True)
        fetch_raw_collection(api, collection, raw_dir)

    source_version = args.source_version or datetime.now(timezone.utc).strftime("api-v1-%Y%m%d")
    edition = source_version.replace(":", "-").replace("/", "-")
    imported = []
    for collection in collections:
        slug = str(collection["name"])
        folder = raw_dir / safe_component(slug)
        normalized = records_dir / (safe_component(slug) + ".jsonl")
        with normalized.open("w", encoding="utf-8") as out:
            imported.append(normalize_collection(folder, group_by_title, edition, source_version, out))

    source_files = []
    for p in sorted(output.rglob("*")):
        if not p.is_file() or p.name == "manifest.json":
            continue
        source_files.append(p)

    files = {str(p.relative_to(output)): sha256(p) for p in source_files}
    manifest = {
        "pack_id": f"sunnah-official-api-{edition}",
        "content_version": datetime.now(timezone.utc).strftime("%Y.%m.%d"),
        "source_name": "Sunnah.com official API",
        "source_version": source_version,
        "redistribution_basis": args.redistribution_basis,
        "license_files": [str(permission_copy.relative_to(output))],
        "files": files,
        "required_collection_ids": [str(c["name"]) for c in collections],
        "exact_collection_set": True,
        "require_catalog_complete": not args.allow_partial_catalog,
        "catalog_complete": not missing_titles,
        "catalog_missing_titles": missing_titles,
        "acquired_at": datetime.now(timezone.utc).isoformat(),
        "runtime_network_required": False,
    }
    (output / "manifest.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    total = sum(item[2] for item in imported)
    print(json.dumps({"collections": len(imported), "records": total, "manifest": str(output / "manifest.json")}, indent=2))


if __name__ == "__main__":
    main()
