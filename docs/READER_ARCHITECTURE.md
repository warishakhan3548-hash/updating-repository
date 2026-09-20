# Reader Architecture — Phase 1

## Purpose

The Reader is intentionally thinner than the content pipeline. Its job is to display already-verified Quran evidence and navigate stable coordinates. A low-level visual-span helper may support future alignment work, but unavailable word help is not exposed as an interaction.

The Reader must never become a second Quran database, a morphology generator, or a place where search-normalized text leaks into display.

## Trust boundary

Production flow:

`Source Vault -> deterministic importer -> gated/signed quran-core pack -> ReaderCore -> UI`

`ReaderCore.from_manifest()` reuses the existing content-pack gate. Production callers additionally refuse a pack whose manifest is not `approved`. Development/tests must opt in explicitly when exercising a `candidate` pack.

The runtime database is opened read-only. Reader models expose `original_text`; they do not expose `search_unicode` or `search_diacritic_free`.

## Navigation contract

A Quran position is an app-owned `QuranCoordinate(surah, ayah)` whose canonical ayah ID is `qa:SSS:AAA`.

The Reader supports:

- direct coordinate lookup;
- first/last positions;
- previous/next navigation across Surah boundaries;
- ordered iteration of the complete coordinate set;
- per-Surah ayah count for simple progress labels.

Invalid coordinates fail closed instead of silently falling back to a nearby ayah.

## Word-tap plumbing without fake morphology

The current `quran-core` pack line is deliberately ayah-only. It contains no canonical `quran_token` rows because no word-level morphology or gloss source has yet passed the Source Vault licence/provenance gate.

`ReaderCore.surface_tap_anchors()` remains a low-level, test-only alignment primitive that can derive transient non-whitespace spans from the exact displayed string. These spans are explicitly non-linguistic: they have no `TokenID`, `LexemeID`, root, lemma, gloss, or grammar claim and are never written to the Evidence Plane.

The Android reader does **not** currently expose those spans as tappable words. Showing a selectable word followed by “details are not installed” creates a dead-end interaction, encourages users to treat whitespace spans as semantic units, and gives touch users an affordance that has no meaningful accessible equivalent.

When a legally preserved word-level source is approved, a later pack may map visual spans to canonical token/segment IDs after explicit alignment tests. Only then should the UI expose tap-to-understand, with an equivalent screen-reader/focus action and a fail-closed “no verified meaning” state for unresolved mappings.

## Android UI implications

The future Android layer should remain a simple projection of this core:

1. local content pack is the source of truth;
2. Arabic renders from `ReaderAyah.original_text` only;
3. navigation events request another `QuranCoordinate`;
4. word help remains absent until a trusted word-level/gloss pack resolves it; when enabled, touch hit-testing and an equivalent accessibility action must resolve the same verified semantic target;
5. interactive controls should meet Android's 48dp minimum target guidance, with RTL and screen-reader semantics tested on-device.

No network call belongs on the critical read path.

## Release invariants

A Reader release fails if:

- the activated Quran pack fails the existing pack gate;
- an unapproved pack is accepted by the production reader path;
- display text comes from a normalized/search column;
- a missing coordinate is silently substituted;
- UI-only anchors are persisted as canonical Quran tokens;
- word meaning/morphology appears without a provenance-backed source assertion.

## Current limitation

This phase does **not** yet provide tap meanings. That is intentional. QAC v0.4 remains blocked by conflicting official usage statements, and QUL morphology cannot be treated as an independently cleared replacement until each resource's upstream licence/provenance is verified.
