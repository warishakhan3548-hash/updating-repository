#!/usr/bin/env python3
"""One-shot, fail-closed capture of QuranEnc arabic_seraj v1.0.0.

This is acquisition tooling only. It never updates the Source Vault registry and it is
not used by normal builds. The captured snapshot must still be reviewed before any
registry promotion or runtime pack can consume it.
"""
from __future__ import annotations

import argparse
from dataclasses import dataclass
from datetime import datetime, timezone
import hashlib
import io
import json
import re
from html.parser import HTMLParser
from pathlib import Path
import tarfile
import tempfile
from typing import Callable, Iterable
from urllib.parse import urlparse
from urllib.request import Request, urlopen

if __package__:
    from tools.quran_core import EXPECTED_AYAH_COUNTS
else:
    from quran_core import EXPECTED_AYAH_COUNTS

SOURCE_ID = "quran-gloss.quranenc.arabic-seraj.v1.0.0"
SOURCE_NAME = (
    "QuranEnc Arabic Language - Meanings of Words "
    "(As-Siraj fi Bayan Gharib Al-Quran)"
)
TRANSLATION_KEY = "arabic_seraj"
EXPECTED_VERSION = "1.0.0"
EXPECTED_AYAH_COUNT = sum(EXPECTED_AYAH_COUNTS)
RESOURCE_TITLE = "Arabic Language - Meanings of Words"
RESOURCE_BOOK = "As-Siraj fi Bayan Gharib Al-Quran"
BASE_URL = "https://quranenc.com"
SOURCE_INDEX_URL = f"{BASE_URL}/en/home"
SOURCE_PAGE_URL = f"{BASE_URL}/en/browse/{TRANSLATION_KEY}"
PRESERVED_TERMS_URL = f"{BASE_URL}/en/home/about/terms-and-conditions"
LIST_URL = f"{BASE_URL}/api/v1/translations/list/ar/?localization=en"
TERMS_URL = f"{BASE_URL}/en/home/api"
BROWSE_URL = f"{BASE_URL}/en/browse/{TRANSLATION_KEY}"
VAULT_RELATIVE = Path(
    "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0"
)
REGISTRY_RELATIVE = Path("source-vault/registry.json")
PRESERVED_SNAPSHOT_FIELDS = (
    "vault_artifact",
    "licence_snapshot",
    "provenance",
    "sha256",
    "licence_sha256",
    "provenance_sha256",
    "byte_size",
)
ALLOWED_HOSTS = frozenset({"quranenc.com", "www.quranenc.com"})
MAX_RESPONSE_BYTES = 8 * 1024 * 1024


class CaptureError(RuntimeError):
    pass


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__(convert_charrefs=True)
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        if data.strip():
            self.parts.append(data)


@dataclass(frozen=True, slots=True)
class FetchResult:
    requested_url: str
    final_url: str
    status: int
    content_type: str | None
    body: bytes


Fetcher = Callable[[str], FetchResult]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _validate_https_quranenc(url: str, *, label: str) -> None:
    parsed = urlparse(url)
    host = (parsed.hostname or "").lower()
    if parsed.scheme != "https" or host not in ALLOWED_HOSTS:
        raise CaptureError(
            f"{label} must remain on approved QuranEnc HTTPS hosts: {url}"
        )


def fetch_https(url: str, *, timeout: float = 30.0) -> FetchResult:
    _validate_https_quranenc(url, label="requested URL")
    req = Request(
        url,
        headers={
            "User-Agent": "Aaris-Quran-SourceVault-Capture/1.0",
            "Accept": "application/json,text/html;q=0.9,*/*;q=0.1",
        },
    )
    with urlopen(req, timeout=timeout) as response:  # nosec B310
        status = int(getattr(response, "status", response.getcode()))
        final_url = response.geturl()
        _validate_https_quranenc(final_url, label="final URL")
        if status != 200:
            raise CaptureError(
                f"unexpected HTTP status {status} for {url}"
            )
        body = response.read(MAX_RESPONSE_BYTES + 1)
        if len(body) > MAX_RESPONSE_BYTES:
            raise CaptureError(
                f"response exceeds {MAX_RESPONSE_BYTES} bytes: {url}"
            )
        content_type = response.headers.get("Content-Type")
    return FetchResult(url, final_url, status, content_type, body)


