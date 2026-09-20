from __future__ import annotations

from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from urllib.error import HTTPError

from tools.capture_quranenc_gloss import (
    DEFAULT_OUTPUT,
    EXPECTED_AYAH_COUNTS,
    EXPECTED_AYAH_COUNT,
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
    capture_snapshot,
    fetch_https,
    validate_existing,
)


ROOT = Path(__file__).resolve().parents[1]


def _source_index(version: str = EXPECTED_VERSION) -> bytes:
    return (
        "<html><body>"
        f"17/12/2025 - V{version}"
        f"<h2>{RESOURCE_TITLE}</h2>"
        f'<p>From the book "{RESOURCE_BOOK}".</p>'
        "</body></html>"
    ).encode("utf-8")


def _sura_bytes(sura: int, *, drop_last: bool = False) -> bytes:
    count = EXPECTED_AYAH_COUNTS[sura - 1]
    if drop_last:
        count -= 1
    return json.dumps(
        {
            "result": [
                {
                    "sura": sura,
                    "aya": aya,
                    "translation": f"معنى {sura}:{aya}",
                    "footnotes": "",
                }
                for aya in range(1, count + 1)
            ]
        },
        ensure_ascii=False,
        separators=(",", ":"),
    ).encode("utf-8")


def _download(
    url: str,
    body: bytes,
    *,
    final_url: str | None = None,
    status: int = 200,
) -> Download:
    return Download(
        requested_url=url,
        final_url=final_url or url,
        status=status,
        content_type="application/octet-stream",
        etag=None,
        last_modified=None,
        body=body,
    )


class FakeFetcher:
    def __init__(
        self,
        *,
        version: str = EXPECTED_VERSION,
        post_version: str | None = None,
        bad_sura: int | None = None,
        final_host: str | None = None,
        status: int = 200,
        requested_url_override: str | None = None,
    ) -> None:
        self.version = version
        self.post_version = post_version or version
        self.bad_sura = bad_sura
        self.final_host = final_host
        self.status = status
        self.requested_url_override = requested_url_override
        self.index_calls = 0

    def __call__(self, url: str) -> Download:
        body: bytes
        if url == SOURCE_INDEX_URL:
            self.index_calls += 1
            version = self.version if self.index_calls == 1 else self.post_version
            body = _source_index(version)
        elif url == TERMS_URL:
            body = b"<html><body>Terms and Policies</body></html>"
        elif url == SOURCE_PAGE_URL:
            body = b"<html><body>arabic_seraj</body></html>"
        else:
            prefix = SURA_URL_TEMPLATE.rsplit("{sura}", 1)[0]
            if not url.startswith(prefix):
                raise AssertionError(f"unexpected test URL: {url}")
            sura = int(url.rsplit("/", 1)[1])
            body = _sura_bytes(
                sura,
                drop_last=(self.bad_sura == sura),
            )

        final_url = url
        if self.final_host is not None:
            final_url = url.replace("quranenc.com", self.final_host)

        download = _download(
            url,
            body,
            final_url=final_url,
            status=self.status,
        )
        if self.requested_url_override is None:
            return download
        return Download(
            requested_url=self.requested_url_override,
            final_url=download.final_url,
            status=download.status,
            content_type=download.content_type,
            etag=download.etag,
            last_modified=download.last_modified,
            body=download.body,
        )


