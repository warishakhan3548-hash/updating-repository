# Reader Architecture — Phase 1

## Purpose

The Reader is intentionally thinner than the content pipeline. Its job is to display already-verified Quran evidence, navigate stable coordinates, and preserve the visual anchor needed for future tap-to-understand interactions.

The Reader must never become a second Quran database, a morphology generator, or a place where search-normalized text leaks into display.

## Trust boundary

Production flow:

`Source Vault -> deterministic importer -> gated/signed quran-core pack -> ReaderCore -> platform UI`

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

To let UI layers prototype anchored taps safely, `ReaderCore.surface_tap_anchors()` derives transient non-whitespace spans from the exact displayed string. These anchors:

- are namespaced `ui-surface:`;
- carry character start/end offsets into the immutable ayah string;
- have no `TokenID`, `LexemeID`, root, lemma, gloss, or grammar claim;
- are never written to the Evidence Plane;
- may be discarded and regenerated at any time.

Whitespace hit splitting is therefore a rendering aid, not linguistic annotation.

When a legally preserved word-level source is approved, a later pack may map visual spans to canonical token/segment IDs after explicit alignment tests. Until then, the UI must not invent word meanings or morphology.

## Android implementation

The Android layer is now a thin native projection of this contract rather than a second Reader Core.

- the debug source set references `content-packs/quran-core/1.0.4/` directly, so Quran evidence is not copied into a second repository tree;
- on first use, `content.sqlite` is copied into a versioned app-private directory and checked against the manifest-bound byte size and SHA-256 before activation;
- the installed SQLite file is opened read-only and schema/content/source hashes are rechecked from `pack_metadata`;
- the UI queries and renders `quran_ayah.original_text` only;
- Surah/Ayah coordinates are rendered separately from sacred text;
- database verification and reads run off the UI thread;
- standard Material controls and explicit semantics are used for navigation/source actions;
- the manifest has no `INTERNET` or `ACCESS_NETWORK_STATE` permission.

Because `quran-core` 1.0.4 is still unsigned and marked `candidate`, it is packaged only for the Android debug source set and the release variant is disabled. This mirrors the Reader Core rule that production callers must refuse unapproved packs.

The first visible Android slice intentionally does **not** show tap meanings yet. The transient anchor model exists at the Reader Core boundary, but a tap cannot become authoritative linguistic detail until a trusted word-level pack resolves it.

## Release invariants

A Reader release fails if:

- the activated Quran pack fails the existing pack gate;
- an unapproved pack is accepted by the production reader path;
- display text comes from a normalized/search column;
- a missing coordinate is silently substituted;
- UI-only anchors are persisted as canonical Quran tokens;
- word meaning/morphology appears without a provenance-backed source assertion;
- Android release packaging can include an unsigned candidate Quran pack.

## Validation

Repository tests bind the Android constants to the exact `quran-core` manifest, verify schema-v2 source hashes, forbid direct network permissions and reject Android source code that creates `TokenID`, `LexemeID` or `quran_token` identity in this phase.

Android CI uses full-SHA-pinned Actions, re-runs Source Vault/content-pack gates, runs JVM tests and assembles the debug APK.

Device-level TalkBack, large-font, RTL, low-end performance and scroll-smoothness testing remain explicit release gates; successful compilation alone is not treated as proof.

## Current limitation

This phase does **not** yet provide tap meanings. That is intentional. QAC v0.4 remains blocked by conflicting official usage statements, and QUL morphology cannot be treated as an independently cleared replacement until each resource's upstream licence/provenance is verified.
