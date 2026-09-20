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
import shutil
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
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
SOURCE_PAGE_URL = "https://quranenc.com/en/browse/arabic_seraj"
CSV_URL = "https://quranenc.com/en/home/download/csv/arabic_seraj"
TRANSLATION_LIST_URL = (
    "https://quranenc.com/api/v1/translations/list/ar?localization=en"
)
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


def _walk_objects(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_objects(child)


def _normalized_version(value: object) -> str:
    if not isinstance(value, str):
        return ""
    return value.strip().removeprefix("V").removeprefix("v")


def validate_translation_metadata(raw: bytes) -> dict:
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError("translation-list response is not valid UTF-8 JSON") from exc

    matches = [
        item
        for item in _walk_objects(payload)
        if item.get("key") == TRANSLATION_KEY
    ]
    if len(matches) != 1:
        raise CaptureError(
            f"expected exactly one {TRANSLATION_KEY!r} metadata record; "
            f"found {len(matches)}"
        )

    record = matches[0]
    if record.get("language_iso_code") != "ar":
        raise CaptureError("arabic_seraj metadata is not tagged as Arabic")
    if _normalized_version(record.get("version")) != EXPECTED_VERSION:
        raise CaptureError(
            "upstream version changed: "
            f"expected {EXPECTED_VERSION}, got {record.get('version')!r}"
        )
    return record


def validate_csv_envelope(raw: bytes) -> None:
    if raw.lstrip().startswith((b"<html", b"<!DOCTYPE html", b"<!doctype html")):
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
        metadata = fetcher(TRANSLATION_LIST_URL)
        metadata_record = validate_translation_metadata(metadata.body)

        csv_download = fetcher(CSV_URL)
        validate_csv_envelope(csv_download.body)

        terms = fetcher(TERMS_URL)
        source_page = fetcher(SOURCE_PAGE_URL)

        files: list[tuple[str, Download]] = [
            ("raw/arabic_seraj.csv", csv_download),
            ("raw/translations-list-ar.json", metadata),
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
            "upstream_metadata": {
                "key": metadata_record.get("key"),
                "language_iso_code": metadata_record.get("language_iso_code"),
                "version": metadata_record.get("version"),
                "last_update": metadata_record.get("last_update"),
                "title": metadata_record.get("title"),
            },
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
        provenance_bytes = (
            json.dumps(
                provenance,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            ).encode("utf-8")
            + b"\n"
        )
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


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Capture QuranEnc arabic_seraj v1.0.0 into Source Vault"
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=DEFAULT_OUTPUT,
        help="immutable Source Vault destination",
    )
    args = parser.parse_args()

    try:
        provenance = capture(args.output)
    except (CaptureError, OSError, ValueError) as exc:
        print(f"QuranEnc capture FAILED: {exc}")
        return 1

    print(
        "QuranEnc capture OK: "
        f"{provenance['byte_size']} bytes, {provenance['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
