# Reader Architecture — Phase 1

## Purpose

The Reader is intentionally thinner than the content pipeline. Its job is to display already-verified Quran evidence, navigate stable coordinates, and preserve the visual anchor needed for future tap-to-understand interactions.

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

The current `quran-core` pack line is deliberately ayah-only. It contains no canonical `quran_token` rows because no word-level morphology source has yet passed the Source Vault licence/provenance gate.

To let the UI prototype anchored taps safely, `ReaderCore.surface_tap_anchors()` derives transient non-whitespace spans from the exact displayed string. These anchors:

- are namespaced `ui-surface:`;
- carry character start/end offsets into the immutable ayah string;
- have no `TokenID`, `LexemeID`, root, lemma, gloss, or grammar claim;
- are never written to the Evidence Plane;
- may be discarded and regenerated at any time.

Whitespace hit splitting is therefore a rendering aid, not linguistic annotation.

When a legally preserved word-level source is approved, a later pack may map visual spans to canonical token/segment IDs after explicit alignment tests. Until then, the UI must not invent word meanings or morphology.

## Android UI implications

The future Android layer should remain a simple projection of this core:

1. local content pack is the source of truth;
2. Arabic renders from `ReaderAyah.original_text` only;
3. navigation events request another `QuranCoordinate`;
4. tap hit-testing may return a `SurfaceTapAnchor` but must show no authoritative linguistic detail unless a trusted word-level pack resolves it;
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
