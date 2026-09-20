from __future__ import annotations

from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

from tools.capture_quranenc_gloss import (
    BASE_URL,
    BROWSE_URL,
    CaptureError,
    EXPECTED_AYAH_COUNTS,
    FetchResult,
    LIST_URL,
    SOURCE_ID,
    TERMS_URL,
    VAULT_RELATIVE,
    capture_snapshot,
    validate_preserved_snapshot,
)


def enc(obj):
    return json.dumps(
        obj,
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode()


def meta(
    version="1.0.0",
    last_update="2025-12-17",
):
    return enc(
        [
            {
                "key": "arabic_seraj",
                "language_iso_code": "ar",
                "version": version,
                "last_update": last_update,
                "title": (
                    "Arabic Language - "
                    "Meanings of Words"
                ),
                "description": "As-Siraj",
            },
            {
                "key": "other",
                "language_iso_code": "ar",
                "version": "9.9.9",
                "last_update": "x",
                "title": "x",
                "description": "x",
            },
        ]
    )


def authorize_capture(
    root,
    *,
    status="awaiting-artifact",
    redistribution_allowed=True,
):
    vault = root / "source-vault"
    vault.mkdir(parents=True, exist_ok=True)
    (vault / "registry.json").write_text(
        json.dumps(
            {
                "schema_version": 1,
                "sources": [
                    {
                        "source_id": SOURCE_ID,
                        "version": "1.0.0",
                        "status": status,
                        "redistribution_allowed": (
                            redistribution_allowed
                        ),
                        "modification_allowed": False,
                        "attribution_required": True,
                        "vault_artifact": None,
                        "licence_snapshot": None,
                        "provenance": None,
                        "sha256": None,
                        "licence_sha256": None,
                        "provenance_sha256": None,
                        "byte_size": None,
                    }
                ],
            }
        ),
        encoding="utf-8",
    )


def sura_payload(surah, count):
    return enc(
        [
            {
                "sura": str(surah),
                "aya": str(ayah),
                "translation": (
                    f"gloss {surah}:{ayah}"
                ),
                "footnotes": "",
            }
            for ayah in range(
                1, count + 1
            )
        ]
    )


class FakeFetcher:
    def __init__(
        self,
        *,
        version="1.0.0",
        post_version=None,
        bad_sura=None,
        final_host="quranenc.com",
        status=200,
    ):
        self.version = version
        self.post_version = (
            post_version
            if post_version is not None
            else version
        )
        self.bad_sura = bad_sura
        self.final_host = final_host
        self.status = status
        self.list_calls = 0

    def __call__(self, url):
        final = url.replace(
            "quranenc.com",
            self.final_host,
        )
        if url == LIST_URL:
            self.list_calls += 1
            version = (
                self.version
                if self.list_calls == 1
                else self.post_version
            )
            return FetchResult(
                url,
                final,
                self.status,
                "application/json",
                meta(version),
            )
        if url == TERMS_URL:
            return FetchResult(
                url,
                final,
                self.status,
                "text/html",
                b"<html>QuranEnc terms</html>",
            )
        if url == BROWSE_URL:
            return FetchResult(
                url,
                final,
                self.status,
                "text/html",
                (
                    b"<html>Arabic Language - "
                    b"Meanings of Words</html>"
                ),
            )
        prefix = (
            f"{BASE_URL}/api/v1/"
            "translation/sura/"
            "arabic_seraj/"
        )
        if url.startswith(prefix):
            surah = int(
                url[len(prefix):]
            )
            count = (
                EXPECTED_AYAH_COUNTS[
                    surah - 1
                ]
            )
            if self.bad_sura == surah:
                count -= 1
            return FetchResult(
                url,
                final,
                self.status,
                "application/json",
                sura_payload(
                    surah, count
                ),
            )
        raise AssertionError(url)


class CaptureTests(unittest.TestCase):
    def test_preserved_repository_snapshot_revalidates_offline(self):
        root = Path(__file__).resolve().parents[1]
        provenance = validate_preserved_snapshot(root)
        self.assertEqual(6236, provenance["record_count"])
        self.assertEqual(114, provenance["sura_count"])
        self.assertEqual(
            "8cbc4f5f41298e438f7862fff1eba309ffdab254ca240257bd5b652631f2396c",
            provenance["snapshot_manifest_sha256"],
        )
        self.assertEqual(
            "captured-unreviewed",
            provenance["promotion_status"],
        )

    def test_direct_cli_help_runs_from_repo_root(self):
        root = Path(__file__).resolve().parents[1]
        completed = subprocess.run(
            [sys.executable, "tools/capture_quranenc_gloss.py", "--help"],
            cwd=root,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("Capture the pinned QuranEnc", completed.stdout)

    def test_success_is_complete_review_only_and_deterministic(
        self,
    ):
        now = datetime(
            2026,
            9,
            20,
            18,
            30,
            tzinfo=timezone.utc,
        )
        hashes = []
        for _ in range(2):
            with tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                authorize_capture(root)
                dest = capture_snapshot(
                    root,
                    fetcher=FakeFetcher(),
                    now=now,
                )
                self.assertEqual(
                    root / VAULT_RELATIVE,
                    dest,
                )
                manifest = json.loads(
                    (
                        dest
                        / "capture-manifest.json"
                    ).read_text()
                )
                self.assertEqual(
                    116,
                    manifest[
                        "raw_payload_count"
                    ],
                )
                self.assertEqual(
                    "captured-unreviewed",
                    manifest[
                        "promotion_state"
                    ],
                )
                self.assertFalse(
                    manifest[
                        "normal_build_dependency"
                    ]
                )
                self.assertTrue(
                    (
                        dest
                        / "LICENSE_SOURCE.html"
                    )
                    .read_bytes()
                    .startswith(b"<html>")
                )
                self.assertTrue(
                    (
                        dest
                        / "SOURCE_PAGE.html"
                    )
                    .read_bytes()
                    .startswith(b"<html>")
                )
                self.assertEqual(
                    hashlib.sha256(
                        (
                            dest
                            / "SOURCE_PAGE.html"
                        ).read_bytes()
                    ).hexdigest(),
                    manifest[
                        "source_page_snapshot"
                    ]["sha256"],
                )
                tar_bytes = (
                    dest
                    / "raw-snapshot.tar"
                ).read_bytes()
                hashes.append(
                    hashlib.sha256(
                        tar_bytes
                    ).hexdigest()
                )
                with tarfile.open(
                    fileobj=io.BytesIO(
                        tar_bytes
                    ),
                    mode="r:",
                ) as archive:
                    names = (
                        archive.getnames()
                    )
                    self.assertEqual(
                        116,
                        len(names),
                    )
                    self.assertIn(
                        "raw/sura-001.json",
                        names,
                    )
                    self.assertIn(
                        "raw/sura-114.json",
                        names,
                    )
                    self.assertEqual(
                        meta(),
                        archive.extractfile(
                            "metadata/"
                            "translations-list-"
                            "ar.pre.json"
                        ).read(),
                    )
                with self.assertRaisesRegex(
                    CaptureError,
                    "refusing to overwrite",
                ):
                    capture_snapshot(
                        root,
                        fetcher=FakeFetcher(),
                        now=now,
                    )
        self.assertEqual(
            hashes[0], hashes[1]
        )

    def test_naive_timestamp_fails_closed(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with self.assertRaisesRegex(
                CaptureError,
                "timezone-aware",
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(),
                    now=datetime(
                        2026, 9, 20, 18, 30
                    ),
                )
            self.assertFalse(
                (
                    root / VAULT_RELATIVE
                ).exists()
            )

    def test_version_mismatch_leaves_no_snapshot(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(root)
            with self.assertRaisesRegex(
                CaptureError,
                "expected pinned",
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(
                        version="1.0.1"
                    ),
                )
            self.assertFalse(
                (
                    root / VAULT_RELATIVE
                ).exists()
            )

    def test_mid_capture_metadata_drift_leaves_no_snapshot(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(root)
            with self.assertRaisesRegex(
                CaptureError,
                "metadata changed during capture",
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(
                        post_version="1.0.1"
                    ),
                )
            self.assertFalse(
                (
                    root / VAULT_RELATIVE
                ).exists()
            )

    def test_coordinate_gap_fails_closed(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(root)
            with self.assertRaisesRegex(
                CaptureError,
                "coordinate mismatch",
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(
                        bad_sura=2
                    ),
                )
            self.assertFalse(
                (
                    root / VAULT_RELATIVE
                ).exists()
            )

    def test_redirect_off_quranenc_fails_closed(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(root)
            with self.assertRaisesRegex(
                CaptureError,
                (
                    "approved QuranEnc "
                    "HTTPS hosts"
                ),
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(
                        final_host=(
                            "evil.example"
                        )
                    ),
                )

    def test_non_200_fails_closed_even_for_injected_fetcher(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(root)
            with self.assertRaisesRegex(
                CaptureError,
                "unexpected HTTP status",
            ):
                capture_snapshot(
                    root,
                    fetcher=FakeFetcher(
                        status=503
                    ),
                )

    def test_awaiting_licence_blocks_before_network(
        self,
    ):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            authorize_capture(
                root,
                status="awaiting-licence",
                redistribution_allowed=None,
            )

            def should_not_fetch(url):
                self.fail(
                    "network fetch attempted before "
                    "licence authorization"
                )

            with self.assertRaisesRegex(
                CaptureError,
                "licence review must promote",
            ):
                capture_snapshot(
                    root,
                    fetcher=should_not_fetch,
                )


if __name__ == "__main__":
    unittest.main()
