from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import tempfile
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Callable

from tools.quran_core import EXPECTED_AYAH_COUNTS


LIST_URL = "https://quranenc.com/api/v1/translations/list/ar?localization=en"
SURA_URL_TEMPLATE = "https://quranenc.com/api/v1/translation/sura/{translation_key}/{sura}"
TERMS_URL = "https://quranenc.com/en/home/api"
DEFAULT_TRANSLATION_KEY = "arabic_seraj"
DEFAULT_SOURCE_ID = "quran-gloss.quranenc.arabic-seraj"

# Coordinate completeness is checked against the existing Quran core invariant.
# No Quran text is sourced from QuranEnc or reconstructed here.


class SnapshotError(RuntimeError):
    pass


@dataclass(frozen=True)
class FetchResult:
    requested_url: str
    final_url: str
    body: bytes
    content_type: str | None = None


Fetcher = Callable[[str], FetchResult]


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _strict_json(data: bytes, label: str) -> object:
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise SnapshotError(f"{label} is not UTF-8") from exc
    try:
        return json.loads(text)
    except json.JSONDecodeError as exc:
        raise SnapshotError(f"{label} is not valid JSON") from exc


def _result_rows(payload: object, label: str) -> list[dict]:
    if isinstance(payload, list):
        rows = payload
    elif isinstance(payload, dict) and isinstance(payload.get("result"), list):
        rows = payload["result"]
    else:
        raise SnapshotError(f"{label} does not contain a result array")
    if any(not isinstance(row, dict) for row in rows):
        raise SnapshotError(f"{label} contains a non-object row")
    return rows


def translation_metadata(data: bytes, translation_key: str) -> dict[str, str]:
    rows = _result_rows(_strict_json(data, "translation list"), "translation list")
    matches = [row for row in rows if row.get("key") == translation_key]
    if len(matches) != 1:
        raise SnapshotError(
            f"translation list must contain exactly one {translation_key!r} entry"
        )
    row = matches[0]
    version = row.get("version")
    last_update = row.get("last_update")
    if not isinstance(version, str) or not version:
        raise SnapshotError("translation metadata lacks a version")
    if not isinstance(last_update, (str, int, float)) or str(last_update) == "":
        raise SnapshotError("translation metadata lacks last_update")
    return {
        "key": translation_key,
        "version": version,
        "last_update": str(last_update),
    }


def validate_sura_response(data: bytes, sura: int) -> int:
    if not 1 <= sura <= 114:
        raise SnapshotError(f"invalid sura number {sura}")
    rows = _result_rows(_strict_json(data, f"sura {sura}"), f"sura {sura}")
    expected_count = EXPECTED_AYAH_COUNTS[sura - 1]
    if len(rows) != expected_count:
        raise SnapshotError(
            f"sura {sura} row count mismatch: expected {expected_count}, got {len(rows)}"
        )
    seen: list[int] = []
    for row in rows:
        try:
            row_sura = int(row.get("sura"))
            aya = int(row.get("aya"))
        except (TypeError, ValueError) as exc:
            raise SnapshotError(f"sura {sura} has invalid coordinates") from exc
        if row_sura != sura:
            raise SnapshotError(
                f"sura {sura} response contains row from sura {row_sura}"
            )
        seen.append(aya)
        if "translation" not in row or "footnotes" not in row:
            raise SnapshotError(
                f"sura {sura} aya {aya} lacks translation/footnotes fields"
            )
    expected = list(range(1, expected_count + 1))
    if seen != expected:
        raise SnapshotError(f"sura {sura} aya coordinates are not exactly 1..{expected_count}")
    return expected_count


def _allowed_quranenc_url(url: str) -> None:
    parsed = urllib.parse.urlparse(url)
    if parsed.scheme != "https" or parsed.hostname not in {"quranenc.com", "www.quranenc.com"}:
        raise SnapshotError(f"refusing non-QuranEnc URL: {url}")


