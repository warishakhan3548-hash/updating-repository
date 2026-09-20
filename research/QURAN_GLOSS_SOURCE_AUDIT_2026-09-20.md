# Quran Contextual Gloss Source Audit — 2026-09-20

Purpose: find a legally preservable source that can make the north-star flow `Read → get stuck → tap → understand → keep reading` useful before a full morphology dataset is legally available, without inventing TokenIDs, lexical identities, or meanings.

| Claim | Primary source | Verified | Confidence | Licence / trust implication | Product implication |
|---|---|---:|---|---|---|
| QuranEnc currently lists **Arabic Language - Meanings of Words**, sourced from *As-Siraj fi Bayan Gharib Al-Quran*, as version **V1.0.0**. | https://quranenc.com/en/home ; https://quranenc.com/en/browse/arabic_seraj | 2026-09-20 | High | The source and version are identifiable. | Strong candidate for verse-scoped contextual help. |
| The resource is sparse/difficulty-oriented rather than complete word-by-word morphology: individual verses may expose one or several Arabic phrase → Arabic gloss entries, while other verses expose none. | https://quranenc.com/en/browse/arabic_seraj/4/127 ; https://quranenc.com/en/browse/arabic_seraj/5-3 | 2026-09-20 | High | It must not be represented as a complete token dictionary or morphology corpus. | Useful as an early “rare/difficult word rescue” layer that can abstain when no verified gloss exists. |
| QuranEnc documents version-aware translation-list, Surah, and Ayah API endpoints. | https://quranenc.com/en/home/api | 2026-09-20 | High | A one-shot acquisition process can preserve exact upstream response bytes instead of making the app depend on the live API. | Acquisition may use the API; production/runtime must use only the preserved project-controlled snapshot. |
| QuranEnc states translation content may be downloaded/re-published if it is not modified, QuranEnc/publisher is clearly referenced, the version is stated, transcript information is retained, notes are reported, newer source versions are tracked, and inappropriate advertising is avoided. | https://quranenc.com/en/home/api | 2026-09-21 | High for the published terms; Medium for whether immutable historical public redistribution remains permitted after a newer version appears | Treat the source as `awaiting-licence`. The requirement to update according to the latest source version is not yet proven compatible with our requirement to retain superseded snapshots publicly for reproducible builds. | Do not capture bytes into the public Source Vault until the archival-rights ambiguity is resolved; derived learning aids remain separate from source assertions. |
| The rendered Arabic resource listing exposes browsing but does not expose the same direct CSV/SQLite controls shown for many other translations. | https://quranenc.com/en/home | 2026-09-20 | Medium | Do not pretend a single downloadable immutable file has already been acquired. | If API acquisition is used, archive the complete exact response set plus translation-list/version metadata and per-file checksums as the raw source snapshot. |

## Decision

Register `quran-gloss.quranenc.arabic-seraj.v1.0.0` as **awaiting-licence**.

No QuranEnc content bytes are production-approved or currently capture-authorized. A review-only snapshot was captured earlier in commit `95e8fc41fae70c4687e41ac887df7ab0c2c2eb48`; after the stronger archival-retention review, those bytes are removed from the active Source Vault tree and remain excluded from registry artifact fields. The current Android reader must continue to abstain rather than invent a meaning when no verified local gloss pack is installed.

Before acquisition, obtain authoritative clarification that the republication terms permit this project to retain and redistribute immutable historical snapshots after a newer upstream version appears, or obtain an equivalent archival grant. Only after that review may the registry move to `awaiting-artifact` with explicit redistribution/modification/attribution flags.

After licence clearance, the acquisition/preservation sequence is:

1. set `historical_snapshot_retention_status=verified-allowed` and update the registry to `awaiting-artifact` with reviewed permissions;
2. obtain authoritative translation-list metadata and confirm the then-current `arabic_seraj` version;
3. either restore the exact historical review capture if the grant permits that version, or reacquire the then-current official bytes through the gated capture path;
4. preserve the applicable QuranEnc API/terms page and exact resource page;
5. record retrieval timestamp, URLs/status, version, sizes and SHA-256 values;
6. store the immutable snapshot under project control;
7. independently validate coordinates and content shape;
8. only then build a separate candidate gloss pack;
9. before release approval, separately bind the latest-upstream-version review into the signed manifest.

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

- read `source-vault/registry.json` before any network request and refuse capture unless the source is explicitly `awaiting-artifact` with reviewed redistribution/modification/attribution permissions;
- pin `arabic_seraj` to version `1.0.0` before acquisition;
- preserve the exact translation-list response before and after capture and abort if the selected metadata changes;
- capture the exact 114 Surah API response byte streams without editing them;
- validate the complete ordered 6,236-coordinate Quran shape before publishing a snapshot directory;
- preserve the exact official QuranEnc API/terms page and resource page bytes alongside the source payload;
- reject non-HTTPS/off-QuranEnc redirects, non-200 responses, oversized/empty responses, coordinate gaps and destination overwrites;
- build a deterministic raw tar plus request-level SHA-256/size metadata, a candidate provenance record and checksums;
- leave the result explicitly `captured-unreviewed` until a human/source review promotes the registry entry.

This repository still has **no preserved QuranEnc production artifact**. The source remains `awaiting-licence` until the historical-archive redistribution question is resolved. The earlier review capture is an audit artifact in Git history, not a production Source Vault dependency, and its active-tree copy is removed. Only after archival permission is verified may the source become `awaiting-artifact` and an exact snapshot be restored/reacquired for review. A runtime gloss importer must not precede that promotion.


## Follow-up — redistribution freshness boundary (verified 2026-09-21)

Current primary-source review still shows **Arabic Language - Meanings of Words** as version **V1.0.0**. QuranEnc's API documentation exposes a version-bearing translations-list endpoint, and its published republication terms require publishers to update the translation according to the latest version issued by QuranEnc.

That creates three distinct invariants:

1. **Acquisition-permission invariant:** do not move a source to `awaiting-artifact` or register preserved bytes while historical snapshot retention remains unresolved.
2. **Archive invariant:** once archival redistribution is legally cleared, keep every exact legally preserved snapshot allowed by that grant so historical builds remain reproducible and no upstream deletion can erase our evidence trail.
3. **Release-eligibility invariant:** before approving a newly distributed pack from a source with a latest-version condition, explicitly verify the official upstream version and bind that review into the signed pack manifest.

The implementation records the future release-time condition as `release_requirements` on the Source Vault entry and `source_release_review` on an approved pack. That second gate becomes relevant only after the archival-retention gate is cleared. It intentionally does not make normal builds query QuranEnc and does not claim that software can replace legal/source review. If a compatible archival grant is obtained and the official version later advances, the preserved old snapshot remains part of the reproducibility record only to the extent that grant permits, while a newly distributed approved pack must use a source version that passes the current release review.
