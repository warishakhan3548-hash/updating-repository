# Progress — 2026-09-20

## Current phase

Phase 0A–0C foundation is established. Production content is intentionally blocked until exact legally redistributable source artifacts are preserved under project control.

## Completed

- product north star and reader/trust/privacy contracts;
- Source Vault policy, registry and machine-readable licence firewall;
- app-owned canonical ID policy;
- Evidence Plane vs Learning Plane separation;
- canonical SQLite content schema;
- append-only user learning/event schema;
- Lexeme → Sense → Occurrence model;
- Hadith edition/numbering/grade assertion model;
- multi-lane Arabic/Hadith search architecture with abstention;
- external-AI trust boundary and verify-back contract;
- content-pack manifest/provenance schemas;
- Quran and Hadith release invariants;
- accessibility/performance baseline;
- secure content-update lifecycle;
- executable Source Vault gate and schema validator;
- regression tests and GitHub Actions foundation workflow;
- primary-source research log and licence matrix.

## Validation performed

The Source Vault gate, both SQLite schemas and nine foundation behavioral checks were executed successfully in a reconstructed local validation workspace. The environment could not perform a clean GitHub clone because outbound DNS was unavailable, so this result is not represented as a GitHub Actions green check.

## Production data status

There are currently **zero production-approved external datasets**.

- Tanzil Quran Text v1.1: licence/release terms researched; exact selected artifact, licence snapshot and SHA-256 not yet preserved.
- Quranic Arabic Corpus v0.4: official terms researched; exact artifact not yet preserved.
- HadeethEnc: research candidate only pending edition/numbering and exact-version verification.
- QUL resources: per-resource licensing/provenance review required.
- Quran Foundation API: explicitly not a critical Source Vault dependency under current developer terms.

## Next safe milestone

Acquire the exact chosen Quran source artifact through its official download flow, preserve its exact bytes and licence snapshot under project control, compute SHA-256/size, create provenance, run the vault gate, then write the pinned importer and Quran integrity tests against that preserved snapshot.

Do not begin the production reader with copied/random Quran text while this gate is unresolved.
