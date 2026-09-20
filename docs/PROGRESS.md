# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable. The Quran Evidence Plane source is permanently mirrored and the current candidate runtime pack is `quran-core` 1.0.1. This branch adds the missing canonical-intermediate boundary and hardens reproducibility before the project enters the minimal Phase 1 reader.

## Completed on main before this branch

- product north star, Evidence Plane / Learning Plane boundary, privacy and offline-first contracts;
- Source Vault registry, licence firewall, provenance checks and immutable-source policy;
- app-owned canonical ID policy and SQLite content/user schemas;
- Evidence Plane update/delete protection and append-only learning-event history;
- edition-aware Hadith/grade data model and multi-lane search architecture with abstention;
- AI trust boundary, evidence-export/verify-back design and pack-manifest gate;
- exact Tanzil Quran Text v1.1 Uthmani snapshot preserved under project control;
- source, licence and provenance SHA-256 bindings;
- 114-surah / 6,236-ayah coordinate invariants;
- display Arabic separated from derived search-normalized lanes;
- candidate `quran-core` 1.0.1 with a hashed Tanzil attribution notice;
- GitHub Actions foundation checks and deterministic pack build workflow.

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

## Current Quran core candidate

- pack: `quran-core`
- content version: `1.0.1`
- artifact: `content-packs/quran-core/1.0.1/content.sqlite`
- artifact SHA-256: `34df2de57790226382d7693f1f64df78a78d446b83754d714e72787cc32f7b58`
- records: `6236`
- importer: `quran-core-importer-2`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- source notice SHA-256: `83cc1310c83bf3c67fb9b403c5939b4109a2cea9295fe6f610a756846ad9b7be`

Candidate does not mean release-approved.

## Reproducibility hardening in this branch

- add deterministic `canonical/quran-core/1.0.0/ayahs.jsonl`;
- bind its manifest directly to the exact Source Vault source ID/version/path/hash/licence;
- build `quran-core` 1.1.0 from canonical data rather than directly from the upstream file layout;
- introduce pack-manifest schema v2 with canonical hashes and build-toolchain provenance;
- scope SQLite byte-reproducibility claims to identical canonical input/importer/Python/SQLite;
- pin trust-critical GitHub Actions to full commit SHAs and Python to an exact patch release;
- preserve legacy pack-manifest v1 verification for already-published candidate packs.

The canonical artifact and `quran-core` 1.1.0 are derived outputs. They will be published by the main-branch build workflow only after this branch is reviewed/merged and validation succeeds; this document does not claim they already exist on main.

## Validation status

The branch's tests cover Source Vault integrity, pack/source identity binding, canonical/source identity binding, canonical tamper detection, runtime pack tamper detection, SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, canonical deterministic output, runtime deterministic output within the same toolchain, and attribution notice integrity.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Merge this reproducibility hardening only after CI passes, then let the main build workflow publish and validate canonical Quran 1.0.0 and `quran-core` 1.1.0.
2. Review/sign/promote the Quran core pack according to the release policy.
3. Build the minimal reader: immutable Arabic rendering, stable Surah/Ayah navigation, RTL/accessibility semantics, and anchored word-tap plumbing.
4. Add word-level meaning only from a legally preserved, provenance-backed source; do not infer morphology from AI.
5. Resolve QAC licensing or choose a legally clearer morphology source.
6. Preserve an edition-aware Hadith source before production Hadith search.
7. Add an independent off-GitHub backup/archive for critical Source Vault artifacts.
