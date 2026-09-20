# Research Record — Durable Learning Ledger and FSRS Boundary — 2026-09-20

Purpose: strengthen the existing local Learning Plane before wiring word taps to a verified lexical/gloss source. This change does not add Quran, Hadith, morphology, translation, audio, or AI evidence.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | FSRS-6 models memory with Stability and Difficulty while retrievability changes with elapsed time; the standard review grades are Again, Hard, Good and Easy. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-Algorithm | 2026-09-20 | High | Preserve the user's review grade and timestamp as durable history; do not make computed memory state the only truth. |
| fact | The FSRS optimization workflow learns from time-series review logs. | https://github.com/open-spaced-repetition/awesome-fsrs/wiki/The-mechanism-of-optimization | 2026-09-20 | High | Review history must survive scheduler upgrades so parameters/state can be recomputed. |
| fact | Current reference implementations update card memory state from review history and rating, then derive the next interval. | https://github.com/open-spaced-repetition/py-fsrs/blob/main/fsrs/scheduler.py | 2026-09-20 | High | memory_state_cache remains a replaceable projection; event rows remain the durable substrate. |
| inference | Scheduler-neutral product history should record canonical review grade, adapter/version used at the time, context reference and event-schema version, while keeping adapter state outside canonical history. | Repository architecture + sources above | 2026-09-20 | High | Add user schema v2 without serializing FSRS equations or parameters into permanent event identity. |
| inference | Legacy unconstrained outcomes must not be silently reinterpreted. | Data-migration safety principle | 2026-09-20 | High | Migrate only exact Again/Hard/Good/Easy strings to canonical_grade; preserve unknown legacy outcomes verbatim with a null canonical grade. |

## Decision

Keep user.sqlite as the sole owner of personal learning history and add a versioned v2 contract:

- PRAGMA user_version = 2;
- append-only exposure and review events remain authoritative history;
- every new v2 review records one canonical grade: again, hard, good, or easy;
- every new v2 review records the scheduler adapter version used at the time;
- review events may record a context_ref so future context rotation can distinguish Quran/Hadith/review contexts without coupling history to a particular content-pack layout;
- event rows carry event_schema_version;
- memory_state_cache remains rebuildable and may be discarded/recomputed when the scheduler changes.

The v1→v2 migration is deliberately conservative. Exact canonical grade strings are mapped. Any other historical outcome remains preserved but receives no guessed canonical grade.

## Non-goals

- no FSRS parameter tuning;
- no retention benchmark claim;
- no automatic review scheduling in the Android UI yet;
- no rare-word prioritization score yet;
- no word identity inferred from Quran whitespace;
- no new evidence source;
- no cloud sync or account dependency.

This makes the learning substrate ready for a future verified gloss/morphology tap without forcing the UI to expose learning machinery.
