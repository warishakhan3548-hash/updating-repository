# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable. The first Quran Evidence Plane source is permanently mirrored, a deterministic Quran-core builder exists, and the current complete candidate runtime pack has been produced from pinned Source Vault bytes. Work can enter the minimal Phase 1 reader without inventing morphology or Hadith evidence.

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
- deterministic Quran-core importer with same-toolchain byte-reproducibility coverage;
- complete candidate Quran core pack published at `content-packs/quran-core/1.0.1/`;
- required Tanzil attribution notice bound to the pack manifest by SHA-256;
- importer-independent Quran semantic verifier that reconstructs all 6,236 expected rows from the preserved Source Vault artifact;
- promotion-gate regression coverage proving sacred-text tampering still fails even when the altered SQLite file is assigned a freshly recomputed artifact SHA-256;
- GitHub Actions foundation checks and deterministic pack validation/build workflow.

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
- content version: `1.0.1`
- artifact: `content-packs/quran-core/1.0.1/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `34df2de57790226382d7693f1f64df78a78d446b83754d714e72787cc32f7b58`
- records: `6236`
- importer: `quran-core-importer-2`
- search normalization: `arabic-search-v1`
- notice: `content-packs/quran-core/1.0.1/NOTICE.txt`
- notice SHA-256: `83cc1310c83bf3c67fb9b403c5939b4109a2cea9295fe6f610a756846ad9b7be`
- review status: `candidate`
- signature status: unsigned

Candidate does not mean release-approved. Promotion must still pass review/signing policy.

## Validation status

Automated coverage checks Source Vault integrity, licence/provenance consistency, pack/source identity binding, attribution notice integrity, SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, direct builder CLI execution and deterministic pack reproducibility.

The Quran pack promotion boundary additionally verifies the shipped SQLite database independently against the Source Vault: database integrity, source assertion identity, release metadata, required immutability triggers, all 6,236 Quran display rows, recomputed derived search lanes, and absence of unrelated Evidence Plane rows.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Review/sign/promote the Quran core 1.0.1 candidate according to the release policy.
2. Build the minimal reader: immutable Arabic rendering, stable Surah/Ayah navigation, RTL/accessibility semantics, and anchored word-tap plumbing.
3. Add word-level meaning only from a legally preserved, provenance-backed source; do not infer morphology from AI.
4. Resolve QAC licensing or choose a legally clearer morphology source.
5. Preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.
