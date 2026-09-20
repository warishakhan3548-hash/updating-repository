#!/usr/bin/env python3
"""Offline verifier for a captured QuranEnc arabic_seraj Source Vault snapshot.

The verifier intentionally performs no network access. It proves that a preserved
review-only snapshot is internally complete, immutable-by-hash, coordinate-complete,
and still bound to the pinned QuranEnc source identity before any later promotion.
"""
from __future__ import annotations

import argparse
import io
import json
from pathlib import Path
import tarfile

if __package__:
    from tools.capture_quranenc_gloss import (
        BASE_URL,
        CaptureError,
        EXPECTED_AYAH_COUNTS,
        EXPECTED_VERSION,
        LIST_URL,
        SOURCE_ID,
        TERMS_URL,
        TRANSLATION_KEY,
        VAULT_RELATIVE,
        _selected_translation,
        _validate_https_quranenc,
        sha256_bytes,
        validate_sura,
    )
else:
    from capture_quranenc_gloss import (
        BASE_URL,
        CaptureError,
        EXPECTED_AYAH_COUNTS,
        EXPECTED_VERSION,
        LIST_URL,
        SOURCE_ID,
        TERMS_URL,
        TRANSLATION_KEY,
        VAULT_RELATIVE,
        _selected_translation,
        _validate_https_quranenc,
        sha256_bytes,
        validate_sura,
    )


def _read_json(path: Path, *, label: str) -> dict:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError) as exc:
        raise CaptureError(f"{label} is not valid UTF-8 JSON") from exc
    if not isinstance(value, dict):
        raise CaptureError(f"{label} must be a JSON object")
    return value


def _require_file(root: Path, relative: str) -> bytes:
    candidate = root / relative
    try:
        candidate.resolve().relative_to(root.resolve())
    except ValueError as exc:
        raise CaptureError(f"snapshot path escaped root: {relative}") from exc
    if not candidate.is_file():
        raise CaptureError(f"snapshot file missing: {relative}")
    return candidate.read_bytes()


def _expected_tar_names() -> list[str]:
    names = ["metadata/translations-list-ar.pre.json"]
    names.extend(
        f"raw/sura-{surah:03d}.json"
        for surah in range(1, 115)
    )
    names.append("metadata/translations-list-ar.post.json")
    return sorted(names)


def _load_tar_files(raw: bytes) -> dict[str, bytes]:
    files: dict[str, bytes] = {}
    try:
        with tarfile.open(fileobj=io.BytesIO(raw), mode="r:") as archive:
            for member in archive.getmembers():
                name = member.name
                path = Path(name)
                if (
                    not member.isfile()
                    or path.is_absolute()
                    or ".." in path.parts
                    or name in files
                ):
                    raise CaptureError(
                        f"unsafe or duplicate raw snapshot member: {name!r}"
                    )
                handle = archive.extractfile(member)
                if handle is None:
                    raise CaptureError(f"cannot read raw snapshot member: {name}")
                files[name] = handle.read()
    except (tarfile.TarError, OSError) as exc:
        raise CaptureError("raw-snapshot.tar is invalid") from exc

    expected = _expected_tar_names()
    if sorted(files) != expected:
        raise CaptureError(
            "raw snapshot member set mismatch: "
            f"expected {len(expected)}, found {len(files)}"
        )
    return files


def _request_expected_url(stored_as: str) -> str:
    if stored_as in {
        "metadata/translations-list-ar.pre.json",
        "metadata/translations-list-ar.post.json",
    }:
        return LIST_URL
    if stored_as == "LICENSE_SOURCE.html":
        return TERMS_URL
    if stored_as.startswith("raw/sura-") and stored_as.endswith(".json"):
        try:
            surah = int(stored_as[len("raw/sura-"):-len(".json")])
        except ValueError as exc:
            raise CaptureError(f"invalid sura member name: {stored_as}") from exc
        if not 1 <= surah <= 114:
            raise CaptureError(f"invalid sura member number: {stored_as}")
        return (
            f"{BASE_URL}/api/v1/translation/sura/"
            f"{TRANSLATION_KEY}/{surah}"
        )
    raise CaptureError(f"unexpected captured request target: {stored_as}")


