from __future__ import annotations

from datetime import datetime, timezone
import unittest

from tools.release_freshness import (
    ReleaseFreshnessError,
    require_fresh_for_activation,
    validate_release_window,
)


class ReleaseFreshnessTests(unittest.TestCase):
    def _approved(self) -> dict:
        return {
            "review_status": "approved",
            "release_issued_at": "2026-09-21T00:00:00Z",
            "release_expires_at": "2027-09-21T00:00:00Z",
        }

    def test_candidate_may_omit_release_window(self):
        self.assertIsNone(validate_release_window({"review_status": "candidate"}))

    def test_approved_release_requires_both_signed_timestamps(self):
        manifest = self._approved()
        manifest.pop("release_expires_at")
        with self.assertRaisesRegex(ReleaseFreshnessError, "provided together"):
            validate_release_window(manifest)

    def test_timestamps_must_use_canonical_utc_seconds(self):
        manifest = self._approved()
        manifest["release_issued_at"] = "2026-09-21T05:30:00+05:30"
        with self.assertRaisesRegex(ReleaseFreshnessError, "canonical UTC"):
            validate_release_window(manifest)

    def test_expiry_must_follow_issue_time(self):
        manifest = self._approved()
        manifest["release_expires_at"] = manifest["release_issued_at"]
        with self.assertRaisesRegex(ReleaseFreshnessError, "later"):
            validate_release_window(manifest)

    def test_release_window_is_bounded(self):
        manifest = self._approved()
        manifest["release_expires_at"] = "2028-09-21T00:00:00Z"
        with self.assertRaisesRegex(ReleaseFreshnessError, "366 days"):
            validate_release_window(manifest)

    def test_fresh_approved_release_can_be_considered_for_new_activation(self):
        manifest = self._approved()
        window = require_fresh_for_activation(
            manifest,
            datetime(2027, 1, 1, tzinfo=timezone.utc),
        )
        self.assertEqual(
            "2026-09-21T00:00:00+00:00",
            window[0].isoformat(),
        )

    def test_expired_release_is_rejected_for_new_activation(self):
        manifest = self._approved()
        with self.assertRaisesRegex(ReleaseFreshnessError, "expired"):
            require_fresh_for_activation(
                manifest,
                datetime(2027, 9, 21, tzinfo=timezone.utc),
            )

    def test_future_release_is_rejected_for_new_activation(self):
        manifest = self._approved()
        with self.assertRaisesRegex(ReleaseFreshnessError, "not valid yet"):
            require_fresh_for_activation(
                manifest,
                datetime(2026, 9, 20, 23, 59, 59, tzinfo=timezone.utc),
            )

    def test_activation_time_must_be_timezone_aware(self):
        with self.assertRaisesRegex(ReleaseFreshnessError, "timezone-aware"):
            require_fresh_for_activation(
                self._approved(),
                datetime(2027, 1, 1),
            )


if __name__ == "__main__":
    unittest.main()
