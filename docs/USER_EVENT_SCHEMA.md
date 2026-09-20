# User Event Schema

`schemas/user_v1.sql` keeps personal history separate from replaceable content.

Durable learning truth is append-only:
- exposure events: passive visible, quick meaning opened, deep morphology opened, explicitly unknown/known, audio heard;
- review events: scheduler outcome, timestamp and context.

Passive visibility is not recall success.

`memory_state_cache` is rebuildable. Changing FSRS versions or replacing the scheduler must not destroy review/exposure history.

Bookmarks, notes and preferences live in the user database and belong in versioned export/import.
