# Progress — 2026-09-20

## Current phase

Phase 0A–0C is executable and Phase 1 now has a minimal offline Android reader on the trusted read-only Reader Core boundary. The source-faithful canonical Quran JSONL layer now separates durable semantics from SQLite byte identity, and release authenticity now has a real Ed25519 trusted-key verifier. Production approval remains deliberately blocked until offline release-key custody is bootstrapped.

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
- preserved schema-v2 `quran-core 1.0.4` candidate retained for historical regression coverage;
- canonical schema-v3 `quran-core 1.1.0` candidate published from the deterministic Quran JSONL layer;
- schema-v2 Quran promotion independently verifies Source Vault semantic fidelity: canonical SQLite schema, source assertions/metadata, all 6,236 display rows, recomputed search lanes, and absence of undeclared morphology/Hadith evidence;
- read-only Reader Core with stable `QuranCoordinate` navigation, production pack-approval guard, source-faithful `original_text` projection, and ephemeral UI tap anchors that never become canonical TokenIDs;
- minimal offline Android reader with RTL/source-faithful Arabic rendering and debug-only candidate-pack loading;
- canonical Quran v3 builder/validator that inserts deterministic JSONL between Source Vault and runtime SQLite and rejects re-hashed canonical text drift;
- GitHub Actions foundation checks and deterministic pack build workflow;
- Ed25519 release-authenticity gate with deterministic signed-manifest bytes, content-derived key IDs, threshold policy, unauthorized/duplicate-key rejection, and project-controlled public trust-root storage;
- Android release builds delegate to the same authoritative pack gate instead of trusting signature-shaped metadata;
- trust-root bootstrap remains intentionally incomplete: no private release key or fake approval was created in GitHub.

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
- content version: `1.1.0`
- manifest schema: `3`
- artifact: `content-packs/quran-core/1.1.0/content.sqlite`
- artifact bytes: `4599808`
- artifact SHA-256: `c4c5d9e4819a11b06c24fda045bf583bd541d6e9285cd68a298e6f7c776acb61`
- records: `6236`
- importer: `quran-core-importer-6`
- canonical artifact: `canonical/quran-core/1.0.0/ayahs.jsonl`
- canonical SHA-256: `ae0682ac00e85009dec44293a6436ac04c6834d2de38b6ab0f4afc9843278e04`
- canonical records: `6236`
- search normalization: `arabic-search-v1`
- review status: `candidate`
- signature status: unsigned
- source-derived attribution notice: `content-packs/quran-core/1.1.0/NOTICE.txt`
- notice SHA-256: `d52680db446c36e9f7878c704e1db6eee16328f854671276fc63533fb73f3483`
- source licence SHA-256: `1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68`
- source provenance SHA-256: `733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505`
- supersedes: `quran-core@1.0.4`

Candidate does not mean release-approved. Version 1.1.0 adds the source-faithful canonical JSONL binding without changing Quran source text. The Android debug reader may exercise this candidate, while release builds remain fail-closed until reviewed public trust material exists and a new immutable pack is approved and signed.

## Validation status

Automated coverage now checks Source Vault integrity, licence/provenance consistency, schema-v2 manifest-to-vault binding, manifest-to-SQLite provenance/notice consistency, required attribution-notice hashing, pack-local artifact/notice isolation (including symlink resolution), SQLite schemas, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, direct builder CLI execution, and deterministic pack reproducibility. The historical 1.0.4 publisher passed its release gate, and the schema-v3 publisher subsequently built, revalidated and pushed quran-core 1.1.0 from the exact main tree. CI now also rejects movable remote Action references, pins external Actions to verified full commit SHAs, and requires future generated-pack commits to revalidate Source Vault, pack, schema and unit-test gates on the exact committed tree before push.

Schema-v2 Quran semantic regression coverage now tampers with Quran text and SQLite schema, recomputes the runtime artifact SHA-256, and requires promotion to fail. Recomputing `built_sha256` after changing Quran text or SQLite schema does not make the pack valid.

Reader Core regression coverage checks read-only SQLite access, fail-closed coordinates, original-text-only models, navigation edges, complete 6,236-coordinate iteration, and the invariant that the current ayah-only pack still contains zero canonical `quran_token` rows. Signing regression coverage verifies valid Ed25519 approval, post-signing tamper failure, unauthorized/duplicate keys, threshold enforcement, malformed/bootstrap trust roots, and Android release delegation to the authoritative pack gate.

No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly.

## Next safe milestones

1. Bootstrap durable offline release-key custody and independent backup, commit only the public trust material, then sign/review a new immutable Quran-core release candidate for production approval.
2. Persist the highest accepted signed `release_sequence` and add freshness/recovery state before enabling any automatic remote content-update channel.
3. Complete accessibility/device validation for the minimal Android reader and connect future word taps only to provenance-backed linguistic evidence.
4. Add word-level meaning only from a legally preserved, provenance-backed source; do not infer morphology from AI.
5. Resolve QAC licensing or choose a legally clearer morphology source, and preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts and trust-root history.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.


### Canonical v3 integration status

Manifest schema v3 is now on `main`. The protected publisher generated `canonical/quran-core/1.0.0/ayahs.jsonl` and `quran-core 1.1.0`, revalidated the exact committed tree, and pushed the immutable candidate. Schema-v2 1.0.4 remains preserved for historical verification; new reader work should target the schema-v3 candidate.