def _verify_requests(
    manifest: dict,
    tar_files: dict[str, bytes],
    licence_bytes: bytes,
) -> None:
    requests = manifest.get("requests")
    if not isinstance(requests, list):
        raise CaptureError("capture manifest requests must be a list")

    expected_names = set(tar_files) | {"LICENSE_SOURCE.html"}
    if len(requests) != len(expected_names):
        raise CaptureError(
            f"capture request count mismatch: expected {len(expected_names)}, "
            f"found {len(requests)}"
        )

    seen: set[str] = set()
    for record in requests:
        if not isinstance(record, dict):
            raise CaptureError("capture request record must be an object")
        stored_as = record.get("stored_as")
        if not isinstance(stored_as, str) or stored_as in seen:
            raise CaptureError(f"duplicate/invalid stored_as: {stored_as!r}")
        seen.add(stored_as)
        if stored_as not in expected_names:
            raise CaptureError(f"unexpected stored_as: {stored_as}")

        expected_url = _request_expected_url(stored_as)
        if record.get("requested_url") != expected_url:
            raise CaptureError(f"{stored_as}: requested URL mismatch")
        final_url = record.get("final_url")
        if not isinstance(final_url, str):
            raise CaptureError(f"{stored_as}: final URL missing")
        _validate_https_quranenc(final_url, label=f"{stored_as} final URL")
        if record.get("status") != 200:
            raise CaptureError(f"{stored_as}: HTTP status is not 200")

        body = (
            licence_bytes
            if stored_as == "LICENSE_SOURCE.html"
            else tar_files[stored_as]
        )
        if record.get("byte_size") != len(body):
            raise CaptureError(f"{stored_as}: byte size mismatch")
        if record.get("sha256") != sha256_bytes(body):
            raise CaptureError(f"{stored_as}: SHA-256 mismatch")

    if seen != expected_names:
        raise CaptureError("capture request set is incomplete")


