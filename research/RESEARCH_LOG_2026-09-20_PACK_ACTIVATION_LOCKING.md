# Research Record — Pack Activation Serialization — 2026-09-20

This record captures the narrow primary-source research that materially changed the already-existing Android rollback implementation. It does not promote or modify any Quran, morphology, Hadith, translation, font, audio, or timing source.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | Android `AtomicFile` guarantees complete/synced replacement semantics but explicitly provides no file locking; callers must enforce mutual exclusion whenever the file can be accessed concurrently. | https://developer.android.com/reference/android/util/AtomicFile | 2026-09-20 | High | Do not treat atomic replacement as concurrency control. Serialize access to the rollback-state file and verified pack activation. |
| fact | TUF identifies rollback, mix-and-match, and stale-view attacks as distinct updater risks and states that freshness requires never accepting files older than those already seen. | https://theupdateframework.io/docs/security/ | 2026-09-20 | High | Keep the existing monotonic release sequence and make its local check/activation/state-advance path one serialized transaction. |
| fact | Android `noBackupFilesDir` is excluded from automatic backup. | https://developer.android.com/reference/android/content/Context#getNoBackupFilesDir() | 2026-09-20 | High | Keep rollback-security state out of portable user-history backup/restore. |

## Repository finding

Main commit `0c011d9dce2e517573e08c598e50324a91e6c941` already implemented the correct single-owner rollback subsystem: bounded signed sequence parsing, a persisted highest-sequence/pack-hash record, preflight rejection, and crash-safe `AtomicFile` replacement of verified Quran-pack bytes.

The remaining gap was concurrency, not missing architecture. `AtomicFile` itself does not lock, and future repository/updater instances could otherwise interleave the sequence:

`read accepted state → validate candidate → activate bytes → advance accepted state`.

## Decision

Retain the existing rollback system and add one process-wide lock shared by:

- the complete release activation transaction in `PackagedQuranRepository`;
- direct `PackActivationStateStore.requireAcceptable` calls;
- direct `PackActivationStateStore.accept` calls.

Java/Kotlin monitor synchronization is re-entrant, so the store can defend itself while the higher-level transaction holds the same lock.

## Non-goals

- no second rollback-state format or database;
- no network updater;
- no new cryptography;
- no change to content-pack signatures;
- no change to evidence bytes;
- no claim of cross-process or hardware-backed monotonic storage.
