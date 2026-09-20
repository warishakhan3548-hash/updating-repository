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

## ADR-009 — Exact-byte integrity and semantic fidelity are separate gates
A runtime pack SHA-256 identifies exact shipped bytes, but it does not by itself prove that those bytes faithfully represent the preserved sacred source. Quran pack promotion therefore performs a second, importer-independent semantic check: reopen the SQLite artifact read-only, verify its canonical schema and database integrity, reconstruct expected rows and source notice/attribution from the production-approved Source Vault artifact, then compare original Arabic, derived search lanes and source assertions. A process that changes evidence and merely recomputes a file hash must still fail.
