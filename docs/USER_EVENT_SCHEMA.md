# User Event Schema

`user.sqlite` is precious personal state and remains separate from replaceable content packs.

## Current schema

Fresh databases use `schemas/user_v2.sql`. Existing v1 databases upgrade with `schemas/migrations/user_v1_to_v2.sql`. SQLite `PRAGMA user_version` is `2` after either path.

Durable learning truth is append-only:

- exposure events: passive visible, quick meaning opened, deep morphology opened, explicitly unknown/known, audio heard;
- review events: user review outcome, canonical grade, timestamp, scheduler adapter/version and optional context reference.

Passive visibility is not recall success.

Every new v2 review must record exactly one canonical grade: `again`, `hard`, `good`, or `easy`. The raw `outcome` is retained for migration/audit compatibility and must match the canonical grade for new v2 rows.

`scheduler_adapter` and `scheduler_version` describe what scheduled the review; they do not own the permanent memory model. `memory_state_cache` remains rebuildable. Changing FSRS versions or replacing the scheduler must not destroy review/exposure history.

`context_ref` lets future context rotation record which Quran/Hadith/review context was used without coupling the event ledger to a specific runtime pack layout.

`event_schema_version` distinguishes migrated historical rows from new rows. The v1→v2 migration preserves unknown legacy outcomes verbatim and deliberately leaves their canonical grade unset rather than guessing.

Bookmarks, notes and preferences live in the user database and belong in versioned export/import.

Regression coverage lives in `tests/test_user_migrations.py`; `tools/validate_schemas.py` compiles both v1 and v2 so future migrations cannot silently orphan the current contract.


## Derived rare-word rescue policy

`RareWordRescuePolicy` is a derived Learning Plane policy over existing evidence; it does not introduce another source of user truth or require a schema migration.

Its inputs may include:

- an already-existing app-owned `semantic_unit_id`;
- preserved exposure/review evidence since the last successful retrieval;
- a replaceable scheduler projection such as review-due state, optional retrievability, and explicit authorization to defer a due review to a predicted natural encounter;
- a future verified prediction of suitable natural encounters in the user's reading path.

A natural encounter may substitute for an interruptive due-review opportunity only when the scheduler projection explicitly authorizes that deferral, and it is **not** written as successful recall. Passive visibility remains an exposure event. If the user needs meaning help again, that becomes additional struggle evidence; only an explicit review outcome carries canonical Again/Hard/Good/Easy retrieval evidence.

This policy remains dormant for Quran word-level learning while the current Quran pack has no provenance-backed canonical word identities.
