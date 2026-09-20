# User Data Portability

## Goal

Years of learning history must survive phone replacement, reinstall and future scheduler changes without requiring an account or cloud service.

The first portable format is intentionally boring:

\`\`\`
Aaris user backup v1 (.aaris-backup ZIP)
├── manifest.json
└── user.sqlite
\`\`\`

The SQLite payload preserves the current user schema and durable rows exactly. The manifest binds that payload to an explicit backup-format version, user-schema version, byte size, SHA-256 and per-table row counts.

## What is durable

Backup v1 preserves:

- \`exposure_event\`
- \`review_event\`
- \`bookmark\`
- \`note\`
- \`preference\`

It deliberately excludes \`memory_state_cache\`.

The cache is a scheduler projection and must be rebuildable from durable history. Shipping it as precious user history would couple portability to one scheduler implementation and could make stale derived state look authoritative.

## Safety contract

\`tools/user_backup.py\` is the reference implementation for backup format v1.

Export:

1. opens the source database read-only;
2. requires the supported user schema version;
3. runs SQLite \`integrity_check\` and \`foreign_key_check\`;
4. takes a consistent SQLite backup copy;
5. clears rebuildable cache state from the copy;
6. runs \`VACUUM\` so the portable copy does not intentionally carry deleted cache pages;
7. validates the portable SQLite copy again;
8. records SHA-256, byte size and durable-table row counts in canonical \`manifest.json\`;
9. writes exactly two bounded archive members without overwriting an existing backup.

Inspection/restore:

1. accepts exactly \`manifest.json\` and \`user.sqlite\`;
2. rejects unsupported format or user-schema versions;
3. enforces archive size bounds before trusting content;
4. verifies canonical manifest encoding, byte size and SHA-256;
5. reruns SQLite structural checks and row-count checks;
6. requires derived cache tables to be empty;
7. refuses to overwrite an existing destination database;
8. writes the validated replacement in the destination directory and activates it with an atomic filesystem replace.

A failed validation never becomes an active user database.

## Privacy and threat model

Backup v1 is **plaintext and unauthenticated**.

Its SHA-256 detects accidental corruption of the SQLite payload relative to its manifest. It does **not** prove who created the backup, and it does not protect the file from a person who can deliberately modify both payload and manifest.

The backup may contain private notes, reading/learning history and preferences. The future Android UI must say that clearly before export. Encryption can be added as a new compatible envelope/version when a reviewed key-management design exists; it is not silently improvised in v1.

## Android UX boundary

The reference format is independent of Android UI. When user-state persistence is wired into the app, export/import should use the Android Storage Access Framework:

- \`ACTION_CREATE_DOCUMENT\` for an explicit user-chosen backup destination;
- \`ACTION_OPEN_DOCUMENT\` for an explicit user-chosen restore file.

This keeps storage access user-controlled and avoids requiring broad storage permissions.

The app must close/quiesce its user database before final restore activation. Restore should remain a deliberate user action with a clear warning if existing local user state would be replaced. The host reference implementation intentionally refuses overwrite rather than guessing a merge policy.

## Compatibility

Backup format version and SQLite user-schema version are separate.

Backup v1 currently accepts user schema v2 only. Unknown/future schema versions fail closed instead of being guessed. Historical v1 learning rows that were conservatively migrated into user schema v2 remain byte-for-byte semantic history inside that v2 database and round-trip without being reinterpreted.

Future user-schema migrations should preserve the ability to restore older supported backup-format versions through explicit, tested migration paths.

## Reference commands

\`\`\`bash
python tools/user_backup.py export user.sqlite my-history.aaris-backup
python tools/user_backup.py inspect my-history.aaris-backup
python tools/user_backup.py restore my-history.aaris-backup restored-user.sqlite
\`\`\`

These commands are engineering/reference tooling. The first-time-user product experience should eventually expose only simple **Export backup** and **Restore backup** actions.

## Primary-source basis

Verified 2026-09-21:

- SQLite \`PRAGMA integrity_check\`, \`foreign_key_check\` and application-owned \`user_version\`: https://www.sqlite.org/pragma.html
- SQLite transaction/atomic-commit model: https://www.sqlite.org/lang_transaction.html and https://www.sqlite.org/atomiccommit.html
- Android Storage Access Framework user-controlled document creation/opening: https://developer.android.com/training/data-storage/shared/documents-files
