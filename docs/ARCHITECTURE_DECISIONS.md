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

## ADR-011 — Mirroring begins the integrity contract
An unmirrored research candidate may remain metadata-only. Once any Source Vault preservation field is populated, the artifact/licence/provenance snapshot must be complete and hash-consistent even before production promotion. Preserved public snapshots require verified redistribution permission plus explicit modification/attribution flags. Release builders remain stricter: they may consume only `production-approved` entries. This closes the gap where candidate bytes could otherwise drift silently between acquisition and later review.

