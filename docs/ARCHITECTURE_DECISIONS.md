# Architecture Decisions

## ADR-001 — Two databases
Use replaceable read-only `content.sqlite` packs and a separate `user.sqlite` for precious personal state. Content upgrades must not endanger years of learning history.

## ADR-002 — Evidence vs Learning planes
Immutable source-faithful assertions are structurally separated from derived learning aids, glosses and AI outputs.

## ADR-003 — Event-preserving learning
Exposure and review logs are append-only. Scheduler state is a projection. FSRS is an adapter, not a permanent schema dependency.

## ADR-004 — Local deterministic retrieval
SQLite is the baseline. Evaluate FTS5/BM25 and trigram/custom Arabic lanes before adding heavier search dependencies.

## ADR-005 — No critical Quran Foundation API dependency
Current Quran Foundation developer terms make the API unsuitable as this project's permanent mirrored foundation. It may remain an optional integration where its terms are satisfied.

## ADR-006 — 48dp Android interaction floor
Important Android controls target at least 48dp touch areas. Inline Arabic word hit regions may expand semantically without visually increasing inter-word spacing.

## ADR-007 — Signed content updates when distribution exists
Use TUF-style version, hash, signature and rollback principles rather than ad-hoc URL replacement, while keeping implementation minimal until real downloadable packs exist.

## ADR-008 — Runtime packs cannot outrun Source Vault trust
A runtime content pack may only reference a `production-approved` Source Vault entry. CI cross-checks the pack's source ID, version, vault path, source hash and licence against the registry, then verifies the built artifact's own hash and byte size. `approved` packs require signature metadata. This turns provenance from documentation into an executable release boundary.


## ADR-009 — Ayah-only Quran core until morphology passes the Source Vault gate
The first Quran core stores source-faithful ayah evidence and derived search lanes only. It does not manufacture canonical token, segment, lexeme or morphology identities by whitespace splitting. Word-level linguistic identities wait for a legally compatible morphology source that independently passes the Source Vault gate and mapping invariants.

## ADR-010 — Runtime attribution is derived from preserved evidence
For a source whose preserved artifact embeds its required notice, the runtime pack derives its notice from that pinned artifact rather than a separately hand-maintained paraphrase. Provenance attribution and source URL are bound into runtime metadata. Pack artifacts and notices must resolve inside their own immutable manifest directory so one pack cannot borrow another pack's evidence or notice by path or symlink.

## ADR-011 — Trusted build workflows are content dependencies
Remote GitHub Actions used by evidence/content builds are pinned to full commit SHAs and guarded by tests. A workflow that commits generated evidence artifacts with `GITHUB_TOKEN` must validate the exact committed tree before push; it must not assume that its bot-generated push will trigger another ordinary `push` workflow.


## ADR-012 — Exact-byte integrity and semantic fidelity are separate gates

A runtime pack SHA-256 identifies exact shipped bytes, not whether those bytes still faithfully represent preserved sacred evidence. For provenance-bound Quran packs (manifest schema v2), promotion therefore reconstructs Source Vault evidence, opens the SQLite artifact read-only, verifies the canonical schema and source assertion/runtime metadata, compares all Quran display/search rows with independently derived expectations, and rejects undeclared morphology/Hadith evidence. Historical schema-v1 candidates remain immutable under their historical contract rather than being rewritten in place.


## ADR-013 — Canonical Quran semantics are the long-lived reproducibility anchor

Runtime SQLite byte identity is useful but can depend on the pinned Python/SQLite toolchain. Quran evidence therefore has a deterministic canonical JSONL layer between Source Vault and runtime packs. Schema-v3 packs bind to that canonical manifest/artifact, while promotion independently proves that every canonical ayah exactly matches the preserved Source Vault row and that every runtime Quran row/search lane still derives from the same evidence. Recomputing hashes after changing sacred text is not sufficient to restore validity.


## ADR-014 — Signed release ordering is separate from client anti-rollback state

Every `approved` content-pack manifest carries a positive integer `release_sequence`, and that field is inside the authenticated manifest payload. This gives pack releases one explicit monotonic ordering primitive instead of relying on semantic-version string comparison, publication time, Git history, or mutable server state.

A signed sequence alone does not prevent rollback. A future downloaded-pack client must persist the highest accepted sequence, reject lower sequences by default, and expose any recovery/downgrade path explicitly. Freshness/expiry and atomic activation remain separate update-system responsibilities.

The current Ed25519 verifier is a repository/build-time boundary. Android platform `Signature` support for Ed25519 begins at API 33 while this app supports older Android versions, so a future on-device updater must use a reviewed compatible verifier/provider or introduce a versioned signature-format migration. It must not silently assume the build-time Python verifier is available on device.


## ADR-015 — Preserve historical signatures without trusting old keys forever

Release-key rotation must not force deletion of the public key needed to verify an old approved pack, but retaining an old key must not let a later compromise authorize new releases. Trusted release keys therefore have active/retired/revoked lifecycle state and signed release-sequence validity windows. Retired keys require a finite maximum sequence; revoked keys never count. The active release role must still contain enough active keys to satisfy its threshold.

This is repository-side trust policy. It complements, but does not replace, the future client requirement to persist the highest accepted release sequence and freshness state.


## ADR-016 — Release signing is offline, additive and cannot approve content

Production release private keys remain outside the repository and CI. The project-owned signer accepts only encrypted PKCS#8 Ed25519 private keys whose resolved paths are outside the repository, prompts for their passwords interactively, derives the existing project key ID, and signs through the existing canonical payload contract.

Signing authority is separated from content review: the signer refuses manifests that are not already `approved`, requires the key to be active and authorized for the signed release-sequence window, refuses duplicate signatures by the same key, and creates a new output file instead of overwriting an input.

Threshold signing is additive because the top-level signature block is intentionally excluded from the signed payload. This keeps the release ceremony reproducible and library-replaceable without making private-key generation, key custody, review approval, or repository mutation a hidden side effect of the signing tool.

## ADR-017 — Verse-scoped verified glosses may precede full morphology

The product may add a separate optional contextual-gloss pack before a complete morphology pack exists, but only when its exact source snapshot has passed the Source Vault gate. A source-provided verse phrase and contextual gloss remain an attributed assertion bound to `QuranCoordinate`; they do not manufacture `TokenID`, `LexemeID`, `SenseID`, root, lemma, or grammar.

Reader tap resolution at this boundary is conservative: bind a gloss only when the preserved source phrase can be located deterministically and unambiguously against the source-faithful ayah. Fuzzy matching may help research/search, but it must not silently promote a fuzzy phrase alignment into Evidence Plane truth. If the mapping is absent or ambiguous, the UI abstains.

This lets difficult-word comprehension improve independently of morphology licensing while preserving the long-term lexical model. When verified morphology later exists, an explicit mapping overlay may connect the unchanged gloss assertion to canonical lexical entities.

## ADR-018 — Canonical review history outlives the scheduler

The Learning Plane stores review events as durable user history and treats scheduler memory state as a rebuildable projection. New user-schema-v2 review rows record a canonical grade (again/hard/good/easy), the scheduler adapter and version used at the time, an optional content context reference, and the event-schema version.

This contract deliberately does not serialize FSRS equations, parameter vectors or library-specific card objects into permanent event identity. A future scheduler may replay the same preserved events into a different cache implementation.

The v1→v2 migration never guesses the meaning of an unknown historical outcome. Exact canonical grade strings are mapped; all other legacy outcomes remain verbatim with no canonical grade. Historical rows stay append-only.
