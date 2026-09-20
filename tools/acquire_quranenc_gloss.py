#!/usr/bin/env python3
"""One-shot, fail-closed capture of QuranEnc arabic_seraj v1.0.0.

The official bulk CSV endpoint is not reliably available to cloud CI. QuranEnc
also documents a Surah API, so this acquisition tool preserves the exact 114
Surah response bodies plus the official index/source/terms pages.

This is acquisition infrastructure only. It does not promote the source, build a
runtime pack, create lexical identities, or modify Quran text.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import shutil
import tempfile
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from html.parser import HTMLParser
from pathlib import Path
from typing import Callable
from urllib.error import HTTPError, URLError
from urllib.parse import urlparse
from urllib.request import Request, urlopen


SOURCE_ID = "quran-gloss.quranenc.arabic-seraj.v1.0.0"
SOURCE_NAME = (
    "QuranEnc Arabic Language - Meanings of Words "
    "(As-Siraj fi Bayan Gharib Al-Quran)"
)
TRANSLATION_KEY = "arabic_seraj"
EXPECTED_VERSION = "1.0.0"
EXPECTED_AYAH_COUNT = 6236
RESOURCE_TITLE = "Arabic Language - Meanings of Words"
RESOURCE_BOOK = "As-Siraj fi Bayan Gharib Al-Quran"
SOURCE_INDEX_URL = "https://quranenc.com/en/home"
SOURCE_PAGE_URL = "https://quranenc.com/en/browse/arabic_seraj"
TERMS_URL = "https://quranenc.com/en/home/about/terms-and-conditions"
SURA_URL_TEMPLATE = (
    "https://quranenc.com/api/v1/translation/sura/"
    + TRANSLATION_KEY
    + "/{sura}"
)
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


def _canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(value, ensure_ascii=False, indent=2, sort_keys=True).encode(
            "utf-8"
        )
        + b"\n"
    )


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
            "Accept-Encoding": "identity",
        },
    )

    retryable_statuses = {429, 500, 502, 503, 504}
    for attempt in range(1, 5):
        try:
            with urlopen(request, timeout=45) as response:  # nosec B310: allow-listed host
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
        except HTTPError as exc:
            if exc.code in retryable_statuses and attempt < 4:
                time.sleep(2 ** (attempt - 1))
                continue
            raise CaptureError(f"{url}: HTTP {exc.code}") from exc
        except URLError as exc:
            if attempt < 4:
                time.sleep(2 ** (attempt - 1))
                continue
            raise CaptureError(f"{url}: network error: {exc.reason}") from exc

    raise CaptureError(f"{url}: exhausted download retries")


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


def _walk_objects(value: object):
    if isinstance(value, dict):
        yield value
        for child in value.values():
            yield from _walk_objects(child)
    elif isinstance(value, list):
        for child in value:
            yield from _walk_objects(child)


def validate_sura_response(raw: bytes, expected_sura: int) -> list[int]:
    try:
        payload = json.loads(raw.decode("utf-8-sig"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError(
            f"Surah {expected_sura}: response is not valid UTF-8 JSON"
        ) from exc

    rows = [
        item
        for item in _walk_objects(payload)
        if {"sura", "aya", "translation"}.issubset(item)
    ]
    if not rows:
        raise CaptureError(f"Surah {expected_sura}: no ayah translation rows found")

    ayahs: list[int] = []
    for row in rows:
        try:
            sura = int(row["sura"])
            aya = int(row["aya"])
        except (TypeError, ValueError) as exc:
            raise CaptureError(
                f"Surah {expected_sura}: non-numeric coordinate"
            ) from exc
        if sura != expected_sura or aya < 1:
            raise CaptureError(
                f"Surah {expected_sura}: unexpected coordinate {sura}:{aya}"
            )
        if not isinstance(row.get("translation"), str):
            raise CaptureError(
                f"Surah {expected_sura}:{aya}: translation is not text"
            )
        ayahs.append(aya)

    if len(ayahs) != len(set(ayahs)):
        raise CaptureError(f"Surah {expected_sura}: duplicate ayah rows")
    if sorted(ayahs) != list(range(1, max(ayahs) + 1)):
        raise CaptureError(f"Surah {expected_sura}: non-contiguous ayah sequence")
    return sorted(ayahs)


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


def _build_snapshot_manifest(
    sura_records: list[dict],
    metadata_record: dict,
) -> dict:
    return {
        "schema_version": 1,
        "snapshot_type": "quranenc-sura-api-response-set",
        "source_id": SOURCE_ID,
        "translation_key": TRANSLATION_KEY,
        "version": EXPECTED_VERSION,
        "record_count": EXPECTED_AYAH_COUNT,
        "sura_count": 114,
        "upstream_metadata": metadata_record,
        "suras": sura_records,
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
        source_index = fetcher(SOURCE_INDEX_URL)
        metadata_record = validate_source_index(source_index.body)
        terms = fetcher(TERMS_URL)
        source_page = fetcher(SOURCE_PAGE_URL)

        external_files: list[tuple[str, Download]] = [
            ("SOURCE_INDEX.html", source_index),
            ("LICENSE_SOURCE.html", terms),
            ("SOURCE_PAGE.html", source_page),
        ]
        sura_records: list[dict] = []
        total_ayahs = 0

        for sura in range(1, 115):
            url = SURA_URL_TEMPLATE.format(sura=sura)
            download = fetcher(url)
            ayahs = validate_sura_response(download.body, sura)
            total_ayahs += len(ayahs)
            relative = f"raw/suras/{sura:03d}.json"
            external_files.append((relative, download))
            record = _download_record(download, relative)
            record["sura"] = sura
            record["ayah_count"] = len(ayahs)
            record["first_ayah"] = ayahs[0]
            record["last_ayah"] = ayahs[-1]
            sura_records.append(record)

        if total_ayahs != EXPECTED_AYAH_COUNT:
            raise CaptureError(
                "QuranEnc API coordinate count mismatch: "
                f"expected {EXPECTED_AYAH_COUNT}, got {total_ayahs}"
            )

        for relative, download in external_files:
            destination = stage / relative
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(download.body)

        snapshot_manifest = _build_snapshot_manifest(
            sura_records=sura_records,
            metadata_record=metadata_record,
        )
        snapshot_bytes = _canonical_json_bytes(snapshot_manifest)
        (stage / "raw" / "api-snapshot-manifest.json").write_bytes(snapshot_bytes)

        timestamp = retrieved_at or datetime.now(timezone.utc).replace(
            microsecond=0
        ).isoformat().replace("+00:00", "Z")
        snapshot_rel = (
            "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0/"
            "raw/api-snapshot-manifest.json"
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
            "licence_id": LICENCE_ID,
            "redistribution_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_snapshot": licence_rel,
            "translation_key": TRANSLATION_KEY,
            "snapshot_type": "quranenc-sura-api-response-set",
            "snapshot_manifest": snapshot_rel,
            "snapshot_manifest_sha256": sha256_bytes(snapshot_bytes),
            "snapshot_manifest_byte_size": len(snapshot_bytes),
            "record_count": total_ayahs,
            "sura_count": 114,
            "upstream_metadata": metadata_record,
            "capture_files": [
                _download_record(download, relative)
                for relative, download in external_files
            ],
            "promotion_status": "captured-unreviewed",
            "promotion_note": (
                "Exact upstream Surah API response bytes are preserved. "
                "Production promotion requires a multi-file Source Vault gate, "
                "independent licence/freshness review, and exact coordinate/"
                "content alignment against the trusted Quran Evidence Plane."
            ),
        }
        provenance_bytes = _canonical_json_bytes(provenance)
        (stage / "provenance.json").write_bytes(provenance_bytes)

        checksum_entries = [
            (relative, sha256_bytes(download.body))
            for relative, download in external_files
        ]
        checksum_entries.extend(
            [
                (
                    "raw/api-snapshot-manifest.json",
                    sha256_bytes(snapshot_bytes),
                ),
                ("provenance.json", sha256_bytes(provenance_bytes)),
            ]
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
        "snapshot_type": "quranenc-sura-api-response-set",
        "record_count": EXPECTED_AYAH_COUNT,
        "sura_count": 114,
        "promotion_status": "captured-unreviewed",
    }
    mismatched = [
        key for key, value in expected.items() if provenance.get(key) != value
    ]
    if mismatched:
        raise CaptureError(
            "captured provenance metadata mismatch: " + ", ".join(mismatched)
        )

    source_index_path = output / "SOURCE_INDEX.html"
    terms_path = output / "LICENSE_SOURCE.html"
    source_page_path = output / "SOURCE_PAGE.html"
    for path in (source_index_path, terms_path, source_page_path):
        if not path.is_file() or path.stat().st_size < 1:
            raise CaptureError(f"captured evidence file is missing/empty: {path.name}")

    metadata_record = validate_source_index(source_index_path.read_bytes())
    if provenance.get("upstream_metadata") != metadata_record:
        raise CaptureError("source-index metadata does not match provenance")

    records = provenance.get("capture_files")
    if not isinstance(records, list) or len(records) != 117:
        raise CaptureError("provenance capture_files must contain 117 upstream responses")

    seen: set[str] = set()
    checksum_entries: list[tuple[str, str]] = []
    sura_manifest_records: list[dict] = []
    total_ayahs = 0

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

        if isinstance(relative, str) and relative.startswith("raw/suras/"):
            sura = record.get("sura")
            if not isinstance(sura, int) or sura not in range(1, 115):
                raise CaptureError(f"{relative}: invalid Surah metadata")
            ayahs = validate_sura_response(body, sura)
            if record.get("ayah_count") != len(ayahs):
                raise CaptureError(f"{relative}: ayah count mismatch")
            total_ayahs += len(ayahs)
            sura_manifest_records.append(record)

    if len(sura_manifest_records) != 114:
        raise CaptureError("capture does not contain exactly 114 Surah responses")
    if total_ayahs != EXPECTED_AYAH_COUNT:
        raise CaptureError(
            f"captured ayah total mismatch: {total_ayahs}"
        )

    snapshot_path = output / "raw" / "api-snapshot-manifest.json"
    snapshot_bytes = snapshot_path.read_bytes()
    snapshot = json.loads(snapshot_bytes.decode("utf-8"))
    expected_snapshot = _build_snapshot_manifest(
        sura_records=sorted(sura_manifest_records, key=lambda item: item["sura"]),
        metadata_record=metadata_record,
    )
    if snapshot != expected_snapshot:
        raise CaptureError("API snapshot manifest does not match captured responses")
    if snapshot_bytes != _canonical_json_bytes(snapshot):
        raise CaptureError("API snapshot manifest is not canonical project JSON")
    snapshot_hash = sha256_bytes(snapshot_bytes)
    if provenance.get("snapshot_manifest_sha256") != snapshot_hash:
        raise CaptureError("snapshot manifest SHA-256 does not match provenance")
    if provenance.get("snapshot_manifest_byte_size") != len(snapshot_bytes):
        raise CaptureError("snapshot manifest byte size does not match provenance")
    checksum_entries.append(("raw/api-snapshot-manifest.json", snapshot_hash))

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
    except (CaptureError, OSError, ValueError, json.JSONDecodeError) as exc:
        print(f"QuranEnc capture FAILED: {exc}")
        return 1

    action = "verification" if args.validate_existing else "capture"
    print(
        f"QuranEnc {action} OK: "
        f"{provenance['sura_count']} Surahs, "
        f"{provenance['record_count']} ayahs, "
        f"snapshot {provenance['snapshot_manifest_sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
