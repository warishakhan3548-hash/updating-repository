from __future__ import annotations

import json
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from tools.acquire_quranenc_gloss import (
    EXPECTED_VERSION,
    RESOURCE_BOOK,
    RESOURCE_TITLE,
    SOURCE_INDEX_URL,
    SOURCE_PAGE_URL,
    SURA_URL_TEMPLATE,
    TERMS_URL,
    CaptureError,
    Download,
    capture,
    fetch_https,
    sha256_bytes,
    validate_existing,
)


def _source_index(version: str = EXPECTED_VERSION) -> bytes:
    return (
        "<html><body>"
        f"17/12/2025 - V{version}"
        f"<h2>{RESOURCE_TITLE}</h2>"
        f'<p>From the book "{RESOURCE_BOOK}".</p>'
        "</body></html>"
    ).encode("utf-8")


def _sura_bytes(sura: int) -> bytes:
    return json.dumps(
        {
            "result": [
                {
                    "sura": sura,
                    "aya": 1,
                    "translation": f"معنى {sura}",
                    "footnotes": "",
                }
            ]
        },
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
        self.index = _source_index()
        self.terms = b"<html><body>Terms and Policies</body></html>"
        self.source_page = b"<html><body>arabic_seraj</body></html>"

    def fetcher(self, url: str) -> Download:
        if url == SOURCE_INDEX_URL:
            return _download(url, self.index)
        if url == TERMS_URL:
            return _download(url, self.terms)
        if url == SOURCE_PAGE_URL:
            return _download(url, self.source_page)
        prefix = SURA_URL_TEMPLATE.rsplit("{sura}", 1)[0]
        if url.startswith(prefix):
            sura = int(url.rsplit("/", 1)[1])
            return _download(url, _sura_bytes(sura))
        raise AssertionError(f"unexpected test URL: {url}")

    def test_capture_preserves_exact_api_bytes_and_revalidates_offline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, patch(
            "tools.acquire_quranenc_gloss.EXPECTED_AYAH_COUNT",
            114,
        ):
            output = Path(tmp) / "vault" / "1.0.0"
            provenance = capture(
                output,
                self.fetcher,
                retrieved_at="2026-09-20T18:30:00Z",
            )

            first = _sura_bytes(1)
            self.assertEqual(
                first,
                (output / "raw" / "suras" / "001.json").read_bytes(),
            )
            self.assertEqual(
                self.index,
                (output / "SOURCE_INDEX.html").read_bytes(),
            )
            self.assertEqual(
                self.terms,
                (output / "LICENSE_SOURCE.html").read_bytes(),
            )
            self.assertEqual(
                self.source_page,
                (output / "SOURCE_PAGE.html").read_bytes(),
            )
            self.assertEqual(114, provenance["record_count"])
            self.assertEqual(114, provenance["sura_count"])
            self.assertEqual(
                EXPECTED_VERSION,
                provenance["upstream_metadata"]["version"],
            )
            self.assertEqual("captured-unreviewed", provenance["promotion_status"])
            self.assertTrue(provenance["snapshot_manifest_sha256"])

            verified = validate_existing(output)
            self.assertEqual(
                provenance["snapshot_manifest_sha256"],
                verified["snapshot_manifest_sha256"],
            )

    def test_wrong_upstream_version_fails_without_partial_vault(self) -> None:
        bad_index = _source_index("1.0.1")

        def fetcher(url: str) -> Download:
            if url == SOURCE_INDEX_URL:
                return _download(url, bad_index)
            return self.fetcher(url)

        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(CaptureError, "upstream version changed"):
                capture(output, fetcher)
            self.assertFalse(output.exists())

    def test_existing_version_is_immutable(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, patch(
            "tools.acquire_quranenc_gloss.EXPECTED_AYAH_COUNT",
            114,
        ):
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, self.fetcher)
            with self.assertRaisesRegex(CaptureError, "refusing to overwrite"):
                capture(output, self.fetcher)

    def test_post_capture_tamper_is_detected(self) -> None:
        with tempfile.TemporaryDirectory() as tmp, patch(
            "tools.acquire_quranenc_gloss.EXPECTED_AYAH_COUNT",
            114,
        ):
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, self.fetcher)
            primary = output / "raw" / "suras" / "001.json"
            primary.write_bytes(primary.read_bytes() + b"tamper\n")

            with self.assertRaisesRegex(CaptureError, "byte size mismatch|SHA-256"):
                validate_existing(output)

    def test_retryable_http_failure_is_reported_after_bounded_retries(self) -> None:
        failure = HTTPError(SOURCE_INDEX_URL, 503, "Service Unavailable", None, None)
        with patch(
            "tools.acquire_quranenc_gloss.urlopen",
            side_effect=failure,
        ) as mocked_urlopen, patch(
            "tools.acquire_quranenc_gloss.time.sleep",
        ):
            with self.assertRaisesRegex(
                CaptureError,
                r"quranenc\.com/en/home: HTTP 503",
            ):
                fetch_https(SOURCE_INDEX_URL)

        self.assertEqual(4, mocked_urlopen.call_count)


if __name__ == "__main__":
    unittest.main()
