# Quran Contextual Gloss Source Audit — 2026-09-20

Purpose: find a legally preservable source that can make the north-star flow `Read → get stuck → tap → understand → keep reading` useful before a full morphology dataset is legally available, without inventing TokenIDs, lexical identities, or meanings.

| Claim | Primary source | Verified | Confidence | Licence / trust implication | Product implication |
|---|---|---:|---|---|---|
| QuranEnc currently lists **Arabic Language - Meanings of Words**, sourced from *As-Siraj fi Bayan Gharib Al-Quran*, as version **V1.0.0**. | https://quranenc.com/en/home ; https://quranenc.com/en/browse/arabic_seraj | 2026-09-20 | High | The source and version are identifiable. | Strong candidate for verse-scoped contextual help. |
| The resource is sparse/difficulty-oriented rather than complete word-by-word morphology: individual verses may expose one or several Arabic phrase → Arabic gloss entries, while other verses expose none. | https://quranenc.com/en/browse/arabic_seraj/4/127 ; https://quranenc.com/en/browse/arabic_seraj/5-3 | 2026-09-20 | High | It must not be represented as a complete token dictionary or morphology corpus. | Useful as an early “rare/difficult word rescue” layer that can abstain when no verified gloss exists. |
| QuranEnc documents translation-list, Surah, and Ayah API endpoints; live audit showed the Arabic translation-list endpoint does **not** reliably expose `arabic_seraj`, while the official resource index does expose the title/source/version and the documented Surah API serves the keyed data. | https://quranenc.com/en/home ; https://quranenc.com/en/home/api | 2026-09-21 | High | Version identity must bind to the official resource index rather than assuming catalog completeness. | If acquisition is later legally cleared, use the official index for version pinning and the documented Surah API for exact bytes. |
| QuranEnc states translation content may be downloaded/re-published if it is not modified, QuranEnc/publisher is clearly referenced, the version is stated, transcript information is retained, notes are reported, newer source versions are tracked, and inappropriate advertising is avoided. | https://quranenc.com/en/home/about/terms-and-conditions | 2026-09-21 | High for the published terms; Medium for permanent retention of superseded public snapshots | Treat the source as `awaiting-licence`. The stay-current obligation does not itself establish permission to keep superseded versions publicly mirrored forever. | Block new public Source Vault capture until historical-retention permission is verified; derived learning aids must remain separate from preserved assertions. |
| The rendered Arabic resource listing exposes browsing but does not expose the same direct CSV/SQLite controls shown for many other translations. | https://quranenc.com/en/home | 2026-09-20 | Medium | Do not pretend a single downloadable immutable file has already been acquired. | If API acquisition is used, archive the complete exact response set plus translation-list/version metadata and per-file checksums as the raw source snapshot. |

## Decision

Register `quran-gloss.quranenc.arabic-seraj.v1.0.0` as **awaiting-licence** until immutable historical redistribution is explicitly cleared.

No QuranEnc content bytes are production-approved. The current Android reader must continue to abstain rather than invent a meaning when no verified local gloss pack is installed. An exact v1.0.0 response set was captured for audit and is now preserved on `main` as `captured-unreviewed`. It is deliberately **not** bound into the production Source Vault registry and cannot become a runtime dependency while historical-retention rights remain unresolved.

The next production integration step begins only after archival-rights clearance:

1. change the registry to `awaiting-artifact` only after `historical_snapshot_retention_status` is `verified-allowed`;
2. use the official resource index to confirm `arabic_seraj` title/source/version at 1.0.0;
3. verify the preserved exact response set against the canonical offline validator, or capture a newer upstream version if the source has advanced;
4. preserve the applicable QuranEnc terms and resource-page snapshots;
5. record retrieval timestamp, URLs/status, version, sizes and SHA-256 values;
6. store the immutable snapshot under project control;
7. independently validate coordinates and content shape;
8. only then build a separate candidate gloss pack.

Normal builds must never re-query QuranEnc.

## Architecture consequence — verse-scoped gloss bridge

A contextual gloss source can improve reading before morphology is available **without pretending it provides morphology**.

`QuranCoordinate + tap surface → exact local source-phrase match → source-faithful contextual gloss → continue reading`

Rules:

- keep the Tanzil Quran display text authoritative and unchanged;
- keep the QuranEnc source phrase/gloss unchanged inside its preserved assertion;
- do not create canonical `TokenID`, `LexemeID`, `SenseID`, root, lemma, or grammar from whitespace or AI;
- use conservative deterministic alignment only; no fuzzy Evidence-Plane binding;
- if the phrase is absent, ambiguous, or cannot be mapped safely, return **no verified gloss**;
- keep this data in a separate optional content pack that depends on the Quran core rather than rebuilding sacred Quran bytes;
- when a legally verified morphology source later exists, add an explicit mapping overlay from the preserved gloss assertion to canonical lexical entities instead of rewriting the raw assertion.

This bridge is intentionally asymmetric: it can answer some “what does this difficult expression mean here?” taps early, while full morphology waits for a properly licensed source.

## Acquisition gate implementation

`tools/capture_quranenc_gloss.py` is the one-shot acquisition boundary for this candidate. It is intentionally **not** part of normal builds and does not mutate `source-vault/registry.json`.

The capture is fail-closed:

- consult `source-vault/registry.json` before any network request and require explicit capture permission plus `historical_snapshot_retention_status=verified-allowed`;
- pin `arabic_seraj` to version `1.0.0` from the official resource index before acquisition;
- preserve the exact source-index response before and after capture and abort if the selected metadata changes;
- capture the exact 114 Surah API response byte streams without editing them;
- validate the complete ordered 6,236-coordinate Quran shape before publishing a snapshot directory;
- preserve the exact official QuranEnc terms page and resource page bytes alongside the source payload;
- reject non-HTTPS/off-QuranEnc redirects, non-200 responses, oversized/empty responses, coordinate gaps and destination overwrites;
- build a deterministic raw tar plus request-level SHA-256/size metadata, a candidate provenance record and checksums;
- leave the result explicitly `captured-unreviewed` until a human/source review promotes the registry entry.

This repository has an exact **captured-unreviewed** QuranEnc v1.0.0 snapshot but still has **no production-approved QuranEnc artifact**. The source remains `awaiting-licence`; the canonical acquisition gate blocks new network capture, and the preserved review bytes must remain quarantined from runtime use unless archival-rights review clears the source and a later Source Vault promotion passes all integrity gates.


## Follow-up — redistribution freshness boundary (verified 2026-09-21)

Current primary-source review still shows **Arabic Language - Meanings of Words** as version **V1.0.0** on QuranEnc's official resource index. The documented Arabic translation-list endpoint was not reliable for this specific key during live acquisition, so version checks for `arabic_seraj` now bind to the official index. QuranEnc's published republication terms require publishers to update according to the latest source version.

That creates two distinct invariants:

1. **Archive invariant:** keep every exact legally preserved snapshot forever so historical builds remain reproducible and no upstream deletion can erase our evidence trail.
2. **Release-eligibility invariant:** before approving a newly distributed pack from a source with a latest-version condition, explicitly verify the official upstream version and bind that review into the signed pack manifest.

The implementation records release freshness separately from archival permission. `release_requirements` and a signed `source_release_review` can enforce a stay-current obligation only **after** historical snapshot retention has been verified allowed. While that permission remains unresolved, the registry stays `awaiting-licence` and capture is blocked before network access. Normal builds never query QuranEnc.
