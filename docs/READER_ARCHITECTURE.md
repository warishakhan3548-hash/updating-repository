# Phase 1 Reader Architecture

## Purpose

The first reader slice proves the product north star without weakening the Evidence Plane. It renders the exact verified Quran Arabic already present in `quran-core` and deliberately postpones word-level meaning/morphology until a legally preserved token-level source passes the Source Vault gate.

## Data path

`content-packs/quran-core/1.0.3/` is bundled as an Android asset directory by reference; its database bytes are not duplicated in a second source tree.

At runtime:

1. copy `content.sqlite` into the app-private versioned pack directory only when needed;
2. verify the exact expected byte size and SHA-256 before activation;
3. atomically rename the verified candidate inside the same directory;
4. mark the installed file read-only;
5. open SQLite with `OPEN_READONLY`;
6. verify pack ID, content version, source SHA-256 and Quran coordinate count from `pack_metadata`;
7. query only `quran_ayah.original_text` for display.

Search-normalized fields never feed the reading surface.

## UI contract

The visible reader stays intentionally small:

- previous / next Surah;
- obvious Surah chooser;
- source-information action;
- exact Arabic ayah text with coordinates shown separately.

Arabic is rendered RTL with scalable `sp` text. Material controls provide standard semantics and touch behavior. The reader performs database installation/verification and reads off the UI thread.

No guessed Surah-name table, whitespace-derived token identity, morphology, translation or AI output is inserted into the evidence reading surface.

## Network boundary

The Phase 1 app manifest declares neither `INTERNET` nor `ACCESS_NETWORK_STATE`. Core reading therefore cannot silently depend on a server. The source-information screen may hand an explicit Tanzil link to the user's external browser; the app itself does not fetch it.

Later audio, signed pack updates or external-AI flows must be separate explicit capabilities rather than hidden reader dependencies.

## Replaceability

Jetpack Compose is an implementation choice, not a permanent data contract. The durable boundary is the verified content-pack contract plus repository methods that expose source-faithful records. A future UI toolkit can replace Compose without changing canonical IDs, source artifacts or user history.

## Validation

CI checks that:

- the Android pack contract matches the checked-in `quran-core` manifest;
- the app references the existing pack instead of duplicating source bytes;
- the manifest has no direct network permissions;
- the reader opens SQLite read-only and selects `original_text`, never search-normalized display data;
- Source Vault and content-pack gates still pass;
- Android unit tests compile and a debug APK assembles.

Device-level TalkBack, large-font, RTL, low-end performance and scroll-smoothness testing remain release gates and are not claimed by repository compilation alone.