class QuranEncCaptureTests(unittest.TestCase):
    def test_direct_cli_help_runs_from_repo_root(self):
        completed = subprocess.run(
            [sys.executable, "tools/capture_quranenc_gloss.py", "--help"],
            cwd=ROOT,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(0, completed.returncode, completed.stderr)
        self.assertIn("offline-verify QuranEnc", completed.stdout)

    def test_preserved_repository_snapshot_revalidates_offline(self):
        provenance = validate_existing(ROOT / DEFAULT_OUTPUT)
        self.assertEqual(EXPECTED_AYAH_COUNT, provenance["record_count"])
        self.assertEqual(114, provenance["sura_count"])
        self.assertEqual(
            "8cbc4f5f41298e438f7862fff1eba309ffdab254ca240257bd5b652631f2396c",
            provenance["snapshot_manifest_sha256"],
        )
        self.assertEqual("captured-unreviewed", provenance["promotion_status"])

    def test_capture_preserves_exact_bytes_and_revalidates_offline(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            provenance = capture(
                output,
                FakeFetcher(),
                retrieved_at=datetime(
                    2026,
                    9,
                    20,
                    18,
                    30,
                    tzinfo=timezone.utc,
                ),
            )

            self.assertEqual(
                _sura_bytes(1),
                (output / "raw" / "suras" / "001.json").read_bytes(),
            )
            self.assertEqual(EXPECTED_AYAH_COUNT, provenance["record_count"])
            self.assertEqual(114, provenance["sura_count"])
            self.assertEqual(
                EXPECTED_VERSION,
                provenance["upstream_metadata"]["version"],
            )
            self.assertEqual(
                provenance["snapshot_manifest_sha256"],
                validate_existing(output)["snapshot_manifest_sha256"],
            )

    def test_capture_snapshot_compatibility_entrypoint(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            destination = capture_snapshot(
                root,
                fetcher=FakeFetcher(),
                now=datetime(
                    2026,
                    9,
                    20,
                    18,
                    30,
                    tzinfo=timezone.utc,
                ),
            )
            self.assertEqual(root / DEFAULT_OUTPUT, destination)
            self.assertEqual(
                EXPECTED_AYAH_COUNT,
                validate_existing(destination)["record_count"],
            )

    def test_wrong_upstream_version_leaves_no_partial_vault(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(CaptureError, "upstream version changed"):
                capture(
                    output,
                    FakeFetcher(version="1.0.1"),
                )
            self.assertFalse(output.exists())

    def test_mid_capture_source_index_drift_leaves_no_partial_vault(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(
                CaptureError,
                "source index changed during capture",
            ):
                capture(
                    output,
                    FakeFetcher(post_version="1.0.1"),
                )
            self.assertFalse(output.exists())

    def test_coordinate_gap_leaves_no_partial_vault(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(CaptureError, "coordinate mismatch"):
                capture(
                    output,
                    FakeFetcher(bad_sura=2),
                )
            self.assertFalse(output.exists())

    def test_existing_version_is_immutable(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, FakeFetcher())
            with self.assertRaisesRegex(CaptureError, "refusing to overwrite"):
                capture(output, FakeFetcher())

    def test_naive_capture_timestamp_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            with self.assertRaisesRegex(CaptureError, "timezone-aware"):
                capture(
                    output,
                    FakeFetcher(),
                    retrieved_at=datetime(2026, 9, 20, 18, 30),
                )
            self.assertFalse(output.exists())

    def test_injected_fetcher_cannot_redirect_off_quranenc(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(CaptureError, "trusted QuranEnc"):
                capture(
                    Path(tmp) / "vault" / "1.0.0",
                    FakeFetcher(final_host="evil.example"),
                )

    def test_injected_fetcher_cannot_substitute_requested_url(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(CaptureError, "requested URL mismatch"):
                capture(
                    Path(tmp) / "vault" / "1.0.0",
                    FakeFetcher(
                        requested_url_override=(
                            "https://quranenc.com/en/unexpected"
                        )
                    ),
                )

    def test_injected_non_200_fails_closed(self):
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(CaptureError, "HTTP status is not 200"):
                capture(
                    Path(tmp) / "vault" / "1.0.0",
                    FakeFetcher(status=503),
                )

    def test_post_capture_tamper_is_detected(self):
        with tempfile.TemporaryDirectory() as tmp:
            output = Path(tmp) / "vault" / "1.0.0"
            capture(output, FakeFetcher())
            primary = output / "raw" / "suras" / "001.json"
            primary.write_bytes(primary.read_bytes() + b"tamper\n")
            with self.assertRaisesRegex(
                CaptureError,
                "byte size mismatch|SHA-256",
            ):
                validate_existing(output)

    def test_retryable_http_failure_is_bounded(self):
        failure = HTTPError(
            SOURCE_INDEX_URL,
            503,
            "Service Unavailable",
            None,
            None,
        )
        with (
            patch(
                "tools.capture_quranenc_gloss.urlopen",
                side_effect=failure,
            ) as mocked_urlopen,
            patch("tools.capture_quranenc_gloss.time.sleep") as mocked_sleep,
        ):
            with self.assertRaisesRegex(CaptureError, "HTTP 503"):
                fetch_https(SOURCE_INDEX_URL)

        self.assertEqual(4, mocked_urlopen.call_count)
        self.assertEqual(
            [((1,), {}), ((2,), {}), ((4,), {})],
            mocked_sleep.call_args_list,
        )


if __name__ == "__main__":
    unittest.main()
