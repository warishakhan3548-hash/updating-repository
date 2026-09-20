# Quran Contextual Gloss Source Audit — 2026-09-20

Purpose: find a legally preservable source that can make the north-star flow `Read → get stuck → tap → understand → keep reading` useful before a full morphology dataset is legally available, without inventing TokenIDs, lexical identities, or meanings.

| Claim | Primary source | Verified | Confidence | Licence / trust implication | Product implication |
|---|---|---:|---|---|---|
| QuranEnc currently lists **Arabic Language - Meanings of Words**, sourced from *As-Siraj fi Bayan Gharib Al-Quran*, as version **V1.0.0**. | https://quranenc.com/en/home ; https://quranenc.com/en/browse/arabic_seraj | 2026-09-20 | High | The source and version are identifiable. | Strong candidate for verse-scoped contextual help. |
| The resource is sparse/difficulty-oriented rather than complete word-by-word morphology: individual verses may expose one or several Arabic phrase → Arabic gloss entries, while other verses expose none. | https://quranenc.com/en/browse/arabic_seraj/4/127 ; https://quranenc.com/en/browse/arabic_seraj/5-3 | 2026-09-20 | High | It must not be represented as a complete token dictionary or morphology corpus. | Useful as an early “rare/difficult word rescue” layer that can abstain when no verified gloss exists. |
| QuranEnc documents version-aware translation-list, Surah, and Ayah API endpoints. | https://quranenc.com/en/home/api | 2026-09-20 | High | A one-shot acquisition process can preserve exact upstream response bytes instead of making the app depend on the live API. | Acquisition may use the API; production/runtime must use only the preserved project-controlled snapshot. |
| QuranEnc states translation content may be downloaded/re-published if it is not modified, QuranEnc/publisher is clearly referenced, the version is stated, transcript information is retained, notes are reported, newer source versions are tracked, and inappropriate advertising is avoided. | https://quranenc.com/en/home/api | 2026-09-21 | High for the published terms; Medium for whether immutable historical public redistribution remains permitted after a newer version appears | Treat the source as `awaiting-licence`. The requirement to update according to the latest source version is not yet proven compatible with our requirement to retain superseded snapshots publicly for reproducible builds. | Do not capture bytes into the public Source Vault until the archival-rights ambiguity is resolved. |
| The rendered Arabic resource listing exposes browsing but does not expose the same direct CSV/SQLite controls shown for many other translations. | https://quranenc.com/en/home | 2026-09-20 | Medium | Do not pretend a single downloadable immutable file has already been acquired. | If API acquisition is used, archive the complete exact response set plus translation-list/version metadata and per-file checksums as the raw source snapshot. |

## Decision

Register `quran-gloss.quranenc.arabic-seraj.v1.0.0` as **awaiting-licence**.

No QuranEnc content bytes are production-approved or capture-authorized by this change. The current Android reader must continue to abstain rather than invent a meaning when no verified local gloss pack is installed.

Before acquisition, obtain authoritative clarification that the republication terms permit this project to retain and redistribute immutable historical snapshots after a newer upstream version appears, or obtain an equivalent archival grant. Only after that review may the registry move to `awaiting-artifact` with explicit redistribution/modification/attribution flags.

After licence clearance, the acquisition sequence is:

1. update the registry to `awaiting-artifact` with reviewed permissions;
2. obtain authoritative Arabic translation-list metadata and confirm `arabic_seraj` at version 1.0.0;
3. capture the exact upstream response/file bytes for all required coordinates without editing them;
4. preserve the applicable QuranEnc API/terms page and the exact resource page;
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

- read `source-vault/registry.json` before any network request and refuse capture unless the source is explicitly `awaiting-artifact` with reviewed redistribution/modification/attribution permissions;
- pin `arabic_seraj` to version `1.0.0` before acquisition;
- preserve the exact translation-list response before and after capture and abort if the selected metadata changes;
- capture the exact 114 Surah API response byte streams without editing them;
- validate the complete ordered 6,236-coordinate Quran shape before publishing a snapshot directory;
- preserve the exact official QuranEnc API/terms page and resource page bytes alongside the source payload;
- reject non-HTTPS/off-QuranEnc redirects, non-200 responses, oversized/empty responses, coordinate gaps and destination overwrites;
- build a deterministic raw tar plus request-level SHA-256/size metadata, a candidate provenance record and checksums;
- leave the result explicitly `captured-unreviewed` until a human/source review promotes the registry entry.

This repository still has **no preserved QuranEnc production artifact**. The source remains `awaiting-licence` until the historical-archive redistribution question is resolved. Only then may it become `awaiting-artifact`, after which the real capture can run in a trusted network-enabled environment and the resulting bytes/terms can be reviewed for a separate production promotion. A runtime gloss importer must not precede that promotion.