def _validate_result(result: FetchResult, *, label: str) -> None:
    _validate_https_quranenc(
        result.requested_url, label=f"{label} requested URL"
    )
    _validate_https_quranenc(
        result.final_url, label=f"{label} final URL"
    )
    if result.status != 200:
        raise CaptureError(
            f"unexpected HTTP status {result.status} "
            f"for {result.requested_url}"
        )
    if len(result.body) > MAX_RESPONSE_BYTES:
        raise CaptureError(
            f"{label} exceeds {MAX_RESPONSE_BYTES} bytes"
        )
    if not result.body:
        raise CaptureError(f"{label} response is empty")


def _json(data: bytes, *, label: str):
    try:
        return json.loads(data.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError(
            f"{label} is not valid UTF-8 JSON"
        ) from exc


def _translation_entries(payload) -> list[dict]:
    if not isinstance(payload, list) or not all(
        isinstance(item, dict) for item in payload
    ):
        raise CaptureError(
            "translation list API returned an unexpected shape"
        )
    return payload


def _selected_translation(
    raw: bytes, *, enforce_version: bool = True
) -> dict:
    entries = _translation_entries(
        _json(raw, label="translation list")
    )
    matches = [
        entry for entry in entries
        if entry.get("key") == TRANSLATION_KEY
    ]
    if len(matches) != 1:
        raise CaptureError(
            f"expected exactly one {TRANSLATION_KEY!r} "
            f"translation entry, found {len(matches)}"
        )
    selected = matches[0]
    version = (
        str(selected.get("version", ""))
        .removeprefix("V")
        .removeprefix("v")
    )
    if enforce_version and version != EXPECTED_VERSION:
        raise CaptureError(
            f"upstream {TRANSLATION_KEY} version is "
            f"{selected.get('version')!r}; expected pinned "
            f"{EXPECTED_VERSION!r}"
        )
    return selected


def _sura_rows(payload) -> list[dict]:
    if isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict):
        candidates = [
            payload.get("result"),
            payload.get("translations"),
            payload.get("data"),
        ]
        rows = next(
            (
                item for item in candidates
                if isinstance(item, list)
            ),
            None,
        )
        if rows is None:
            raise CaptureError(
                "sura API returned an unexpected object shape"
            )
    else:
        raise CaptureError(
            "sura API returned an unexpected JSON shape"
        )
    if not all(isinstance(item, dict) for item in rows):
        raise CaptureError(
            "sura API contains a non-object row"
        )
    return rows


