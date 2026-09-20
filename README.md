# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational. The first Quran Evidence Plane source has passed the Source Vault gate, `quran-core` 1.0.1 is the current candidate runtime pack, and the next pipeline version introduces an app-owned canonical Quran artifact between Source Vault bytes and SQLite.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished reader application. Reader UI, morphology-assisted word tap, learning, Hadith retrieval and external-AI evidence workflows follow only after their required data foundations pass the same gates.

## Architecture boundaries

- `source-vault/`: immutable legally verified external source bytes + licence/provenance.
- `canonical/`: deterministic app-owned semantic representation generated from approved Source Vault snapshots.
- `content-packs/`: replaceable optimized runtime artifacts generated from canonical data.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Quran core pipeline

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/quran_canonical.py` creates and verifies deterministic canonical JSONL with stable app-owned ayah IDs and exact Source Vault bindings.

`tools/build_quran_core.py` builds SQLite only from the validated canonical artifact. Manifest schema v2 records source identity, canonical hashes, runtime hash, attribution notice hash and the Python/SQLite build toolchain.

SQLite pack hashes protect published bytes. Long-term semantic reproducibility is anchored to the deterministic canonical artifact rather than assuming every future SQLite version emits identical physical bytes.

## Validation

The main branch runs `tools/vault_gate.py`, `tools/pack_gate.py`, `tools/validate_schemas.py`, and the full unit-test suite.

Trust-critical GitHub Actions are pinned to immutable commit SHAs and the Python build patch version is pinned. The Quran build workflow publishes new derived artifacts only from a stable `main`.
