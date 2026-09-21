#!/usr/bin/env python3
"""Signed release-freshness rules shared by release tooling.

Historical manifests remain verifiable after expiry. Wall-clock freshness is a
separate activation/signing decision so archival verification and reproducible
builds do not decay with time.
"""
from __future__ import annotations

from datetime import datetime, timedelta, timezone
import re
from typing import Any

RELEASE_TIMESTAMP_FORMAT = "%Y-%m-%dT%H:%M:%SZ"
_RELEASE_TIMESTAMP_RE = re.compile(
    r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"
)
MAX_RELEASE_VALIDITY = timedelta(days=366)


class ReleaseFreshnessError(RuntimeError):
    pass


def _parse_release_timestamp(value: object, field: str) -> datetime:
    if not isinstance(value, str) or not _RELEASE_TIMESTAMP_RE.fullmatch(value):
        raise ReleaseFreshnessError(
            f"{field} must be canonical UTC RFC 3339 seconds (YYYY-MM-DDTHH:MM:SSZ)"
        )
    try:
        parsed = datetime.strptime(value, RELEASE_TIMESTAMP_FORMAT)
    except ValueError as exc:
        raise ReleaseFreshnessError(f"{field} is not a valid UTC timestamp") from exc
    return parsed.replace(tzinfo=timezone.utc)


def validate_release_window(
    manifest: dict[str, Any],
) -> tuple[datetime, datetime] | None:
    """Validate signed freshness metadata without consulting the wall clock.

    Candidate/reviewed manifests may omit the release window. Approved
    manifests must include it. If either field is present on a non-approved
    manifest, both are validated so malformed pre-release metadata cannot hide.
    """
    issued_raw = manifest.get("release_issued_at")
    expires_raw = manifest.get("release_expires_at")
    approved = manifest.get("review_status") == "approved"

    if issued_raw is None and expires_raw is None and not approved:
        return None
    if issued_raw is None or expires_raw is None:
        raise ReleaseFreshnessError(
            "release_issued_at and release_expires_at must be provided together"
        )

    issued = _parse_release_timestamp(issued_raw, "release_issued_at")
    expires = _parse_release_timestamp(expires_raw, "release_expires_at")

    if expires <= issued:
        raise ReleaseFreshnessError(
            "release_expires_at must be later than release_issued_at"
        )
    if expires - issued > MAX_RELEASE_VALIDITY:
        raise ReleaseFreshnessError(
            "release freshness window may not exceed 366 days"
        )
    return issued, expires


def require_fresh_for_activation(
    manifest: dict[str, Any],
    now: datetime,
) -> tuple[datetime, datetime]:
    """Require an approved release to be current for a new trust decision."""
    if manifest.get("review_status") != "approved":
        raise ReleaseFreshnessError(
            "only an approved release may pass activation freshness"
        )
    if now.tzinfo is None or now.utcoffset() is None:
        raise ReleaseFreshnessError("activation time must be timezone-aware")

    window = validate_release_window(manifest)
    if window is None:  # pragma: no cover - approved manifests cannot reach this
        raise ReleaseFreshnessError("approved release is missing its freshness window")
    issued, expires = window
    current = now.astimezone(timezone.utc)

    if current < issued:
        raise ReleaseFreshnessError(
            "release metadata is not valid yet; clock or metadata may be wrong"
        )
    if current >= expires:
        raise ReleaseFreshnessError(
            "release metadata has expired; refuse a new activation"
        )
    return issued, expires
