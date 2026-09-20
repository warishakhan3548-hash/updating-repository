# Research Record — HadeethEnc Archival Rights — 2026-09-21

Purpose: decide whether HadeethEnc Arabic can legally enter the project's immutable public Source Vault before any Hadith artifact is downloaded or mirrored.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---|---|---|
| fact | HadeethEnc's official Arabic site offers Arabic content for download as Excel/PDF and states that downloaded translations may be republished only under listed conditions. | https://hadeethenc.com/ar | 2026-09-21 | High | HadeethEnc is a plausible Hadith source, but admission depends on all source-specific conditions. |
| fact | The official republication conditions prohibit modification, require source/publisher attribution, require version retention, require keeping transcript information, and require downstream copies to be updated according to newer HadeethEnc versions. | https://hadeethenc.com/ar | 2026-09-21 | High | Current-version republication permission is not equivalent to permission for indefinite redistribution of superseded immutable snapshots. |
| fact | HadeethEnc's official version-check surface reports that Arabic v1.3.0 has a newer v1.7.0 release. | https://hadeethenc.com/en/check/ar/v1.3.0 | 2026-09-21 | High | Arabic v1.7.0 is the current observed candidate version; a future release review must check again before shipping. |
| inference | The inspected terms do not clearly establish a right to keep older HadeethEnc versions publicly mirrored forever after a newer source version appears. | primary-source terms + Source Vault durability requirement | 2026-09-21 | High | Keep HadeethEnc `awaiting-licence`; do not download or mirror source bytes until archival-retention permission is clarified. |
| open question | The inspected HadeethEnc republication terms do not separately state a commercial-use grant. | primary-source terms | 2026-09-21 | Medium | Keep `commercial_use_allowed` unknown rather than inferring it from redistribution permission. |
| inference | Edition/collection/numbering provenance is independent of copyright permission. | product evidence model | 2026-09-21 | High | Even after licence gates clear, HadeethEnc must still pass bibliographic/record-identity review before Evidence Plane promotion. |

## Decision

Do **not** capture or mirror HadeethEnc Arabic bytes yet.

The registry records:

- source: HadeethEnc Arabic;
- observed current version: v1.7.0;
- status: `awaiting-licence`;
- historical snapshot retention: `unresolved`;
- commercial-use permission: unknown;
- latest upstream version review: required;
- no Source Vault artifact, licence snapshot, provenance file or checksum yet.

This is intentionally the same archival boundary used for QuranEnc: a "stay current" condition can coexist with permission to republish the current version while still leaving historical public archival rights unclear. Commercial-use permission remains a separate independent release dimension.

## Promotion path

Only after archival retention and commercial-use rights are explicitly documented as compatible with the intended release:

1. move the source to a capture-authorized state;
2. fetch the exact then-current official artifact;
3. preserve the exact legal/terms snapshot;
4. calculate artifact/licence/provenance SHA-256 values and byte sizes;
5. preserve the artifact under project control without modification;
6. verify edition, collection, numbering and grade/source fields;
7. build a candidate canonical Hadith model;
8. before any approved release, perform the separate latest-version review required by the source terms.

No production Hadith importer or search pack should be built on HadeethEnc before those gates pass.
