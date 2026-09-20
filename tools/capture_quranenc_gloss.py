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
BASE_URL = "https://quranenc.com"
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
CAPTURE_SOURCE_INDEX_URL = f"{BASE_URL}/en/home"
CAPTURE_TERMS_URL = f"{BASE_URL}/en/home/about/terms-and-conditions"
PRESERVED_MANIFEST_SHA256 = (
    "8cbc4f5f41298e438f7862fff1eba309"
    "ffdab254ca240257bd5b652631f2396c"
)
PRESERVED_PROVENANCE_SHA256 = (
    "a34107eb5edc90122bbdfcb5906639e6"
    "9d19f5cf3a038e08e66709c510132b82"
)
PRESERVED_FIXED_HASHES = {
    "SOURCE_INDEX.html": (
        "fe260d3728b6e0dd544c29695f96ac3"
        "fa0deda500dd28d9d704bfa47c1606322"
    ),
    "LICENSE_SOURCE.html": (
        "24dd28bc25f21e59a2ec87137faeb0d9"
        "691401232d99d2177cabf887c48341c"
    ),
    "SOURCE_PAGE.html": (
        "64284343dbff99dc3bfd2f343a156d2b"
        "6745b7bd99b7f0d5677ba168c4762299"
    ),
}


class CaptureError(RuntimeError):
    pass


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



def _safe_existing_member(root: Path, relative: str) -> Path:
    rel = Path(relative)
    if rel.is_absolute() or ".." in rel.parts:
        raise CaptureError(
            f"unsafe preserved snapshot path: {relative!r}"
        )
    path = root / rel
    if not path.is_file():
        raise CaptureError(
            f"missing preserved snapshot file: {relative}"
        )
    try:
        path.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise CaptureError(
            f"preserved snapshot path escaped root: {relative!r}"
        ) from exc
    return path


