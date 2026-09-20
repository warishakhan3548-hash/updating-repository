# Progress — 2026-09-21

## Current phase

Phase 0A–0C is executable and Phase 1 now has a minimal offline Android reader on the trusted read-only Reader Core boundary. The source-faithful canonical Quran JSONL layer now separates durable semantics from SQLite byte identity, and release authenticity now has a real Ed25519 trusted-key verifier. Production approval remains deliberately blocked until offline release-key custody is bootstrapped.

## Completed

- product north star, Evidence Plane / Learning Plane boundary, privacy and offline-first contracts;
- Source Vault registry, licence firewall, provenance checks and immutable-source policy;
- app-owned canonical IDs and canonical SQLite content/user schemas;
- Evidence Plane update/delete protection and append-only learning-event history;
- versioned `user.sqlite` schema v2 plus a conservative v1→v2 migration that preserves append-only history, canonicalizes only exact Again/Hard/Good/Easy review grades, records scheduler/context metadata for new reviews, and keeps scheduler state rebuildable;
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
- read-only Reader Core with stable `QuranCoordinate` navigation, production pack-approval guard and source-faithful `original_text` projection; its low-level ephemeral span helper remains non-canonical, while Android no longer exposes an unavailable word-tap action;
- minimal offline Android reader with RTL/source-faithful Arabic rendering and debug-only candidate-pack loading;
- Phase 1 reader accessibility semantics now mark headings, label indeterminate Quran load/search progress, expose failures with Compose error semantics plus polite live regions, announce completed no-result states politely, and expose approximate-search confidence as both visible text and semantic state; static regression coverage preserves 48dp controls, `sp` text, RTL and the absence of an unavailable word-tap gesture;
- strict local ayah-level Quran search over the existing provenance-bound Unicode/diacritic-free lanes, version-locked to `arabic-search-v1`, with source-faithful result rendering, query cancellation/debounce and explicit zero-result abstention;
- strict-miss-only `arabic-query-variant-v1` fallback for a small fixed set of Arabic orthographic and South-Asian keyboard substitutions; it never changes display/source text, labels every fallback hit **Approximate spelling match**, and does not claim general edit-distance/fuzzy retrieval;
- immutable historical `quran-search-golden-v1` strict-search baseline plus active `quran-search-golden-v2`, explicitly bound to `arabic-query-variant-v1`; the deterministic host evaluator/CI protects exact/no-harakat/partial and constrained orthographic/keyboard recall plus labelled no-answer abstention without rewriting old benchmark semantics;
- canonical Quran v3 builder/validator that inserts deterministic JSONL between Source Vault and runtime SQLite and rejects re-hashed canonical text drift;
- GitHub Actions foundation checks and deterministic pack build workflow;
- Ed25519 release-authenticity gate with deterministic signed-manifest bytes, content-derived key IDs, threshold policy, unauthorized/duplicate-key rejection, and project-controlled public trust-root storage;
- release-key lifecycle policy with active/retired/revoked states and signed release-sequence validity windows, preserving historical verification without allowing retired/revoked keys to authorize future releases;
- Android release builds delegate to the same authoritative pack gate instead of trusting signature-shaped metadata;
- Android release runtime persists the highest accepted signed release sequence plus exact pack SHA-256 under no-backup storage, rejects lower-sequence rollback and same-sequence byte collisions, and uses atomic replacement for both verified pack bytes and rollback state;
- Android reader CI runs Android/Compose lint alongside JVM tests and debug assembly, so framework lint errors block integration rather than being left to manual IDE review;
- project-owned offline signer for encrypted out-of-repository PKCS#8 Ed25519 keys, public-key/key-ID inspection, active-role and sequence-window enforcement, additive threshold signatures, cryptographic self-check, and create-only signed-manifest output;
- trust-root bootstrap remains intentionally incomplete: no private release key or fake approval was created in GitHub.
- primary-source audit identified QuranEnc `arabic_seraj` v1.0.0 as a promising verse-scoped difficult-word gloss source and defined a fail-closed gloss bridge that does not fabricate morphology or lexical IDs; source is now `awaiting-licence` pending clarification that immutable historical archival redistribution remains permitted after newer upstream versions appear.
- one-shot `tools/capture_quranenc_gloss.py` acquisition gate pins QuranEnc `arabic_seraj` v1.0.0, preserves exact pre/post metadata + 114 Surah response byte streams + official terms/source page, validates the complete 6,236-coordinate shape, rejects source drift/off-host redirects/partial capture/overwrite, and emits deterministic review-only snapshot metadata. It now also refuses any network acquisition unless the registry is explicitly `awaiting-artifact` with reviewed permissions; the current `awaiting-licence` state therefore blocks capture.

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