def _as_int(value, *, label: str) -> int:
    if isinstance(value, bool):
        raise CaptureError(f"{label} is not an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    raise CaptureError(f"{label} is not an integer")


def validate_sura(
    raw: bytes, surah: int, expected_count: int
) -> None:
    rows = _sura_rows(
        _json(raw, label=f"sura {surah}")
    )
    actual: list[tuple[int, int]] = []
    for index, row in enumerate(rows, start=1):
        row_surah = _as_int(
            row.get("sura"),
            label=f"sura {surah} row {index} sura",
        )
        row_ayah = _as_int(
            row.get("aya"),
            label=f"sura {surah} row {index} aya",
        )
        if row_surah != surah:
            raise CaptureError(
                "sura response mismatch: "
                f"requested {surah}, row {index} "
                f"reports {row_surah}"
            )
        if not isinstance(row.get("translation"), str):
            raise CaptureError(
                f"sura {surah} ayah {row_ayah} "
                "has no string translation"
            )
        actual.append((row_surah, row_ayah))

    expected = [
        (surah, ayah)
        for ayah in range(1, expected_count + 1)
    ]
    if actual != expected:
        raise CaptureError(
            f"sura {surah} coordinate mismatch: expected "
            f"{expected_count} ordered ayahs, found "
            f"{len(actual)}"
        )


def _tar_bytes(
    entries: Iterable[tuple[str, bytes]]
) -> bytes:
    buffer = io.BytesIO()
    with tarfile.open(
        fileobj=buffer,
        mode="w",
        format=tarfile.USTAR_FORMAT,
    ) as archive:
        for name, data in sorted(
            entries, key=lambda item: item[0]
        ):
            info = tarfile.TarInfo(name=name)
            info.size = len(data)
            info.mtime = 0
            info.uid = 0
            info.gid = 0
            info.uname = ""
            info.gname = ""
            info.mode = 0o644
            archive.addfile(info, io.BytesIO(data))
    return buffer.getvalue()


def _record(
    result: FetchResult, stored_as: str
) -> dict:
    return {
        "requested_url": result.requested_url,
        "final_url": result.final_url,
        "status": result.status,
        "content_type": result.content_type,
        "stored_as": stored_as,
        "byte_size": len(result.body),
        "sha256": sha256_bytes(result.body),
    }


def _assert_capture_authorized(repo_root: Path) -> None:
    registry_path = repo_root / REGISTRY_RELATIVE
    try:
        registry = json.loads(
            registry_path.read_text(encoding="utf-8")
        )
    except FileNotFoundError as exc:
        raise CaptureError(
            "QuranEnc capture blocked: missing "
            "source-vault/registry.json"
        ) from exc
    except json.JSONDecodeError as exc:
        raise CaptureError(
            "QuranEnc capture blocked: invalid "
            "source-vault/registry.json"
        ) from exc

    sources = registry.get("sources")
    if not isinstance(sources, list):
        raise CaptureError(
            "QuranEnc capture blocked: registry sources "
            "must be a list"
        )
    matches = [
        source
        for source in sources
        if isinstance(source, dict)
        and source.get("source_id") == SOURCE_ID
    ]
    if len(matches) != 1:
        raise CaptureError(
            "QuranEnc capture blocked: expected exactly "
            f"one registry entry for {SOURCE_ID}"
        )

    source = matches[0]
    if source.get("status") != "awaiting-artifact":
        raise CaptureError(
            "QuranEnc capture blocked: licence review must "
            "promote registry status to 'awaiting-artifact' first"
        )
    if source.get("version") != EXPECTED_VERSION:
        raise CaptureError(
            "QuranEnc capture blocked: registry version does "
            "not match the pinned acquisition version"
        )

    required_permissions = {
        "redistribution_allowed": True,
        "modification_allowed": False,
        "attribution_required": True,
    }
    mismatched = [
        field
        for field, expected in required_permissions.items()
        if source.get(field) is not expected
    ]
    if mismatched:
        raise CaptureError(
            "QuranEnc capture blocked: licence permissions "
            "are not explicitly cleared: "
            + ", ".join(mismatched)
        )

    present_snapshot_fields = [
        field
        for field in PRESERVED_SNAPSHOT_FIELDS
        if source.get(field) not in (None, "")
    ]
    if present_snapshot_fields:
        raise CaptureError(
            "QuranEnc capture blocked: registry already "
            "contains preserved snapshot metadata"
        )


def _canonical_json_bytes(value: object) -> bytes:
    return (
        json.dumps(
            value,
            ensure_ascii=False,
            indent=2,
            sort_keys=True,
        ).encode("utf-8")
        + b"\n"
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
        raise CaptureError(
            "QuranEnc source index HTML could not be parsed"
        ) from exc

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
        raise CaptureError(
            "resource version is not adjacent to its source-index title"
        )
    observed_version = versions[-1]
    if observed_version != EXPECTED_VERSION:
        raise CaptureError(
            "upstream version changed: "
            f"expected {EXPECTED_VERSION}, got {observed_version!r}"
        )
    if RESOURCE_BOOK not in after:
        raise CaptureError(
            "source-index title is not followed by the expected "
            "As-Siraj attribution"
        )

    return {
        "key": TRANSLATION_KEY,
        "language_iso_code": "ar",
        "version": observed_version,
        "title": RESOURCE_TITLE,
        "description": f'From the book "{RESOURCE_BOOK}".',
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


def validate_existing(repo_root: Path) -> dict:
    output = (repo_root.resolve() / VAULT_RELATIVE).resolve()
    if not output.is_dir():
        raise CaptureError(
            f"captured Source Vault directory is missing: {output}"
        )

    provenance_path = output / "provenance.json"
    try:
        provenance_bytes = provenance_path.read_bytes()
        provenance = json.loads(provenance_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError("captured provenance.json is invalid") from exc

    expected = {
        "schema_version": 1,
        "source_id": SOURCE_ID,
        "source_name": SOURCE_NAME,
        "original_url": SOURCE_PAGE_URL,
        "version": EXPECTED_VERSION,
        "licence_id": "quranenc-republication-terms",
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
        key for key, value in expected.items()
        if provenance.get(key) != value
    ]
    if mismatched:
        raise CaptureError(
            "captured provenance metadata mismatch: "
            + ", ".join(mismatched)
        )

    retrieved_at = provenance.get("retrieved_at")
    if not isinstance(retrieved_at, str) or not retrieved_at:
        raise CaptureError("captured provenance retrieved_at is missing")
    try:
        parsed_retrieved_at = datetime.fromisoformat(
            retrieved_at.replace("Z", "+00:00")
        )
    except ValueError as exc:
        raise CaptureError(
            "captured provenance retrieved_at is not ISO-8601"
        ) from exc
    if (
        parsed_retrieved_at.tzinfo is None
        or parsed_retrieved_at.utcoffset() is None
    ):
        raise CaptureError(
            "captured provenance retrieved_at must include a timezone"
        )

    source_index_path = output / "SOURCE_INDEX.html"
    terms_path = output / "LICENSE_SOURCE.html"
    source_page_path = output / "SOURCE_PAGE.html"
    for path in (source_index_path, terms_path, source_page_path):
        if not path.is_file() or path.stat().st_size < 1:
            raise CaptureError(
                f"captured evidence file is missing/empty: {path.name}"
            )

    metadata_record = validate_source_index(
        source_index_path.read_bytes()
    )
    if provenance.get("upstream_metadata") != metadata_record:
        raise CaptureError(
            "source-index metadata does not match provenance"
        )

    records = provenance.get("capture_files")
    if not isinstance(records, list) or len(records) != 117:
        raise CaptureError(
            "provenance capture_files must contain 117 upstream responses"
        )

    static_urls = {
        "SOURCE_INDEX.html": SOURCE_INDEX_URL,
        "LICENSE_SOURCE.html": PRESERVED_TERMS_URL,
        "SOURCE_PAGE.html": SOURCE_PAGE_URL,
    }
    seen: set[str] = set()
    checksum_entries: list[tuple[str, str]] = []
    sura_manifest_records: list[dict] = []
    total_ayahs = 0

    for record in records:
        if not isinstance(record, dict):
            raise CaptureError("capture_files entry is not an object")
        relative = record.get("path")
        if not isinstance(relative, str) or not relative:
            raise CaptureError("capture_files entry has no path")
        if relative in seen:
            raise CaptureError(
                f"duplicate capture file record: {relative!r}"
            )
        seen.add(relative)
        path = _safe_capture_member(output, relative)
        body = path.read_bytes()
        if record.get("byte_size") != len(body):
            raise CaptureError(f"{relative}: byte size mismatch")
        digest = sha256_bytes(body)
        if record.get("sha256") != digest:
            raise CaptureError(f"{relative}: SHA-256 mismatch")
        if record.get("http_status") != 200:
            raise CaptureError(
                f"{relative}: captured HTTP status is not 200"
            )
        _validate_https_quranenc(
            record.get("requested_url", ""),
            label="requested URL",
        )
        _validate_https_quranenc(
            record.get("final_url", ""),
            label="final URL",
        )

        expected_url = static_urls.get(relative)
        if relative.startswith("raw/suras/") and relative.endswith(".json"):
            try:
                sura = int(Path(relative).stem)
            except ValueError as exc:
                raise CaptureError(
                    f"{relative}: invalid Surah filename"
                ) from exc
            if sura not in range(1, 115):
                raise CaptureError(
                    f"{relative}: invalid Surah metadata"
                )
            expected_url = (
                f"{BASE_URL}/api/v1/translation/sura/"
                f"{TRANSLATION_KEY}/{sura}"
            )
            if record.get("sura") != sura:
                raise CaptureError(
                    f"{relative}: Surah metadata mismatch"
                )
            expected_count = EXPECTED_AYAH_COUNTS[sura - 1]
            validate_sura(body, sura, expected_count)
            if record.get("ayah_count") != expected_count:
                raise CaptureError(
                    f"{relative}: ayah count mismatch"
                )
            if (
                record.get("first_ayah") != 1
                or record.get("last_ayah") != expected_count
            ):
                raise CaptureError(
                    f"{relative}: first/last ayah metadata mismatch"
                )
            total_ayahs += expected_count
            sura_manifest_records.append(record)
        elif relative not in static_urls:
            raise CaptureError(
                f"unexpected captured upstream file: {relative}"
            )

        if record.get("requested_url") != expected_url:
            raise CaptureError(
                f"{relative}: requested URL does not match canonical source"
            )
        checksum_entries.append((relative, digest))

    expected_paths = set(static_urls)
    expected_paths.update(
        f"raw/suras/{sura:03d}.json"
        for sura in range(1, 115)
    )
    if seen != expected_paths:
        raise CaptureError(
            "captured file set does not match the canonical 117-file set"
        )
    if len(sura_manifest_records) != 114:
        raise CaptureError(
            "capture does not contain exactly 114 Surah responses"
        )
    if total_ayahs != EXPECTED_AYAH_COUNT:
        raise CaptureError(
            f"captured ayah total mismatch: {total_ayahs}"
        )

    snapshot_path = output / "raw" / "api-snapshot-manifest.json"
    try:
        snapshot_bytes = snapshot_path.read_bytes()
        snapshot = json.loads(snapshot_bytes.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError("API snapshot manifest is invalid") from exc

    expected_snapshot = _build_snapshot_manifest(
        sura_records=sorted(
            sura_manifest_records,
            key=lambda item: item["sura"],
        ),
        metadata_record=metadata_record,
    )
    if snapshot != expected_snapshot:
        raise CaptureError(
            "API snapshot manifest does not match captured responses"
        )
    if snapshot_bytes != _canonical_json_bytes(snapshot):
        raise CaptureError(
            "API snapshot manifest is not canonical project JSON"
        )

    snapshot_hash = sha256_bytes(snapshot_bytes)
    if provenance.get("snapshot_manifest_sha256") != snapshot_hash:
        raise CaptureError(
            "snapshot manifest SHA-256 does not match provenance"
        )
    if (
        provenance.get("snapshot_manifest_byte_size")
        != len(snapshot_bytes)
    ):
        raise CaptureError(
            "snapshot manifest byte size does not match provenance"
        )
    expected_snapshot_rel = (
        VAULT_RELATIVE / "raw" / "api-snapshot-manifest.json"
    ).as_posix()
    if provenance.get("snapshot_manifest") != expected_snapshot_rel:
        raise CaptureError(
            "snapshot manifest path does not match provenance"
        )
    expected_licence_rel = (
        VAULT_RELATIVE / "LICENSE_SOURCE.html"
    ).as_posix()
    if provenance.get("licence_snapshot") != expected_licence_rel:
        raise CaptureError(
            "licence snapshot path does not match provenance"
        )
    checksum_entries.append(
        ("raw/api-snapshot-manifest.json", snapshot_hash)
    )

    if provenance_bytes != _canonical_json_bytes(provenance):
        raise CaptureError(
            "provenance.json is not in canonical project format"
        )
    checksum_entries.append(
        ("provenance.json", sha256_bytes(provenance_bytes))
    )

    expected_checksums = "".join(
        f"{digest}  {relative}\n"
        for relative, digest in sorted(checksum_entries)
    ).encode("utf-8")
    try:
        actual_checksums = (output / "sha256.txt").read_bytes()
    except OSError as exc:
        raise CaptureError("captured sha256.txt is missing") from exc
    if actual_checksums != expected_checksums:
        raise CaptureError(
            "sha256.txt does not match preserved capture bytes"
        )

    return provenance


def capture_snapshot(
    repo_root: Path,
    *,
    fetcher: Fetcher = fetch_https,
    now: datetime | None = None,
) -> Path:
    repo_root = repo_root.resolve()
    destination = repo_root / VAULT_RELATIVE
    if destination.exists():
        raise CaptureError(
            "refusing to overwrite existing snapshot: "
            f"{destination}"
        )

    retrieved_at = now or datetime.now(timezone.utc)
    if (
        retrieved_at.tzinfo is None
        or retrieved_at.utcoffset() is None
    ):
        raise CaptureError(
            "capture timestamp must be timezone-aware"
        )
    retrieved_at = retrieved_at.astimezone(
        timezone.utc
    )
    retrieved_iso = (
        retrieved_at.isoformat()
        .replace("+00:00", "Z")
    )
    _assert_capture_authorized(repo_root)
    destination.parent.mkdir(
        parents=True, exist_ok=True
    )

    with tempfile.TemporaryDirectory(
        prefix="quranenc-capture-",
        dir=destination.parent,
    ) as tmp:
        staging = Path(tmp) / "snapshot"
        staging.mkdir()

        raw_entries: list[
            tuple[str, bytes]
        ] = []
        fetch_records: list[dict] = []

        pre = fetcher(LIST_URL)
        _validate_result(
            pre, label="metadata preflight"
        )
        selected_pre = _selected_translation(
            pre.body
        )
        pre_name = (
            "metadata/"
            "translations-list-ar.pre.json"
        )
        raw_entries.append(
            (pre_name, pre.body)
        )
        fetch_records.append(
            _record(pre, pre_name)
        )

        terms = fetcher(TERMS_URL)
        _validate_result(
            terms, label="terms"
        )
        if not terms.body.strip():
            raise CaptureError(
                "terms snapshot is empty"
            )
        (
            staging / "LICENSE_SOURCE.html"
        ).write_bytes(terms.body)
        fetch_records.append(
            _record(
                terms,
                "LICENSE_SOURCE.html",
            )
        )

        source_page = fetcher(BROWSE_URL)
        _validate_result(
            source_page, label="source page"
        )
        (
            staging / "SOURCE_PAGE.html"
        ).write_bytes(source_page.body)
        fetch_records.append(
            _record(
                source_page,
                "SOURCE_PAGE.html",
            )
        )

        for surah, expected_count in enumerate(
            EXPECTED_AYAH_COUNTS,
            start=1,
        ):
            url = (
                f"{BASE_URL}/api/v1/"
                "translation/sura/"
                f"{TRANSLATION_KEY}/{surah}"
            )
            result = fetcher(url)
            _validate_result(
                result,
                label=f"sura {surah}",
            )
            validate_sura(
                result.body,
                surah,
                expected_count,
            )
            name = (
                f"raw/sura-{surah:03d}.json"
            )
            raw_entries.append(
                (name, result.body)
            )
            fetch_records.append(
                _record(result, name)
            )

        post = fetcher(LIST_URL)
        _validate_result(
            post, label="metadata postflight"
        )
        selected_post = _selected_translation(
            post.body,
            enforce_version=False,
        )
        if selected_post != selected_pre:
            raise CaptureError(
                "translation metadata changed "
                "during capture; discard and retry"
            )
        post_name = (
            "metadata/"
            "translations-list-ar.post.json"
        )
        raw_entries.append(
            (post_name, post.body)
        )
        fetch_records.append(
            _record(post, post_name)
        )

        snapshot = _tar_bytes(raw_entries)
        snapshot_path = (
            staging / "raw-snapshot.tar"
        )
        snapshot_path.write_bytes(snapshot)

        manifest = {
            "schema_version": 1,
            "source_id": SOURCE_ID,
            "translation_key": (
                TRANSLATION_KEY
            ),
            "expected_version": (
                EXPECTED_VERSION
            ),
            "selected_translation_metadata": (
                selected_pre
            ),
            "retrieved_at": retrieved_iso,
            "raw_payload_count": len(
                raw_entries
            ),
            "raw_snapshot": {
                "path": "raw-snapshot.tar",
                "byte_size": len(snapshot),
                "sha256": sha256_bytes(
                    snapshot
                ),
            },
            "licence_snapshot": {
                "path": (
                    "LICENSE_SOURCE.html"
                ),
                "byte_size": len(
                    terms.body
                ),
                "sha256": sha256_bytes(
                    terms.body
                ),
            },
            "source_page_snapshot": {
                "path": "SOURCE_PAGE.html",
                "byte_size": len(
                    source_page.body
                ),
                "sha256": sha256_bytes(
                    source_page.body
                ),
            },
            "requests": fetch_records,
            "promotion_state": (
                "captured-unreviewed"
            ),
            "normal_build_dependency": (
                False
            ),
        }
        manifest_bytes = (
            json.dumps(
                manifest,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        (
            staging / "capture-manifest.json"
        ).write_bytes(manifest_bytes)

        project_artifact = (
            VAULT_RELATIVE
            / "raw-snapshot.tar"
        ).as_posix()
        licence_path = (
            VAULT_RELATIVE
            / "LICENSE_SOURCE.html"
        ).as_posix()
        source_page_path = (
            VAULT_RELATIVE
            / "SOURCE_PAGE.html"
        ).as_posix()
        provenance = {
            "source_id": SOURCE_ID,
            "source_name": SOURCE_NAME,
            "original_url": BROWSE_URL,
            "version": EXPECTED_VERSION,
            "retrieved_at": retrieved_iso,
            "sha256": sha256_bytes(
                snapshot
            ),
            "byte_size": len(snapshot),
            "licence_id": (
                "quranenc-republication-terms"
            ),
            "redistribution_allowed": True,
            "modification_allowed": False,
            "attribution_required": True,
            "licence_snapshot": (
                licence_path
            ),
            "source_page_snapshot": (
                source_page_path
            ),
            "project_mirror": (
                project_artifact
            ),
            "capture_manifest": (
                VAULT_RELATIVE
                / "capture-manifest.json"
            ).as_posix(),
            "review_status": (
                "candidate-unreviewed"
            ),
        }
        provenance_bytes = (
            json.dumps(
                provenance,
                ensure_ascii=False,
                indent=2,
                sort_keys=True,
            )
            + "\n"
        ).encode("utf-8")
        (
            staging
            / "provenance.candidate.json"
        ).write_bytes(
            provenance_bytes
        )

        checksums = {
            "raw-snapshot.tar": (
                sha256_bytes(snapshot)
            ),
            "LICENSE_SOURCE.html": (
                sha256_bytes(terms.body)
            ),
            "SOURCE_PAGE.html": (
                sha256_bytes(
                    source_page.body
                )
            ),
            "capture-manifest.json": (
                sha256_bytes(
                    manifest_bytes
                )
            ),
            (
                "provenance."
                "candidate.json"
            ): sha256_bytes(
                provenance_bytes
            ),
        }
        checksum_text = "".join(
            f"{digest}  {name}\n"
            for name, digest in sorted(
                checksums.items()
            )
        )
        (
            staging / "sha256.txt"
        ).write_text(
            checksum_text,
            encoding="utf-8",
        )

        staging.rename(destination)

    return destination


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Capture the pinned QuranEnc "
            "arabic_seraj v1.0.0 source "
            "into a review-only Source Vault "
            "snapshot. This does not update "
            "source-vault/registry.json."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=(
            Path(__file__)
            .resolve()
            .parents[1]
        ),
        help=(
            "repository root "
            "(defaults to parent of tools/)"
        ),
    )
    parser.add_argument(
        "--validate-existing",
        action="store_true",
        help=(
            "verify the already-preserved review-only snapshot "
            "without network access"
        ),
    )
    args = parser.parse_args()
    try:
        if args.validate_existing:
            provenance = validate_existing(args.repo_root)
            print(
                "QuranEnc preserved snapshot verification OK: "
                f"{provenance['sura_count']} Surahs, "
                f"{provenance['record_count']} ayahs, "
                f"snapshot {provenance['snapshot_manifest_sha256']}"
            )
            return 0
        destination = capture_snapshot(
            args.repo_root
        )
    except (
        OSError,
        CaptureError,
    ) as exc:
        print(
            f"QuranEnc capture FAILED: {exc}"
        )
        return 1
    print(
        "QuranEnc capture complete "
        f"(review required): {destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
