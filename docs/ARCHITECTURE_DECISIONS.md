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

## ADR-009 — Canonical intermediate is a permanent semantic boundary
Production importers do not couple the application schema directly to an upstream file layout. A deterministic app-owned canonical artifact sits between immutable Source Vault bytes and runtime packs. It carries stable canonical IDs, exact source bindings and source-faithful fields. Runtime databases may be regenerated or replaced without losing the durable semantic representation.

## ADR-010 — Reproducibility has two layers
Canonical JSONL bytes are the long-lived deterministic reproduction target. Published SQLite bytes are integrity-checked by SHA-256, while byte-identical rebuilding is scoped to the recorded importer, Python and SQLite toolchain. Long-term correctness is evaluated against canonical semantics and invariants rather than assuming arbitrary future database builders emit identical physical bytes.

## ADR-011 — CI actions are immutable dependencies
Third-party GitHub Actions used by trust-critical workflows are pinned to full commit SHAs. Human-readable version comments may document the corresponding major tag, but executable CI must not depend on a movable tag for checkout or toolchain setup.