- QuranEnc Arabic Meanings of Words (As-Siraj) v1.0.0: `awaiting-licence`; its published republication conditions include staying updated to newer source versions, and immutable public redistribution of superseded historical snapshots is not yet clearly authorized. No bytes are captured while that question remains unresolved.
- Quranic Arabic Corpus v0.4: `awaiting-licence` because official materials create a commercial-use/terms ambiguity.
- QuranMorph (SinaLab/Birzeit, 2025): `awaiting-artifact`. Official catalogue licensing is materially clearer at CC BY 4.0, but the free-edition download is currently affiliation-gated; no exact bytes/version are mirrored, and the paper's 6,235-verse count still requires exact coordinate alignment against the 6,236-ayah Tanzil Evidence Plane.
- HadeethEnc Arabic: official version check reports v1.7.0; still a research candidate pending exact artifact preservation plus edition/collection mapping and numbering provenance.
- QUL resources: official morphology downloads expose word-location keyed lemma/root/stem data, but QUL's FAQ explicitly requires checking dataset-specific licensing for commercial use and the inspected morphology pages do not expose a dataset licence; no bytes are mirrored.
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

Automated coverage now checks Source Vault integrity, licence/provenance consistency, schema-v2/v3 manifest binding, manifest-to-SQLite provenance/notice consistency, required attribution-notice hashing, pack-local artifact/notice isolation (including symlink resolution), SQLite schemas including user-v2 migration coverage, sacred-text immutability, append-only learning events, Quran coordinate ordering, source hash/size, deterministic canonical/runtime generation, strict duplicate-free cross-runtime signed-JSON rules, threshold Ed25519 approval, and signed release ordering. The historical 1.0.4 publisher passed its release gate, and the schema-v3 publisher subsequently built, revalidated and pushed quran-core 1.1.0 from the exact main tree. CI now also rejects movable remote Action references, pins external Actions to verified full commit SHAs, and requires future generated-pack commits to revalidate Source Vault, pack, schema and unit-test gates on the exact committed tree before push.

Schema-v2 Quran semantic regression coverage now tampers with Quran text and SQLite schema, recomputes the runtime artifact SHA-256, and requires promotion to fail. Recomputing `built_sha256` after changing Quran text or SQLite schema does not make the pack valid.

Reader Core regression coverage checks read-only SQLite access, fail-closed coordinates, original-text-only models, navigation edges, complete 6,236-coordinate iteration, and the invariant that the current ayah-only pack still contains zero canonical `quran_token` rows. Android JVM coverage also locks representative `arabic-search-v1` query-normalization vectors while the search UI remains fail-closed on normalization-version mismatch. Signing regression coverage verifies valid Ed25519 approval, post-signing tamper failure, unauthorized/duplicate keys, signed release ordering, retired-key historical windows, revoked-key rejection, active-threshold viability, malformed/bootstrap trust roots, strict JSON/domain separation, and Android release delegation to the authoritative pack gate.

Quran search now has an executable host-side golden benchmark. Its host SQLite latency is diagnostic only and is not presented as low-end Android performance. No Hadith retrieval benchmark, FSRS retention benchmark, accessibility device test or low-end Android performance number is claimed yet because those systems are not mature enough to measure honestly. The learning-ledger change establishes durable inputs only; it does not claim that FSRS retention quality has been measured.

## Licence-firewall hardening

Commercial-use permission is represented independently from redistribution in the Source Vault registry. Production Source Vault validation and runtime pack promotion both fail closed unless `commercial_use_allowed` is explicitly true. QAC v0.4 is conservatively marked false from its official FAQ's non-commercial research condition; unknown candidates remain null rather than being inferred from repository or code licences. Existing preserved source/provenance bytes and Quran runtime packs were not rewritten.

## Next safe milestones

1. Perform the real offline release-key custody ceremony using the audited signer workflow: generate the key on a trusted offline machine, make an independent encrypted backup, separately review/activate only its public trust material, then create/review/sign a new immutable Quran-core production candidate. No production key has been generated by this repository or CI.
2. Add freshness/expiry metadata, explicit recovery behavior and a reviewed on-device signature verifier before enabling any automatic remote content-update channel; bundled-release highest-sequence persistence is now implemented.
3. Run the remaining physical accessibility/device validation for the minimal Android reader: TalkBack traversal/announcements, Switch Access, large-font/reflow, contrast/UI Check and representative low-end hardware. The code-level semantics baseline is now regression-tested. Keep word tap hidden until a provenance-backed linguistic/gloss pack is installed, then expose it with an equivalent accessible action rather than a gesture-only path.
4. Resolve QuranEnc’s archival-redistribution ambiguity first: its published republication terms require updates to newer source versions, while this project requires immutable historical snapshots. Keep it `awaiting-licence` and block capture until written clarification or another durable legal basis permits historical retention; only then move it to `awaiting-artifact`, run the one-shot capture, and separately review any production promotion.
5. Obtain QuranMorph through an authorized publisher path and verify its exact artifact, licence snapshot, checksum, and 6,236-ayah coordinate alignment; keep QAC/QUL blocked unless their own gates clear. Preserve an edition-aware Hadith source before production Hadith search.
6. Add an independent backup/archive for critical Source Vault artifacts and trust-root history.

One-shot acquisition/backfill workflows are removed after successful promotion of their outputs; provenance and Git history retain the audit trail.


### Canonical v3 integration status

Manifest schema v3 is now on `main`. The protected publisher generated `canonical/quran-core/1.0.0/ayahs.jsonl` and `quran-core 1.1.0`, revalidated the exact committed tree, and pushed the immutable candidate. Schema-v2 1.0.4 remains preserved for historical verification; the Android debug reader now targets the schema-v3 1.1.0 candidate.