def default_fetch(url: str) -> FetchResult:
    _allowed_quranenc_url(url)
    request = urllib.request.Request(
        url,
        headers={
            "User-Agent": "Aaris-Quran-SourceVault-Acquisition/1.0",
            "Accept": "application/json,text/html;q=0.9,*/*;q=0.1",
        },
        method="GET",
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        final_url = response.geturl()
        _allowed_quranenc_url(final_url)
        body = response.read()
        if not body:
            raise SnapshotError(f"empty response from {url}")
        return FetchResult(
            requested_url=url,
            final_url=final_url,
            body=body,
            content_type=response.headers.get_content_type(),
        )


def _write_raw(path: Path, result: FetchResult) -> dict[str, object]:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(result.body)
    return {
        "requested_url": result.requested_url,
        "final_url": result.final_url,
        "byte_size": len(result.body),
        "sha256": sha256_bytes(result.body),
        "content_type": result.content_type,
    }


def acquire_snapshot(
    output_dir: Path,
    *,
    expected_version: str,
    translation_key: str = DEFAULT_TRANSLATION_KEY,
    source_id: str = DEFAULT_SOURCE_ID,
    list_url: str = LIST_URL,
    terms_url: str = TERMS_URL,
    sura_url_template: str = SURA_URL_TEMPLATE,
    fetch: Fetcher = default_fetch,
    retrieved_at: datetime | None = None,
) -> Path:
    if not expected_version or expected_version.strip() != expected_version:
        raise SnapshotError("expected_version must be an explicit non-empty version")
    if output_dir.exists():
        raise SnapshotError(f"output path already exists: {output_dir}")
    if len(EXPECTED_AYAH_COUNTS) != 114 or sum(EXPECTED_AYAH_COUNTS) != 6236:
        raise SnapshotError("internal Quran coordinate invariant is invalid")

    stamp = retrieved_at or datetime.now(timezone.utc)
    if stamp.tzinfo is None or stamp.utcoffset() is None:
        raise SnapshotError("retrieved_at must be timezone-aware")
    retrieved_iso = stamp.astimezone(timezone.utc).isoformat().replace("+00:00", "Z")

    parent = output_dir.parent
    parent.mkdir(parents=True, exist_ok=True)
    staging = Path(tempfile.mkdtemp(prefix=f".{output_dir.name}.partial-", dir=parent))
    raw = staging / "raw"
    files: list[dict[str, object]] = []

    try:
        before = fetch(list_url)
        meta_before = translation_metadata(before.body, translation_key)
        if meta_before["version"] != expected_version:
            raise SnapshotError(
                f"upstream version is {meta_before['version']!r}, expected {expected_version!r}"
            )
        item = _write_raw(raw / "translations-list-before.json", before)
        item["path"] = "raw/translations-list-before.json"
        files.append(item)

        # Preserve the exact current terms page bytes; legal interpretation and
        # promotion remain a separate human-reviewed Source Vault gate.
        terms = fetch(terms_url)
        item = _write_raw(raw / "TERMS_SOURCE.html", terms)
        item["path"] = "raw/TERMS_SOURCE.html"
        files.append(item)

        total_rows = 0
        for sura in range(1, 115):
            url = sura_url_template.format(
                translation_key=urllib.parse.quote(translation_key, safe=""),
                sura=sura,
            )
            result = fetch(url)
            total_rows += validate_sura_response(result.body, sura)
            name = f"sura-{sura:03d}.json"
            item = _write_raw(raw / name, result)
            item["path"] = f"raw/{name}"
            item["sura"] = sura
            files.append(item)

        if total_rows != 6236:
            raise SnapshotError(f"snapshot coordinate count mismatch: {total_rows}")

        after = fetch(list_url)
        meta_after = translation_metadata(after.body, translation_key)
        item = _write_raw(raw / "translations-list-after.json", after)
        item["path"] = "raw/translations-list-after.json"
        files.append(item)

        if meta_after != meta_before:
            raise SnapshotError(
                "translation metadata changed during acquisition; discard snapshot and retry"
            )
        if meta_after["version"] != expected_version:
            raise SnapshotError("upstream version changed during acquisition")

        manifest = {
            "schema_version": 1,
            "source_id": source_id,
            "source_name": "QuranEnc Arabic Language - Meanings of Words (As-Siraj fi Bayan Gharib Al-Quran)",
            "translation_key": translation_key,
            "version": expected_version,
            "retrieved_at": retrieved_iso,
            "upstream_metadata": meta_before,
            "coordinate_system": "surah:ayah",
            "coordinate_count": total_rows,
            "surah_count": 114,
            "licence_review_state": "requires-human-review-before-vault-promotion",
            "immutability_note": "Files under raw/ are exact downloaded response bytes and must not be edited.",
            "files": files,
        }
        manifest_bytes = (
            json.dumps(manifest, ensure_ascii=False, sort_keys=True, indent=2) + "\n"
        ).encode("utf-8")
        (staging / "snapshot_manifest.json").write_bytes(manifest_bytes)

        checksum_lines = [
            f"{sha256_bytes((staging / entry['path']).read_bytes())}  {entry['path']}"
            for entry in files
        ]
        checksum_lines.append(
            f"{sha256_bytes(manifest_bytes)}  snapshot_manifest.json"
        )
        (staging / "sha256.txt").write_text(
            "\n".join(checksum_lines) + "\n", encoding="utf-8"
        )

        os.replace(staging, output_dir)
        return output_dir
    except Exception:
        shutil.rmtree(staging, ignore_errors=True)
        raise


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description=(
            "Acquire an exact QuranEnc Arabic-Seraj API snapshot into a staging "
            "directory. This never updates the Source Vault registry or promotes data."
        )
    )
    parser.add_argument("output_dir", type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--translation-key", default=DEFAULT_TRANSLATION_KEY)
    parser.add_argument("--source-id", default=DEFAULT_SOURCE_ID)
    parser.add_argument("--list-url", default=LIST_URL)
    parser.add_argument("--terms-url", default=TERMS_URL)
    parser.add_argument("--sura-url-template", default=SURA_URL_TEMPLATE)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        path = acquire_snapshot(
            args.output_dir,
            expected_version=args.expected_version,
            translation_key=args.translation_key,
            source_id=args.source_id,
            list_url=args.list_url,
            terms_url=args.terms_url,
            sura_url_template=args.sura_url_template,
        )
    except (OSError, ValueError, SnapshotError) as exc:
        print(f"QuranEnc snapshot FAILED: {exc}")
        return 1
    print(f"QuranEnc snapshot staged at {path}")
    print("Review licence/provenance and exact bytes before Source Vault promotion.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