def verify_snapshot(repo_root: Path) -> dict:
    repo_root = repo_root.resolve()
    root = repo_root / VAULT_RELATIVE
    if not root.is_dir():
        raise CaptureError(f"captured snapshot directory missing: {root}")

    raw_snapshot = _require_file(root, "raw-snapshot.tar")
    licence_bytes = _require_file(root, "LICENSE_SOURCE.html")
    manifest_bytes = _require_file(root, "capture-manifest.json")
    provenance_bytes = _require_file(root, "provenance.candidate.json")
    checksums_bytes = _require_file(root, "sha256.txt")

    manifest = _read_json(root / "capture-manifest.json", label="capture manifest")
    provenance = _read_json(
        root / "provenance.candidate.json",
        label="candidate provenance",
    )

    if manifest.get("schema_version") != 1:
        raise CaptureError("unsupported QuranEnc capture manifest schema")
    if manifest.get("source_id") != SOURCE_ID:
        raise CaptureError("capture source_id mismatch")
    if manifest.get("translation_key") != TRANSLATION_KEY:
        raise CaptureError("capture translation key mismatch")
    if manifest.get("expected_version") != EXPECTED_VERSION:
        raise CaptureError("capture expected version mismatch")
    if manifest.get("promotion_state") != "captured-unreviewed":
        raise CaptureError("capture promotion_state must remain review-only")
    if manifest.get("normal_build_dependency") is not False:
        raise CaptureError("captured source must not be a normal-build dependency")

    raw_meta = manifest.get("raw_snapshot")
    licence_meta = manifest.get("licence_snapshot")
    if not isinstance(raw_meta, dict) or not isinstance(licence_meta, dict):
        raise CaptureError("capture artifact metadata is incomplete")
    if raw_meta.get("path") != "raw-snapshot.tar":
        raise CaptureError("raw snapshot path mismatch")
    if raw_meta.get("byte_size") != len(raw_snapshot):
        raise CaptureError("raw snapshot byte size mismatch")
    if raw_meta.get("sha256") != sha256_bytes(raw_snapshot):
        raise CaptureError("raw snapshot SHA-256 mismatch")
    if licence_meta.get("path") != "LICENSE_SOURCE.html":
        raise CaptureError("licence snapshot path mismatch")
    if licence_meta.get("byte_size") != len(licence_bytes):
        raise CaptureError("licence snapshot byte size mismatch")
    if licence_meta.get("sha256") != sha256_bytes(licence_bytes):
        raise CaptureError("licence snapshot SHA-256 mismatch")

    tar_files = _load_tar_files(raw_snapshot)
    if manifest.get("raw_payload_count") != len(tar_files):
        raise CaptureError("raw payload count mismatch")

    pre = tar_files["metadata/translations-list-ar.pre.json"]
    post = tar_files["metadata/translations-list-ar.post.json"]
    selected_pre = _selected_translation(pre)
    selected_post = _selected_translation(post)
    if selected_pre != selected_post:
        raise CaptureError("pre/post translation metadata mismatch")
    if manifest.get("selected_translation_metadata") != selected_pre:
        raise CaptureError("selected translation metadata mismatch")

    for surah, expected_count in enumerate(EXPECTED_AYAH_COUNTS, start=1):
        validate_sura(
            tar_files[f"raw/sura-{surah:03d}.json"],
            surah,
            expected_count,
        )

    _verify_requests(manifest, tar_files, licence_bytes)

    expected_project_artifact = (
        VAULT_RELATIVE / "raw-snapshot.tar"
    ).as_posix()
    expected_licence = (
        VAULT_RELATIVE / "LICENSE_SOURCE.html"
    ).as_posix()
    expected_manifest = (
        VAULT_RELATIVE / "capture-manifest.json"
    ).as_posix()

    fixed_provenance = {
        "source_id": SOURCE_ID,
        "version": EXPECTED_VERSION,
        "sha256": sha256_bytes(raw_snapshot),
        "byte_size": len(raw_snapshot),
        "licence_id": "quranenc-republication-terms",
        "redistribution_allowed": True,
        "modification_allowed": False,
        "attribution_required": True,
        "licence_snapshot": expected_licence,
        "project_mirror": expected_project_artifact,
        "capture_manifest": expected_manifest,
        "review_status": "candidate-unreviewed",
    }
    mismatches = [
        key
        for key, expected in fixed_provenance.items()
        if provenance.get(key) != expected
    ]
    if mismatches:
        raise CaptureError(
            "candidate provenance mismatch: " + ", ".join(mismatches)
        )

    expected_checksums = {
        "raw-snapshot.tar": sha256_bytes(raw_snapshot),
        "LICENSE_SOURCE.html": sha256_bytes(licence_bytes),
        "capture-manifest.json": sha256_bytes(manifest_bytes),
        "provenance.candidate.json": sha256_bytes(provenance_bytes),
    }
    expected_text = "".join(
        f"{digest}  {name}\n"
        for name, digest in sorted(expected_checksums.items())
    ).encode("utf-8")
    if checksums_bytes != expected_text:
        raise CaptureError("sha256.txt does not match captured snapshot files")

    return provenance


def main() -> int:
    parser = argparse.ArgumentParser(
        description=(
            "Verify an existing QuranEnc arabic_seraj v1.0.0 "
            "review-only Source Vault snapshot without network access."
        )
    )
    parser.add_argument(
        "--repo-root",
        type=Path,
        default=Path(__file__).resolve().parents[1],
    )
    args = parser.parse_args()
    try:
        provenance = verify_snapshot(args.repo_root)
    except (CaptureError, OSError, ValueError) as exc:
        print(f"QuranEnc snapshot verification FAILED: {exc}")
        return 1
    print(
        "QuranEnc snapshot verification OK: "
        f"{provenance['byte_size']} bytes, {provenance['sha256']}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
