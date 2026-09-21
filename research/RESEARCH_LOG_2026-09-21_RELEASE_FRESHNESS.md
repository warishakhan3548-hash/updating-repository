# Release Freshness / Recovery Research — 2026-09-21

This record separates verified facts from project inference. It does not claim that the project implements full TUF.

| Claim | Primary source | Confidence | Product implication |
| --- | --- | --- | --- |
| TUF signed metadata includes expiration so clients can detect outdated metadata. | https://theupdateframework.io/docs/metadata/ | High | Approved release metadata needs signed expiry semantics before network activation exists. |
| TUF treats rollback and indefinite freeze as distinct update-system attacks, and explicitly states that trust should expire if not renewed. | https://theupdateframework.io/docs/security/ | High | Monotonic release sequence alone is insufficient freshness protection. |
| TUF recommends short expiry for frequently refreshed Timestamp/Snapshot metadata (normally one day) and less frequent expiry for Root/Targets (normally one year). | https://theupdateframework.io/docs/faq/ | High | Bound static pack release metadata, but do not pretend a long-lived pack manifest substitutes for a future short-lived online freshness role. |
| The current TUF specification index lists v1.0.33 as latest. | https://theupdateframework.io/spec/ | High | Research target is current as of this audit. |
| Android's platform `java.security.Signature` lists Ed25519 support only from API 33+, while this app supports API 24+. | https://developer.android.com/reference/java/security/Signature | High | A platform-only Ed25519 verifier would strand API 24–32 devices; remote updates remain blocked until a reviewed compatible verifier/provider or versioned signature migration is chosen. |

## Architectural inference

The existing signed `release_sequence` protects against accepting a lower sequence that the app has already observed, but it cannot detect an attacker indefinitely replaying the latest metadata the client has seen. Signed expiry addresses that missing dimension.

However, applying wall-clock expiry to repository archival validation would make old releases fail merely because time passed. That conflicts with reproducibility. Therefore this project separates:

1. **historical/structural verification** — signatures and release windows remain verifiable forever; and
2. **new activation freshness** — a candidate must be within its signed validity window when it is newly trusted.

For v1 of this project-owned contract, approved static release metadata is capped at 366 days. That ceiling is deliberately targets-like, not a claim of full TUF freshness. Automatic network updates remain disabled until a short-lived authenticated freshness layer, staged-download flow, API-24-compatible on-device signature verification, and trust rotation/revocation protocol exist.

## UX implication

Freshness failures should be quiet and safe: keep reading from the current verified pack. Update security should not turn into a modal interruption or disable offline Quran access.
