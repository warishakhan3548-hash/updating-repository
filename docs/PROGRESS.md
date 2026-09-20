# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable. The first Quran Evidence Plane source is permanently mirrored, deterministic Quran-core packs are reproducible from pinned Source Vault bytes, and early Phase 1 now has a minimal Android reader over the verified local pack. Word-level comprehension remains deliberately blocked until token-level evidence passes the same legal/provenance gate.

## Completed

- product north star, Evidence Plane / Learning Plane boundary, privacy and offline-first contracts;
- Source Vault registry, licence firewall, provenance checks and immutable-source policy;
- app-owned canonical IDs and canonical SQLite content/user schemas;
- Evidence Plane update/delete protection and append-only learning-event history;
- edition-aware Hadith/grade data model and multi-lane search architecture with abstention;
- AI trust boundary, evidence-export/verify-back design and pack-manifest gate;
- exact Tanzil Quran Text v1.1 Uthmani snapshot preserved under project control;
- source SHA-256, licence snapshot SHA-256 and provenance SHA-256 bound into the vault gate;
- 114-surah / 6,236-ayah coordinate invariants;
- display Arabic separated from derived search-normalized lanes;
- deterministic Quran-core importer with byte-reproducibility coverage;
- current candidate Quran core pack published at `content-packs/quran-core/1.0.3/`;
- GitHub Actions foundation checks and deterministic pack build workflow;
- minimal Android reader shell with read-only verified pack activation, RTL Arabic rendering, Surah navigation and source notice access;
- Android contract tests that forbid network permission and normalized-text rendering on the reading path.

## Production Source Vault

### Production-approved: Tanzil Quran Text v1.1 — Uthmani

- artifact: `source-vault/quran/tanzil/1.1/uthmani-marks-sajdah-rub/quran-uthmani.txt`
- artifact bytes: `1384612`
- artifact SHA-256: `4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f`
- licence snapshot SHA-256: `1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68`
- provenance SHA-256: `733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505`
- redistribution: verbatim copies allowed under the archived source-specific terms with attribution/source-link requirements;
- modification of Quran source text: not allowed.

### Still blocked from production

- Quranic Arabic Corpus v0.4: `awaiting-licence` because official materials create a commercial-use/terms ambiguity.
- HadeethEnc: research candidate pending exact version, edition/collection mapping, numbering provenance and preserved artifact.
- QUL resources: each resource requires its own licence/provenance review.
- Quran Foundation API: not accepted as the permanent mirrored evidence foundation under current developer terms.

## Quran core candidate pack

- pack: `quran-core`
- content version: `1.0.3`
- artifact: `content-packs/quran-core/1.0.3/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `7acfb731c59ff2bc404752372eda8f30d16f38fa8c282aa4887ccb2fd8a2a025`
- records: `6236`
- importer: `quran-core-importer-4`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- source-derived attribution notice: `content-packs/quran-core/1.0.3/NOTICE.txt`
- notice SHA-256: `d52680db446c36e9f7878c704e1db6eee16328f854671276fc63533fb73f3483`

Candidate does not mean release-approved. Promotion still requires the project release/signing policy.

## Phase 1 reader slice

The Android reader references the existing `quran-core` 1.0.3 directory as build assets rather than creating another source copy. On first use it copies the SQLite artifact into a private versioned pack directory, verifies exact size/SHA-256 before activation, verifies runtime metadata, opens SQLite read-only, and queries only `quran_ayah.original_text`.

The initial app declares no direct network permissions. Coordinates are displayed separately from Quran text. Word-level tap, gloss and morphology are intentionally absent rather than derived from whitespace or AI.

## Validation status

Foundation automation checks Source Vault integrity, licence/provenance consistency, pack/source identity binding, attribution-notice hashing, pack-local artifact/notice isolation, SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, direct builder execution and deterministic pack reproducibility.

The Android workflow checks the pack contract, re-runs the Source Vault/content-pack gates, runs JVM unit tests and assembles a debug APK. No Hadith retrieval benchmark, FSRS retention benchmark, TalkBack device test or low-end Android performance number is claimed yet.

## Next safe milestones

1. Review/sign/promote the Quran core pack according to the release policy.
2. Exercise the reader with TalkBack, large fonts, RTL and representative low-end hardware; measure cold start, scroll and Surah-switch latency.
3. Add anchored word meaning only after a legally preserved, provenance-backed token/gloss source exists.
4. Resolve QAC licensing or choose a legally clearer morphology source.
5. Preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.
