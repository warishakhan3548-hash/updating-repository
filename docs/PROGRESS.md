# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable. The first Quran Evidence Plane source is permanently mirrored, a deterministic Quran-core builder exists, and the first complete candidate runtime pack has been produced from pinned Source Vault bytes. Work can now enter the minimal Phase 1 reader without inventing morphology or Hadith evidence.

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
- complete candidate Quran core pack published at `content-packs/quran-core/1.0.2/`;
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

## Quran core candidate pack

- pack: `quran-core`
- content version: `1.0.2`
- artifact: `content-packs/quran-core/1.0.2/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `fbb8827d9a80b29087153178615ede039d15aa50c33c43b536ebcd8c9eaa531e`
- records: `6236`
- importer: `quran-core-importer-3`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- source-derived attribution notice: `content-packs/quran-core/1.0.2/NOTICE.txt`
- notice SHA-256: `731ac0d39eb5081307625f5111b19bd8786c6646e695aa8fb0263ad701f41544`

Candidate does not mean release-approved. Promotion must still pass review/signing policy. Version 1.0.1 remains preserved as the preceding candidate; 1.0.2 replaces the hand-maintained notice with notice text derived from the pinned source artifact and binds provenance attribution/source URL into runtime metadata.

## Validation status

Automated coverage now checks Source Vault integrity, licence/provenance consistency, pack/source identity binding, required attribution-notice hashing, pack-local artifact/notice isolation (including symlink resolution), SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, direct builder CLI execution, and deterministic pack reproducibility. The Evidence foundation workflow passed after the attribution-notice gate and regression tests were added.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Review/sign/promote the Quran core pack according to the release policy.
2. Build the minimal reader: immutable Arabic rendering, stable Surah/Ayah navigation, RTL/accessibility semantics, and anchored word-tap plumbing.
3. Add word-level meaning only from a legally preserved, provenance-backed source; do not infer morphology from AI.
4. Resolve QAC licensing or choose a legally clearer morphology source.
5. Preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.
