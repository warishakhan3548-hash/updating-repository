from __future__ import annotations

import json
import tempfile
from pathlib import Path
import unittest

from tools.acquire_quranenc_gloss import (
    CSV_URL,
    EXPECTED_VERSION,
    SOURCE_PAGE_URL,
    TERMS_URL,
    TRANSLATION_KEY,
    TRANSLATION_LIST_URL,
    CaptureError,
    Download,
    capture,
    sha256_bytes,
    validate_existing,
)


def _csv_bytes() -> bytes:
    rows = ["sura,aya,translation,footnotes"]
    rows.extend(
        f"1,{index},معنى {index},"
        for index in range(1, 121)
    )
    return ("\n".join(rows) + "\n").encode("utf-8")


def _metadata_bytes(version: str = EXPECTED_VERSION) -> bytes:
    return json.dumps(
        [
            {
                "key": TRANSLATION_KEY,
                "language_iso_code": "ar",
                "version": version,
                "last_update": "2026-09-20",
                "title": "Arabic Language - Meanings of Words",
                "description": "test fixture",
            }
        ],
        ensure_ascii=False,
    ).encode("utf-8")


def _download(url: str, body: bytes) -> Download:
    return Download(
        requested_url=url,
        final_url=url,
        status=200,
        content_type="application/octet-stream",
        etag=None,
        last_modified=None,
        body=body,
    )


class QuranEncCaptureTests(unittest.TestCase):
    def setUp(self) -> None:
        self.csv = _csv_bytes()
        self.metadata = _metadata_bytes()
        self.terms = b"<html><body>Terms and Policies</body></html>"
        self.source_page = b"<html><body>arabic_seraj V1.0.0</body></html>"

    def fetcher(self, url: str) -> Download:
        bodies = {
            CSV_URL: self.csv,
            TRANSLATION_LIST_URL: self.metadata,
            TERMS_URL: self.terms,
            SOURCE_PAGE_URL: self.source_page,
        }
        return _download(url, bodies[url])

    def test_capture_preserves_exact_bytes_and_revalidates_offline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            provenance = capture(
                output,
                self.fetcher,
                retrieved_at="2026-09-20T18:30:00Z",
            )

            self.assertEqual(
                self.csv,
                (output / "raw" / "arabic_seraj.csv").read_bytes(),
            )
            self.assertEqual(
                self.metadata,
                (output / "raw" / "translations-list-ar.json").read_bytes(),
            )
            self.assertEqual(
                self.terms,
                (output / "LICENSE_SOURCE.html").read_bytes(),
            )
            self.assertEqual(
                self.source_page,
                (output / "SOURCE_PAGE.html").read_bytes(),
            )
            self.assertEqual(sha256_bytes(self.csv), provenance["sha256"])
            self.assertEqual(len(self.csv), provenance["byte_size"])
            self.assertEqual("captured-unreviewed", provenance["promotion_status"])

            verified = validate_existing(output)
            self.assertEqual(provenance["sha256"], verified["sha256"])

    def test_wrong_upstream_version_fails_without_partial_vault(self) -> None:
        bad_metadata = _metadata_bytes("1.0.1")

        def fetcher(url: str) -> Download:
            if url == TRANSLATION_LIST_URL:
                return _download(url, bad_metadata)
            return self.fetcher(url)

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(CaptureError, "upstream version changed"):
                capture(output, fetcher)
            self.assertFalse(output.exists())

    def test_existing_version_is_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, self.fetcher)
            with self.assertRaisesRegex(CaptureError, "refusing to overwrite"):
                capture(output, self.fetcher)

    def test_post_capture_tamper_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, self.fetcher)
            primary = output / "raw" / "arabic_seraj.csv"
            primary.write_bytes(primary.read_bytes() + b"tamper\n")

            with self.assertRaisesRegex(CaptureError, "SHA-256"):
                validate_existing(output)


if __name__ == "__main__":
    unittest.main()
