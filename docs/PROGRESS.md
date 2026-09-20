# Progress — 2026-09-20

## Current phase

Phase 0A–0C is established and executable. The first production Quran source is preserved and verified, and a deterministic Quran-core importer/builder now exists. Work is entering early Phase 1 without bypassing unresolved morphology or Hadith source gates.

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
- executable Source Vault and content-pack promotion gates;
- licence-policy fail-closed enforcement;
- source registry schema and provenance cross-checking;
- Evidence Plane immutability triggers;
- regression tests and GitHub Actions foundation workflow;
- primary-source research log and licence matrix;
- exact Tanzil Quran Text v1.1 Uthmani source snapshot preserved under project control;
- deterministic Quran-core parsing/build path with separate display/search fields;
- full 114-surah / 6,236-ayah coordinate validation;
- byte-reproducibility test for identical Quran pack inputs.

## Production Source Vault status

### Production-approved

**Tanzil Quran Text v1.1 — Uthmani**

- preserved artifact: `source-vault/quran/tanzil/1.1/uthmani-marks-sajdah-rub/quran-uthmani.txt`
- exact artifact SHA-256: `4b91f9e6e8ac645d039e4ed85b3be492e795232a31cd22d668ac58238722e26f`
- exact byte size: `1384612`
- licence snapshot: `LICENSE_SOURCE.html`
- licence snapshot SHA-256: `1ef7fbb0454f64ed4cceb838337808969711155f36147d1b357fc083336f4c68`
- provenance SHA-256: `733a938c4f54f082bf7f4e0b1d9bff7ce21afedceeba199294e872a428a57505`
- redistribution: allowed as verbatim copies under the archived Tanzil terms, with attribution/source-link requirements; modification of the Quran text is not allowed.

### Still blocked from production

- **Quranic Arabic Corpus v0.4:** `awaiting-licence`. Its official download page and official FAQ create a material commercial-use/terms ambiguity, so morphology remains blocked pending clarification or a clearly compatible authoritative licence basis.
- **HadeethEnc:** research candidate only. Exact version, edition/collection mapping, numbering provenance and preserved artifact still need review.
- **QUL resources:** per-resource licence/provenance review required; no blanket promotion.
- **Quran Foundation API:** not a critical Source Vault dependency under its current developer terms.

## Validation status

The latest verified main-branch foundation run is green. Automated checks cover:

- Source Vault integrity and policy enforcement;
- content-pack promotion rules;
- SQLite schema validation;
- sacred/source Evidence Plane immutability;
- append-only user learning events;
- separation of display text from search-normalized text;
- complete Quran coordinate count/ordering;
- preserved Tanzil artifact hash/size validation;
- deterministic Quran pack build reproducibility.

No Hadith search quality benchmark or device performance benchmark is claimed yet because those production systems are not built far enough to measure honestly.

## Next safe milestones

1. Produce/review the first candidate `quran-core` runtime pack from the pinned Tanzil snapshot and promote only after manifest/integrity review.
2. Build the minimal reader around immutable Quran evidence: stable navigation, excellent RTL, and anchored word-tap plumbing without inventing morphology.
3. Resolve QAC licensing before making it a production morphology dependency; otherwise choose a legally clearer alternative.
4. Acquire and preserve an edition-aware Hadith source before implementing production Hadith search.
5. Add an independent off-GitHub backup/archive for truly critical Source Vault artifacts.

Do not fill missing morphology, glosses or Hadith evidence from AI memory.
