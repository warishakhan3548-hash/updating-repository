#!/usr/bin/env python3
"""One-shot, fail-closed capture of QuranEnc arabic_seraj v1.0.0.

This tool is acquisition infrastructure only. It preserves upstream bytes exactly
and records provenance. It does not promote the source, build a runtime pack, or
modify Quran text.
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import re
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Callable
from urllib.parse import urlparse
from urllib.request import Request, urlopen


SOURCE_ID = "quran-gloss.quranenc.arabic-seraj.v1.0.0"
SOURCE_NAME = (
    "QuranEnc Arabic Language - Meanings of Words "
    "(As-Siraj fi Bayan Gharib Al-Quran)"
)
TRANSLATION_KEY = "arabic_seraj"
EXPECTED_VERSION = "1.0.0"
RESOURCE_TITLE = "Arabic Language - Meanings of Words"
RESOURCE_BOOK = "As-Siraj fi Bayan Gharib Al-Quran"
SOURCE_INDEX_URL = "https://quranenc.com/en/home"
SOURCE_PAGE_URL = "https://quranenc.com/en/browse/arabic_seraj"
CSV_URL = "https://quranenc.com/en/home/download/csv/arabic_seraj"
TERMS_URL = "https://quranenc.com/en/home/about/terms-and-conditions"
LICENCE_ID = "quranenc-republication-terms"
DEFAULT_OUTPUT = Path(
    "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0"
)
ALLOWED_HOSTS = {"quranenc.com", "www.quranenc.com"}
USER_AGENT = (
    "Aaris-Quran-Source-Vault/1.0 "
    "(https://github.com/warishakhan3548-hash/updating-repository)"
)


class CaptureError(RuntimeError):
    pass


@dataclass(frozen=True)
class Download:
    requested_url: str
    final_url: str
    status: int
    content_type: str | None
    etag: str | None
    last_modified: str | None
    body: bytes


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.parts.append(data)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _require_quranenc_https(url: str, label: str) -> None:
    parsed = urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in ALLOWED_HOSTS:
        raise CaptureError(f"{label} escaped trusted QuranEnc HTTPS hosts: {url}")


def fetch_https(url: str) -> Download:
    _require_quranenc_https(url, "requested URL")
    request = Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept": "*/*",
        },
    )
    with urlopen(request, timeout=45) as response:  # nosec B310: host is allow-listed
        final_url = response.geturl()
        _require_quranenc_https(final_url, "final URL")
        status = int(getattr(response, "status", response.getcode()))
        if status != 200:
            raise CaptureError(f"{url}: HTTP {status}")
        body = response.read()
        if not body:
            raise CaptureError(f"{url}: empty response")
        return Download(
            requested_url=url,
            final_url=final_url,
            status=status,
            content_type=response.headers.get("Content-Type"),
            etag=response.headers.get("ETag"),
            last_modified=response.headers.get("Last-Modified"),
            body=body,
        )


def validate_source_index(raw: bytes) -> dict:
    try:
        html = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise CaptureError("QuranEnc source index is not UTF-8") from exc

    parser = _TextExtractor()
    try:
        parser.feed(html)
        parser.close()
    except Exception as exc:
        raise CaptureError("QuranEnc source index HTML could not be parsed") from exc

    text = " ".join(" ".join(parser.parts).split())
    title_at = text.find(RESOURCE_TITLE)
    if title_at < 0:
        raise CaptureError(
            f"official source index does not list {RESOURCE_TITLE!r}"
        )

    before = text[max(0, title_at - 160):title_at]
    after = text[title_at:title_at + 420]
    versions = re.findall(r"\b[Vv]?(\d+\.\d+\.\d+)\b", before)
    if not versions:
        raise CaptureError("resource version is not adjacent to its source-index title")

    observed_version = versions[-1]
    if observed_version != EXPECTED_VERSION:
        raise CaptureError(
            "upstream version changed: "
            f"expected {EXPECTED_VERSION}, got {observed_version!r}"
        )
    if RESOURCE_BOOK not in after:
        raise CaptureError(
            "source-index title is not followed by the expected As-Siraj attribution"
        )

    return {
        "key": TRANSLATION_KEY,
        "language_iso_code": "ar",
        "version": observed_version,
        "title": RESOURCE_TITLE,
        "description": f'From the book "{RESOURCE_BOOK}".',
    }


def validate_csv_envelope(raw: bytes) -> None:
    stripped = raw.lstrip().lower()
    if stripped.startswith((b"<html", b"<!doctype html")):
        raise CaptureError("CSV endpoint returned HTML instead of CSV")

    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError as exc:
        raise CaptureError("CSV is not UTF-8/UTF-8-BOM") from exc

    sample = text[:16384]
    try:
        dialect = csv.Sniffer().sniff(sample)
    except csv.Error as exc:
        raise CaptureError("CSV delimiter could not be identified") from exc

    rows = csv.reader(io.StringIO(text), dialect)
    try:
        header = next(rows)
    except StopIteration as exc:
        raise CaptureError("CSV has no rows") from exc

    if len(header) < 3:
        raise CaptureError("CSV header has fewer than three columns")

    # Acquisition is intentionally less opinionated than promotion. We only
    # reject obvious wrong/empty artifacts here; exact schema and coordinate
    # mapping are audited after the immutable bytes are captured.
    observed = 0
    for row in rows:
        if row:
            observed += 1
        if observed >= 100:
            break
    if observed < 100:
        raise CaptureError("CSV has too few data rows to be the Quran resource")


def _download_record(download: Download, relative_path: str) -> dict:
    return {
        "path": relative_path,
        "requested_url": download.requested_url,
        "final_url": download.final_url,
        "http_status": download.status,
        "content_type": download.content_type,
        "etag": download.etag,
        "last_modified": download.last_modified,
        "byte_size": len(download.body),
        "sha256": sha256_bytes(download.body),
    }


def _safe_capture_member(root: Path, raw: object) -> Path:
    if not isinstance(raw, str) or not raw:
        raise CaptureError("capture file path is missing")
    relative = Path(raw)
    if relative.is_absolute() or ".." in relative.parts:
        raise CaptureError(f"unsafe capture file path: {raw!r}")
    path = root / relative
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise CaptureError(f"capture file escaped root: {raw!r}") from exc
    if not path.is_file():
        raise CaptureError(f"missing captured file: {raw}")
    return path


def _canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode(
            "utf-8"
        )
        + b"\n"
    )


def capture(
    output: Path,
    fetcher: Callable[[str], Download] = fetch_https,
    *,
    retrieved_at: str | None = None,
) -> dict:
    output = output.resolve()
    if output.exists():
        raise CaptureError(
            f"refusing to overwrite immutable Source Vault path: {output}"
        )

    parent = output.parent
    parent.mkdir(parents=True, exist_ok=True)
    stage = Path(
        tempfile.mkdtemp(prefix=f".{output.name}.capture-", dir=str(parent))
    )

    try:
        source_index = fetcher(SOURCE_INDEX_URL)
        metadata_record = validate_source_index(source_index.body)

        csv_download = fetcher(CSV_URL)
        validate_csv_envelope(csv_download.body)

        terms = fetcher(TERMS_URL)
        source_page = fetcher(SOURCE_PAGE_URL)

        files: list[tuple[str, Download]] = [
            ("raw/arabic_seraj.csv", csv_download),
            ("SOURCE_INDEX.html", source_index),
            ("LICENSE_SOURCE.html", terms),
            ("SOURCE_PAGE.html", source_page),
        ]

        for relative, download in files:
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(download.body)

        timestamp = retrieved_at or datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat().replace("+00:00", "Z")

        primary_rel = (
            "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/"
            "raw/arabic_seraj.csv"
        )
        licence_rel = (
            "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/"
            "LICENSE_SOURCE.html"
        )

        provenance = {
            "schema_version": 1,
            "source_id": SOURCE_ID,
            "source_name": SOURCE_NAME,
            "original_url": SOURCE_PAGE_URL,
            "version": EXPECTED_VERSION,
            "retrieved_at": timestamp,
            "sha256": sha256_bytes(csv_download.body),
            "byte_size": len(csv_download.body),
            "licence_id": LICENCE_ID,
            "redistribution_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_snapshot": licence_rel,
            "project_mirror": primary_rel,
            "translation_key": TRANSLATION_KEY,
            "upstream_metadata": metadata_record,
            "capture_files": [
                _download_record(download, relative)
                for relative, download in files
            ],
            "promotion_status": "captured-unreviewed",
            "promotion_note": (
                "Exact upstream bytes are preserved. Production promotion "
                "requires independent licence-scope, CSV schema, coordinate, "
                "content, and freshness review."
            ),
        }
        provenance_bytes = _canonical_json_bytes(provenance)
        (stage / "provenance.json").write_bytes(provenance_bytes)

        checksum_entries = [
            (relative, sha256_bytes(download.body))
            for relative, download in files
        ]
        checksum_entries.append(
            ("provenance.json", sha256_bytes(provenance_bytes))
        )
        checksums = "".join(
            f"{digest}  {relative}\n"
            for relative, digest in sorted(checksum_entries)
        ).encode("utf-8")
        (stage / "sha256.txt").write_bytes(checksums)

        os.replace(stage, output)
        return provenance
    except Exception:
        shutil.rmtree(stage, ignore_errors=True)
        raise


def validate_existing(output: Path) -> dict:
    output = output.resolve()
    if not output.is_dir():
        raise CaptureError(f"captured Source Vault directory is missing: {output}")

    provenance_path = output / "provenance.json"
    try:
        provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError("captured provenance.json is invalid") from exc

    expected = {
        "schema_version": 1,
        "source_id": SOURCE_ID,
        "source_name": SOURCE_NAME,
        "original_url": SOURCE_PAGE_URL,
        "version": EXPECTED_VERSION,
        "licence_id": LICENCE_ID,
        "redistribution_allowed": True,
        "modification_allowed": False,
        "attribution_required": True,
        "translation_key": TRANSLATION_KEY,
        "promotion_status": "captured-unreviewed",
    }
    mismatched = [
        key for key, value in expected.items() if provenance.get(key) != value
    ]
    if mismatched:
        raise CaptureError(
            "captured provenance metadata mismatch: " + ", ".join(mismatched)
        )

    csv_path = output / "raw" / "arabic_seraj.csv"
    source_index_path = output / "SOURCE_INDEX.html"
    terms_path = output / "LICENSE_SOURCE.html"
    source_page_path = output / "SOURCE_PAGE.html"

    for path in (csv_path, source_index_path, terms_path, source_page_path):
        if not path.is_file() or path.stat().st_size < 1:
            raise CaptureError(f"captured evidence file is missing/empty: {path.name}")

    csv_bytes = csv_path.read_bytes()
    validate_csv_envelope(csv_bytes)
    metadata_record = validate_source_index(source_index_path.read_bytes())

    if provenance.get("upstream_metadata") != metadata_record:
        raise CaptureError("source-index metadata does not match provenance")
    if provenance.get("sha256") != sha256_bytes(csv_bytes):
        raise CaptureError("primary CSV SHA-256 does not match provenance")
    if provenance.get("byte_size") != len(csv_bytes):
        raise CaptureError("primary CSV byte size does not match provenance")

    records = provenance.get("capture_files")
    if not isinstance(records, list) or len(records) != 4:
        raise CaptureError("provenance capture_files must contain four records")

    seen: set[str] = set()
    checksum_entries: list[tuple[str, str]] = []
    for record in records:
        if not isinstance(record, dict):
            raise CaptureError("capture_files entry is not an object")
        relative = record.get("path")
        if relative in seen:
            raise CaptureError(f"duplicate capture file record: {relative!r}")
        seen.add(relative)
        path = _safe_capture_member(output, relative)
        body = path.read_bytes()
        if record.get("byte_size") != len(body):
            raise CaptureError(f"{relative}: byte size mismatch")
        digest = sha256_bytes(body)
        if record.get("sha256") != digest:
            raise CaptureError(f"{relative}: SHA-256 mismatch")
        if record.get("http_status") != 200:
            raise CaptureError(f"{relative}: captured HTTP status is not 200")
        _require_quranenc_https(record.get("requested_url", ""), "requested URL")
        _require_quranenc_https(record.get("final_url", ""), "final URL")
        checksum_entries.append((str(relative), digest))

    provenance_bytes = provenance_path.read_bytes()
    if provenance_bytes != _canonical_json_bytes(provenance):
        raise CaptureError("provenance.json is not in canonical project format")
    checksum_entries.append(("provenance.json", sha256_bytes(provenance_bytes)))

    expected_checksums = "".join(
        f"{digest}  {relative}\n"
        for relative, digest in sorted(checksum_entries)
    ).encode("utf-8")
    actual_checksums = (output / "sha256.txt").read_bytes()
    if actual_checksums != expected_checksums:
        raise CaptureError("sha256.txt does not match preserved capture bytes")

    return provenance


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Capture or verify QuranEnc arabic_seraj v1.0.0 Source Vault bytes"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="immutable Source Vault destination",
    )
    parser.add_argument(
        "--validate-existing",
        action="store_true",
        help="verify an already captured directory without network access",
    )
    args = parser.parse_args()

    try:
        provenance = (
            validate_existing(args.output)
            if args.validate_existing
            else capture(args.output)
        )
    except (CaptureError, OSError, ValueError) as exc:
        print(f"QuranEnc capture FAILED: {exc}")
        return 1

    action = "verification" if args.validate_existing else "capture"
    print(
        f"QuranEnc {action} OK: "
        f"{provenance['byte_size']} bytes, {provenance['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
