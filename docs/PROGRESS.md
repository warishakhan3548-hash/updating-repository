# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable and Phase 1 has a minimal offline Android reader on the trusted read-only Reader Core boundary. The canonical Quran JSONL layer now separates durable Quran semantics from SQLite byte identity. Release authenticity uses Ed25519 with explicit signed release ordering and key lifecycle rules; production approval remains blocked until offline release-key custody is bootstrapped.

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
- deterministic Quran canonical JSONL and runtime pack builders;
- schema-v2/v3 Quran promotion independently verifies Source Vault semantic fidelity;
- read-only Reader Core with stable `QuranCoordinate` navigation and source-faithful `original_text`;
- minimal offline Android reader with RTL/source-faithful Arabic rendering and no direct network permission;
- GitHub Actions supply-chain pins plus exact-tree publisher revalidation;
- Ed25519 release-authenticity gate with content-derived key IDs, threshold policy and Android release delegation;
- signature-v2 hardening: domain-separated payload, strict signed JSON, positive signed `release_sequence`, active/retired/revoked key lifecycle, and bounded retired-key sequence windows;
- trust-root bootstrap remains intentionally incomplete: no production private key or fake approval was created in GitHub.

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
- Quran Foundation API: not accepted as the permanent mirrored Evidence Plane foundation under current developer terms.

## Current Quran core candidate

- pack: `quran-core`
- content version: `1.1.0`
- manifest schema: `3`
- artifact: `content-packs/quran-core/1.1.0/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `c4c5d9e4819a11b06c24fda045bf583bd541d6e9285cd68a298e6f7c776acb61`
- records: `6236`
- importer: `quran-core-importer-6`
- canonical artifact: `canonical/quran-core/1.0.0/ayahs.jsonl`
- canonical artifact SHA-256: `ae0682ac00e85009dec44293a6436ac04c6834d2de38b6ab0f4afc9843278e04`
- canonical manifest SHA-256: `3aa49f92faca8e010df128b451f76ff1bd27b6bb7333942b2a105586e6f580af`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- supersedes: `quran-core@1.0.4`

Candidate does not mean release-approved. Version 1.1.0 is immutable publisher output; it must not be rewritten merely to add signature-v2 metadata or approval.

The Android reader currently remains pinned to the earlier 1.0.4 candidate. Moving the reader to 1.1.0 is a separate tested migration, not an implicit content swap.

## Validation status

Automated coverage checks Source Vault integrity, licence/provenance consistency, schema-v2/v3 manifest binding, canonical artifact fidelity, manifest-to-SQLite metadata consistency, attribution hashing, pack-local path/symlink isolation, sacred-text immutability, append-only learning events, Quran coordinate ordering, deterministic pack generation, workflow SHA pinning, and exact-tree publisher validation.

Signing regression coverage verifies valid Ed25519 approval, signed-field tamper failure, signed release-sequence tamper failure, unauthorized/duplicate/revoked keys, threshold enforcement, bounded retired keys, bootstrap trust roots, duplicate JSON metadata rejection, unsafe numeric/Unicode rejection, and Android release delegation to the authoritative pack gate.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility-device result or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Run/merge the signature-v2 regression suite without changing any source or Quran runtime bytes.
2. Bootstrap durable offline release-key custody and independent backup, then commit only reviewed public trust material.
3. Sign/review a **new immutable Quran-core content version**; do not mutate 1.1.0.
4. Add persistent highest-sequence/freshness state before enabling any automatic remote content-update channel.
5. Migrate the Android reader to the schema-v3 pack in a dedicated tested change.
6. Complete accessibility/device validation and connect future word taps only to provenance-backed linguistic evidence.
7. Resolve QAC licensing or choose a legally clearer morphology source, then preserve an edition-aware Hadith source before production Hadith search.
8. Add an independent backup/archive for critical Source Vault artifacts and trust-root history.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.