def _load_json_file(path: Path, *, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (
        OSError,
        UnicodeDecodeError,
        json.JSONDecodeError,
    ) as exc:
        raise CaptureError(
            f"{label} is not valid UTF-8 JSON"
        ) from exc
    if not isinstance(value, dict):
        raise CaptureError(
            f"{label} must be a JSON object"
        )
    return value


def _validate_quarantine_registry(repo_root: Path) -> None:
    registry = _load_json_file(
        repo_root / REGISTRY_RELATIVE,
        label="Source Vault registry",
    )
    sources = registry.get("sources")
    if not isinstance(sources, list):
        raise CaptureError(
            "Source Vault registry sources must be a list"
        )
    matches = [
        source
        for source in sources
        if isinstance(source, dict)
        and source.get("source_id") == SOURCE_ID
    ]
    if len(matches) != 1:
        raise CaptureError(
            "preserved QuranEnc snapshot quarantine requires "
            "exactly one registry entry"
        )
    source = matches[0]
    if source.get("status") != "awaiting-licence":
        raise CaptureError(
            "preserved QuranEnc snapshot is not quarantined: "
            "registry status must remain 'awaiting-licence'"
        )
    if source.get("redistribution_allowed") is not None:
        raise CaptureError(
            "preserved QuranEnc snapshot quarantine requires "
            "redistribution_allowed=null"
        )
    populated = [
        field
        for field in PRESERVED_SNAPSHOT_FIELDS
        if source.get(field) not in (None, "")
    ]
    if populated:
        raise CaptureError(
            "quarantined QuranEnc bytes must not be registered "
            "as an approved/preserved production artifact: "
            + ", ".join(populated)
        )
    requirements = source.get("release_requirements")
    if (
        not isinstance(requirements, dict)
        or requirements.get(
            "historical_snapshot_retention_status"
        ) != "unresolved"
    ):
        raise CaptureError(
            "QuranEnc quarantine requires unresolved historical "
            "snapshot retention status"
        )


def _expected_preserved_paths() -> set[str]:
    paths = set(PRESERVED_FIXED_HASHES)
    paths.update(
        f"raw/suras/{surah:03d}.json"
        for surah in range(1, 115)
    )
    return paths


def _expected_capture_url(relative: str) -> str:
    if relative == "SOURCE_INDEX.html":
        return CAPTURE_SOURCE_INDEX_URL
    if relative == "LICENSE_SOURCE.html":
        return CAPTURE_TERMS_URL
    if relative == "SOURCE_PAGE.html":
        return BROWSE_URL
    if (
        relative.startswith("raw/suras/")
        and relative.endswith(".json")
    ):
        stem = relative[len("raw/suras/"):-5]
        if len(stem) == 3 and stem.isdigit():
            surah = int(stem)
            if 1 <= surah <= 114:
                return (
                    f"{BASE_URL}/api/v1/translation/sura/"
                    f"{TRANSLATION_KEY}/{surah}"
                )
    raise CaptureError(
        f"unexpected preserved capture path: {relative!r}"
    )


def validate_preserved_snapshot(repo_root: Path) -> dict:
    """Offline-verify the already preserved, legally quarantined snapshot."""
    repo_root = repo_root.resolve()
    _validate_quarantine_registry(repo_root)

    root = repo_root / VAULT_RELATIVE
    if not root.is_dir():
        raise CaptureError(
            f"preserved QuranEnc snapshot is missing: {root}"
        )

    provenance_path = root / "provenance.json"
    manifest_path = root / "raw" / "api-snapshot-manifest.json"
    checksums_path = root / "sha256.txt"

    provenance_bytes = provenance_path.read_bytes()
    manifest_bytes = manifest_path.read_bytes()
    if sha256_bytes(provenance_bytes) != PRESERVED_PROVENANCE_SHA256:
        raise CaptureError(
            "preserved QuranEnc provenance SHA-256 mismatch"
        )
    if sha256_bytes(manifest_bytes) != PRESERVED_MANIFEST_SHA256:
        raise CaptureError(
            "preserved QuranEnc aggregate manifest SHA-256 mismatch"
        )

    provenance = _load_json_file(
        provenance_path,
        label="preserved QuranEnc provenance",
    )
    manifest = _load_json_file(
        manifest_path,
        label="preserved QuranEnc aggregate manifest",
    )

    expected_provenance = {
        "schema_version": 1,
        "source_id": SOURCE_ID,
        "source_name": SOURCE_NAME,
        "original_url": BROWSE_URL,
        "version": EXPECTED_VERSION,
        "licence_id": "quranenc-republication-terms",
        "translation_key": TRANSLATION_KEY,
        "snapshot_type": "quranenc-sura-api-response-set",
        "snapshot_manifest": (
            VAULT_RELATIVE
            / "raw"
            / "api-snapshot-manifest.json"
        ).as_posix(),
        "snapshot_manifest_sha256": PRESERVED_MANIFEST_SHA256,
        "snapshot_manifest_byte_size": len(manifest_bytes),
        "record_count": sum(EXPECTED_AYAH_COUNTS),
        "sura_count": 114,
        "promotion_status": "captured-unreviewed",
    }
    mismatched = [
        key
        for key, expected in expected_provenance.items()
        if provenance.get(key) != expected
    ]
    if mismatched:
        raise CaptureError(
            "preserved QuranEnc provenance metadata mismatch: "
            + ", ".join(mismatched)
        )

    retrieved_at = provenance.get("retrieved_at")
    if not isinstance(retrieved_at, str) or not retrieved_at.endswith("Z"):
        raise CaptureError(
            "preserved QuranEnc retrieved_at must be UTC"
        )
    try:
        datetime.fromisoformat(
            retrieved_at[:-1] + "+00:00"
        )
    except ValueError as exc:
        raise CaptureError(
            "preserved QuranEnc retrieved_at is invalid"
        ) from exc

    expected_manifest = {
        "schema_version": 1,
        "snapshot_type": "quranenc-sura-api-response-set",
        "source_id": SOURCE_ID,
        "translation_key": TRANSLATION_KEY,
        "version": EXPECTED_VERSION,
        "record_count": sum(EXPECTED_AYAH_COUNTS),
        "sura_count": 114,
    }
    manifest_mismatched = [
        key
        for key, expected in expected_manifest.items()
        if manifest.get(key) != expected
    ]
    if manifest_mismatched:
        raise CaptureError(
            "preserved QuranEnc aggregate manifest metadata mismatch: "
            + ", ".join(manifest_mismatched)
        )
    if provenance.get("upstream_metadata") != manifest.get(
        "upstream_metadata"
    ):
        raise CaptureError(
            "preserved QuranEnc upstream metadata disagrees "
            "between provenance and manifest"
        )
    upstream = manifest.get("upstream_metadata")
    expected_upstream = {
        "key": TRANSLATION_KEY,
        "language_iso_code": "ar",
        "version": EXPECTED_VERSION,
        "title": "Arabic Language - Meanings of Words",
        "description": (
            'From the book "As-Siraj fi Bayan Gharib Al-Quran".'
        ),
    }
    if upstream != expected_upstream:
        raise CaptureError(
            "preserved QuranEnc upstream source identity mismatch"
        )

    capture_files = provenance.get("capture_files")
    if not isinstance(capture_files, list) or len(capture_files) != 117:
        raise CaptureError(
            "preserved QuranEnc provenance must bind 117 upstream responses"
        )
    by_path: dict[str, dict] = {}
    checksum_entries: list[tuple[str, str]] = []
    expected_paths = _expected_preserved_paths()
    for record in capture_files:
        if not isinstance(record, dict):
            raise CaptureError(
                "preserved QuranEnc capture record is not an object"
            )
        relative = record.get("path")
        if not isinstance(relative, str) or relative in by_path:
            raise CaptureError(
                f"invalid/duplicate preserved capture path: {relative!r}"
            )
        if relative not in expected_paths:
            raise CaptureError(
                f"unexpected preserved capture path: {relative!r}"
            )
        expected_url = _expected_capture_url(relative)
        if record.get("requested_url") != expected_url:
            raise CaptureError(
                f"{relative}: preserved requested URL mismatch"
            )
        final_url = record.get("final_url")
        if not isinstance(final_url, str):
            raise CaptureError(
                f"{relative}: preserved final URL missing"
            )
        _validate_https_quranenc(
            final_url,
            label=f"{relative} preserved final URL",
        )
        if record.get("http_status") != 200:
            raise CaptureError(
                f"{relative}: preserved HTTP status is not 200"
            )
        path = _safe_existing_member(root, relative)
        body = path.read_bytes()
        digest = sha256_bytes(body)
        if record.get("byte_size") != len(body):
            raise CaptureError(
                f"{relative}: preserved byte size mismatch"
            )
        if record.get("sha256") != digest:
            raise CaptureError(
                f"{relative}: preserved SHA-256 mismatch"
            )
        fixed = PRESERVED_FIXED_HASHES.get(relative)
        if fixed is not None and digest != fixed:
            raise CaptureError(
                f"{relative}: fixed review hash mismatch"
            )
        by_path[relative] = record
        checksum_entries.append((relative, digest))

    if set(by_path) != expected_paths:
        raise CaptureError(
            "preserved QuranEnc capture file set is incomplete"
        )

    suras = manifest.get("suras")
    if not isinstance(suras, list) or len(suras) != 114:
        raise CaptureError(
            "preserved QuranEnc manifest must contain 114 Surahs"
        )
    total = 0
    for expected_surah, record in enumerate(suras, start=1):
        if not isinstance(record, dict):
            raise CaptureError(
                f"Surah {expected_surah}: manifest record is invalid"
            )
        relative = f"raw/suras/{expected_surah:03d}.json"
        if record != by_path.get(relative):
            raise CaptureError(
                f"Surah {expected_surah}: manifest/provenance record mismatch"
            )
        expected_count = EXPECTED_AYAH_COUNTS[expected_surah - 1]
        if (
            record.get("sura") != expected_surah
            or record.get("ayah_count") != expected_count
            or record.get("first_ayah") != 1
            or record.get("last_ayah") != expected_count
        ):
            raise CaptureError(
                f"Surah {expected_surah}: preserved coordinate metadata mismatch"
            )
        validate_sura(
            _safe_existing_member(root, relative).read_bytes(),
            expected_surah,
            expected_count,
        )
        total += expected_count
    if total != sum(EXPECTED_AYAH_COUNTS):
        raise CaptureError(
            "preserved QuranEnc total ayah count mismatch"
        )

    checksum_entries.extend(
        [
            (
                "raw/api-snapshot-manifest.json",
                PRESERVED_MANIFEST_SHA256,
            ),
            (
                "provenance.json",
                PRESERVED_PROVENANCE_SHA256,
            ),
        ]
    )
    expected_checksums = "".join(
        f"{digest}  {relative}\n"
        for relative, digest in sorted(checksum_entries)
    ).encode("utf-8")
    if checksums_path.read_bytes() != expected_checksums:
        raise CaptureError(
            "preserved QuranEnc sha256.txt does not match "
            "the quarantined snapshot"
        )

    return provenance

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
        "--validate-existing",
        action="store_true",
        help=(
            "offline-verify the already preserved quarantined snapshot; "
            "never contacts upstream"
        ),
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
    args = parser.parse_args()
    try:
        if args.validate_existing:
            provenance = validate_preserved_snapshot(
                args.repo_root
            )
            print(
                "QuranEnc quarantined snapshot verification OK: "
                f"{provenance['sura_count']} Surahs, "
                f"{provenance['record_count']} ayahs, "
                f"manifest {provenance['snapshot_manifest_sha256']}"
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
            f"QuranEnc Source Vault operation FAILED: {exc}"
        )
        return 1
    print(
        "QuranEnc capture complete "
        f"(review required): {destination}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
