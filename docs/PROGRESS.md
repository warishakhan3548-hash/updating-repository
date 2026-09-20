# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable. The first Quran Evidence Plane source is permanently mirrored, the provenance-bound Quran core is reproducible, and Phase 1 now has a trusted read-only Reader Core boundary. Android presentation can build on verified ayah navigation without inventing morphology or Hadith evidence.

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
- complete candidate Quran core pack published at `content-packs/quran-core/1.0.4/`, using provenance-bound manifest schema v2;
- read-only Reader Core with stable `QuranCoordinate` navigation, production pack-approval guard, source-faithful `original_text` projection, and ephemeral UI tap anchors that never become canonical TokenIDs;
- GitHub Actions foundation checks and deterministic pack build workflow;\n- fail-closed release authenticity gate: `approved` packs are rejected until their cryptographic signatures can be verified against trusted project keys.

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
- content version: `1.0.4`
- manifest schema: `2`
- artifact: `content-packs/quran-core/1.0.4/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `492fcc4caa33b5ba64c94abce4d5f78d00232a99b777ea5e3bd70c338e19fa09`
- records: `6236`
- importer: `quran-core-importer-5`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- source-derived attribution notice: `content-packs/quran-core/1.0.4/NOTICE.txt`
- notice SHA-256: `d52680db446c36e9f7878c704e1db6eee16328f854671276fc63533fb73f3483`
- source licence SHA-256: `1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68`
- source provenance SHA-256: `733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505`
- supersedes: `quran-core@1.0.3`

Candidate does not mean release-approved. Version 1.0.4 strengthens the runtime trust boundary without changing Quran source text: the manifest is bound to Source Vault attribution/licence/provenance metadata, and the gate cross-checks the same identity plus exact notice text/hash inside SQLite `pack_metadata`.

## Validation status

Automated coverage now checks Source Vault integrity, licence/provenance consistency, schema-v2 manifest-to-vault binding, manifest-to-SQLite provenance/notice consistency, required attribution-notice hashing, pack-local artifact/notice isolation (including symlink resolution), SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, direct builder CLI execution, and deterministic pack reproducibility. The 1.0.4 publish workflow ran 44 tests successfully and passed the content-pack gate before pushing the generated pack. CI now also rejects movable remote Action references, pins external Actions to verified full commit SHAs, and requires future generated-pack commits to revalidate Source Vault, pack, schema and unit-test gates on the exact committed tree before push.

Reader Core regression coverage checks read-only SQLite access, fail-closed coordinates, original-text-only models, navigation edges, complete 6,236-coordinate iteration, and the invariant that the current ayah-only pack still contains zero canonical `quran_token` rows.\n\nPack-signing regression coverage uses RFC 8032 test material to verify real Ed25519 signatures, tamper rejection, deterministic payload generation, threshold enforcement, retired-key historical verification, revoked-key rejection and mandatory signed release sequencing. The production trusted-key registry contains no key material yet.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Conduct an offline production release-key ceremony, enroll only the reviewed public key, then create/review/sign a new immutable Quran core version; do not rewrite 1.0.4.
2. Build the minimal Android reader UI on the Reader Core contract: immutable Arabic rendering, stable Surah/Ayah navigation, RTL/accessibility semantics, and anchored word-tap hit testing.
3. Add word-level meaning only from a legally preserved, provenance-backed source; do not infer morphology from AI.
4. Resolve QAC licensing or choose a legally clearer morphology source.
5. Preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.
