# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational and the first Quran evidence source has passed the production Source Vault gate. Early Phase 1 now includes a minimal Android reader over the verified Quran core; word-level comprehension remains gated on legally preserved token-level evidence.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished product. Learning, morphology-assisted word tap, Hadith retrieval and external-AI evidence workflows follow only after their required data foundations pass the same gates.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/build_quran_core.py` deterministically builds the current `quran-core` 1.0.3 candidate under `content-packs/`, including SQLite content, manifest and a source-derived Tanzil attribution notice. The pack contains 6,236 ayahs and remains unsigned/candidate until release review and signing.

The ayah-only core intentionally does not manufacture canonical token/morphology identities by whitespace splitting. Word-level morphology and glosses wait for a legally preserved, production-approved source.

## Early Phase 1 Android reader

The Android reader bundles the existing `quran-core` 1.0.3 directory by reference rather than copying a second Quran database into the app tree. At runtime it verifies the exact pack SHA-256 and size before activation, validates pack metadata, opens SQLite read-only and displays only `quran_ayah.original_text`.

The initial manifest contains no direct network permission. The visible experience is deliberately small: Surah navigation, exact Arabic ayahs, separate coordinates and source information. See `docs/READER_ARCHITECTURE.md`.

## Validation

The repository runs the Source Vault/content-pack gates, SQLite schema checks and unit tests. The Android reader workflow additionally checks its pinned pack contract and assembles a debug APK.

Device TalkBack, large-font, RTL, low-end performance and scroll-smoothness measurements remain explicit release work; repository compilation is not treated as proof of those qualities.
