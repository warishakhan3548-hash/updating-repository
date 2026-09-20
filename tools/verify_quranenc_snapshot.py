#!/usr/bin/env python3
"""Offline integrity verifier for the preserved QuranEnc arabic_seraj snapshot.

This tool performs no network access and does not promote the source. It verifies
that the review-only multi-file capture is complete, checksum-bound, structurally
valid, and still contains the expected 114-surah / 6,236-coordinate response set.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
from urllib.parse import urlparse

if __package__:
    from tools.quran_core import EXPECTED_AYAH_COUNTS
    from tools.vault_gate import VaultGateError, validate_checksum_set
else:
    from quran_core import EXPECTED_AYAH_COUNTS
    from vault_gate import VaultGateError, validate_checksum_set


SOURCE_ID = "quran-gloss.quranenc.arabic-seraj.v1.0.0"
EXPECTED_VERSION = "1.0.0"
TRANSLATION_KEY = "arabic_seraj"
SNAPSHOT_RELATIVE = Path(
    "source-vault/quran-gloss/quranenc/arabic-seraj/1.0.0"
)
LEDGER_NAME = "sha256.txt"
MANIFEST_RELATIVE = Path("raw/api-snapshot-manifest.json")
PROVENANCE_NAME = "provenance.json"
EXPECTED_STATIC_MEMBERS = {
    "LICENSE_SOURCE.html",
    "SOURCE_INDEX.html",
    "SOURCE_PAGE.html",
    PROVENANCE_NAME,
    MANIFEST_RELATIVE.as_posix(),
}
ALLOWED_HOSTS = {"quranenc.com", "www.quranenc.com"}


class SnapshotError(RuntimeError):
    pass


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _json_object(path: Path, *, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise SnapshotError(f"{label} is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise SnapshotError(f"{label} must be a JSON object")
    return value


def _ledger_paths(ledger: Path) -> set[str]:
    paths: set[str] = set()
    for line in ledger.read_text(encoding="utf-8").splitlines():
        try:
            _, path = line.split("  ", 1)
        except ValueError as exc:
            raise SnapshotError("checksum ledger has an invalid line") from exc
        paths.add(path)
    return paths


def _expected_members() -> set[str]:
    members = set(EXPECTED_STATIC_MEMBERS)
    members.update(
        f"raw/suras/{surah:03d}.json"
        for surah in range(1, 115)
    )
    return members


def _int(value: object, *, label: str) -> int:
    if isinstance(value, bool):
        raise SnapshotError(f"{label} is not an integer")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and value.isdigit():
        return int(value)
    raise SnapshotError(f"{label} is not an integer")


def _rows(path: Path, *, surah: int) -> list[dict]:
    payload = _json_object(path, label=f"QuranEnc surah {surah}")
    rows = payload.get("result")
    if not isinstance(rows, list) or not all(
        isinstance(item, dict) for item in rows
    ):
        raise SnapshotError(
            f"QuranEnc surah {surah}: result must be a list of objects"
        )
    return rows


def _validate_surah(path: Path, *, surah: int, expected_count: int) -> None:
    rows = _rows(path, surah=surah)
    if len(rows) != expected_count:
        raise SnapshotError(
            f"QuranEnc surah {surah}: expected {expected_count} rows, "
            f"found {len(rows)}"
        )
    for ayah, row in enumerate(rows, start=1):
        row_surah = _int(row.get("sura"), label=f"surah {surah} row sura")
        row_ayah = _int(row.get("aya"), label=f"surah {surah} row aya")
        if (row_surah, row_ayah) != (surah, ayah):
            raise SnapshotError(
                f"QuranEnc coordinate mismatch: expected {surah}:{ayah}, "
                f"found {row_surah}:{row_ayah}"
            )
        if not isinstance(row.get("arabic_text"), str) or not row["arabic_text"]:
            raise SnapshotError(
                f"QuranEnc {surah}:{ayah}: arabic_text missing"
            )
        if not isinstance(row.get("translation"), str):
            raise SnapshotError(
                f"QuranEnc {surah}:{ayah}: translation must be a string"
            )


def _validate_url(url: object, *, expected: str, label: str) -> None:
    if url != expected:
        raise SnapshotError(f"{label}: URL mismatch")
    parsed = urlparse(expected)
    if parsed.scheme != "https" or (parsed.hostname or "").lower() not in ALLOWED_HOSTS:
        raise SnapshotError(f"{label}: URL is outside approved QuranEnc HTTPS hosts")


def verify_snapshot(repo_root: Path) -> dict:
    root = (repo_root.resolve() / SNAPSHOT_RELATIVE)
    if not root.is_dir():
        raise SnapshotError(f"snapshot directory missing: {root}")

    ledger = root / LEDGER_NAME
    if not ledger.is_file():
        raise SnapshotError("QuranEnc checksum ledger is missing")
    try:
        validate_checksum_set(ledger, SOURCE_ID)
    except VaultGateError as exc:
        raise SnapshotError(str(exc)) from exc

    expected_members = _expected_members()
    actual_members = _ledger_paths(ledger)
    if actual_members != expected_members:
        missing = sorted(expected_members - actual_members)
        extra = sorted(actual_members - expected_members)
        raise SnapshotError(
            "QuranEnc checksum member set mismatch; "
            f"missing={missing}, extra={extra}"
        )

    provenance = _json_object(root / PROVENANCE_NAME, label="QuranEnc provenance")
    expected_provenance = {
        "schema_version": 1,
        "source_id": SOURCE_ID,
        "version": EXPECTED_VERSION,
        "translation_key": TRANSLATION_KEY,
        "snapshot_type": "quranenc-sura-api-response-set",
        "promotion_status": "captured-unreviewed",
        "sura_count": 114,
        "record_count": 6236,
        "redistribution_allowed": True,
        "modification_allowed": False,
        "attribution_required": True,
        "licence_id": "quranenc-republication-terms",
        "snapshot_manifest": (
            SNAPSHOT_RELATIVE / MANIFEST_RELATIVE
        ).as_posix(),
    }
    mismatches = [
        key for key, expected in expected_provenance.items()
        if provenance.get(key) != expected
    ]
    if mismatches:
        raise SnapshotError(
            "QuranEnc provenance mismatch: " + ", ".join(mismatches)
        )

    manifest_path = root / MANIFEST_RELATIVE
    if provenance.get("snapshot_manifest_byte_size") != manifest_path.stat().st_size:
        raise SnapshotError("QuranEnc snapshot manifest byte size mismatch")
    if provenance.get("snapshot_manifest_sha256") != _sha256(manifest_path):
        raise SnapshotError("QuranEnc snapshot manifest SHA-256 mismatch")

    manifest = _json_object(manifest_path, label="QuranEnc API snapshot manifest")
    if manifest.get("schema_version") != 1:
        raise SnapshotError("unsupported QuranEnc snapshot manifest schema")
    if manifest.get("source_id") != SOURCE_ID:
        raise SnapshotError("QuranEnc snapshot manifest source_id mismatch")
    if manifest.get("snapshot_type") != "quranenc-sura-api-response-set":
        raise SnapshotError("QuranEnc snapshot manifest type mismatch")
    if manifest.get("sura_count") != 114 or manifest.get("record_count") != 6236:
        raise SnapshotError("QuranEnc snapshot manifest count mismatch")

    entries = manifest.get("suras")
    if not isinstance(entries, list) or len(entries) != 114:
        raise SnapshotError("QuranEnc snapshot manifest must contain 114 surahs")

    total = 0
    for surah, expected_count in enumerate(EXPECTED_AYAH_COUNTS, start=1):
        entry = entries[surah - 1]
        if not isinstance(entry, dict):
            raise SnapshotError(f"QuranEnc manifest surah {surah} is not an object")
        expected_path = f"raw/suras/{surah:03d}.json"
        expected_url = (
            "https://quranenc.com/api/v1/translation/sura/"
            f"{TRANSLATION_KEY}/{surah}"
        )
        expected_entry = {
            "sura": surah,
            "ayah_count": expected_count,
            "first_ayah": 1,
            "last_ayah": expected_count,
            "path": expected_path,
            "http_status": 200,
        }
        bad = [
            key for key, expected in expected_entry.items()
            if entry.get(key) != expected
        ]
        if bad:
            raise SnapshotError(
                f"QuranEnc manifest surah {surah} mismatch: {', '.join(bad)}"
            )
        _validate_url(
            entry.get("requested_url"),
            expected=expected_url,
            label=f"QuranEnc manifest surah {surah} requested_url",
        )
        _validate_url(
            entry.get("final_url"),
            expected=expected_url,
            label=f"QuranEnc manifest surah {surah} final_url",
        )

        source_path = root / expected_path
        if entry.get("byte_size") != source_path.stat().st_size:
            raise SnapshotError(
                f"QuranEnc manifest surah {surah} byte size mismatch"
            )
        if entry.get("sha256") != _sha256(source_path):
            raise SnapshotError(
                f"QuranEnc manifest surah {surah} SHA-256 mismatch"
            )
        _validate_surah(
            source_path,
            surah=surah,
            expected_count=expected_count,
        )
        total += expected_count

    if total != 6236:
        raise SnapshotError(
            f"QuranEnc verified coordinate total is {total}, expected 6236"
        )

    return {
        "source_id": SOURCE_ID,
        "version": EXPECTED_VERSION,
        "promotion_status": provenance["promotion_status"],
        "record_count": total,
        "sura_count": 114,
        "ledger_members": len(actual_members),
        "snapshot_manifest_sha256": _sha256(manifest_path),
    }


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify the preserved QuranEnc arabic_seraj v1.0.0 "
            "review-only snapshot without network access."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    args = parser.parse_args()
    try:
        result = verify_snapshot(args.repo_root)
    except (OSError, ValueError, SnapshotError) as exc:
        print(f"QuranEnc snapshot verification FAILED: {exc}")
        return 1
    print(
        "QuranEnc snapshot verification OK: "
        f"{result['sura_count']} surahs, "
        f"{result['record_count']} coordinates, "
        f"{result['ledger_members']} checksum-bound members"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
