# Aaris Quran + Hadith Comprehension

A local-first, evidence-first Quran and Hadith comprehension system.

**North star:** Read → get stuck → tap → understand → keep reading.

This repository builds trust and reproducibility before UI breadth. Critical external content is not a runtime/build dependency until its exact legally redistributable artifact is preserved in the project-controlled Source Vault with provenance, a licence snapshot and integrity checks.

## Current phase

Phase 0A–0C is operational and the first Quran evidence source has passed the production Source Vault gate. Phase 1 now has a trusted Reader Core plus a minimal Android debug reader that projects the same source-faithful contract.

**Production-approved today:** Tanzil Quran Text v1.1, exact pinned Uthmani `txt-2` snapshot.

**Not production-approved yet:** Quranic Arabic Corpus morphology, Hadith datasets, QUL resources and other optional content. See `source-vault/registry.json`.

This is not yet a finished reader release. The current `quran-core` 1.0.4 pack remains unsigned/candidate, so the Android project deliberately disables the release variant. Word meanings, morphology, learning, Hadith retrieval and external-AI evidence workflows follow only after their required data foundations pass the same gates.

## Architecture boundaries

- `content.sqlite`: replaceable read-only content packs generated from pinned Source Vault artifacts.
- `user.sqlite`: precious local learning history and notes.
- Evidence Plane: immutable source-faithful Quran/Hadith records and attributed assertions.
- Learning Plane: glosses, exposure/review events, scheduler state and derived comprehension.
- AI may expand queries or reason over exported evidence; it cannot author Evidence Plane truth.
- Normal content builds use project-controlled snapshots, never an uncontrolled upstream `latest`.

## Current Quran core

`tools/quran_core.py` validates the pinned Tanzil artifact and the complete 114-surah / 6,236-ayah coordinate sequence while keeping original display text separate from derived search normalization.

`tools/build_quran_core.py` deterministically builds the current `quran-core` 1.0.4 candidate under `content-packs/` using provenance-bound manifest schema v2, including SQLite content, manifest and the source-derived Tanzil attribution notice. The pack contains 6,236 ayahs, keeps display Arabic separate from search-normalized lanes, and remains unsigned/candidate until release review and signing. Candidate packs are immutable build outputs and must pass the content-pack gate before promotion.

The ayah-only core intentionally does not manufacture canonical token/morphology identities. Reader Core may derive transient `ui-surface:` tap anchors for hit testing, but those spans never become TokenIDs, LexemeIDs or linguistic evidence.

## Phase 1 reader

`tools/reader_core.py` is the platform-independent trust/reference boundary: read-only SQLite, stable Quran coordinates, source-faithful `original_text`, fail-closed navigation and non-canonical surface tap anchors.

The Android app is a thin native projection of that contract. Its debug build references the existing `quran-core` 1.0.4 pack rather than duplicating Quran bytes, verifies pack SHA-256/size plus schema-v2 source hashes before read-only access, renders only `original_text`, and declares no direct network permission. The visible UI is limited to Surah navigation, Arabic ayahs, separate coordinates and source information.

## Validation

The main branch runs Source Vault/content-pack gates, SQLite schema checks and unit tests. Remote Actions are pinned to full commit SHAs, and the write-capable pack publisher revalidates the exact committed tree before pushing because `GITHUB_TOKEN`-generated pushes do not trigger ordinary push workflows.

The Android workflow additionally checks the pinned evidence contract, rejects canonical word-identity creation, runs JVM tests and assembles the debug APK. TalkBack, large-font, RTL and low-end-device performance remain explicit device release gates rather than inferred claims.
