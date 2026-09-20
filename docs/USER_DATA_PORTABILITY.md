# User Data Portability

The user's learning history is precious state. It must remain portable independently of replaceable Quran/Hadith content packs and independently of any account or cloud service.

## Backup format v1

A backup is a ZIP-compatible file whose logical format is `aaris-user-backup` version `1`. The filename extension is a UI choice; the format does not depend on an extension.

The archive contains exactly two files:

- `manifest.json`
- `user.sqlite`

No other entry is accepted.

The manifest contains only structural metadata:

- backup format and format version;
- creation timestamp;
- database entry name;
- exact database byte size;
- SHA-256 of the exported `user.sqlite`;
- SQLite `PRAGMA user_version`.

It deliberately contains no note text, review history, identifiers or other user content outside the database itself.

## Export contract

`tools/user_backup.py export` creates the database snapshot with SQLite's online backup mechanism rather than copying the live database file directly. This is important when the application database may be active or using a journal/WAL.

Backup format v1 currently accepts only `user.sqlite` schema v2. The historical `schemas/user_v1.sql` fixture did not assign a stable `PRAGMA user_version=1` (it remains SQLite default `0`), so legacy databases must first pass the existing tested v1→v2 application migration rather than being guessed into a backup schema.

The exported snapshot is validated before publication:

1. SQLite opens read-only.
2. defensive pragmas are applied for inspection;
3. `PRAGMA integrity_check` must return `ok`;
4. `PRAGMA user_version` must be a supported version;
5. the complete persistent application schema must match the canonical repository schema for that `user_version`, including tables, explicit indexes and triggers;
6. no unexpected persistent schema object may be present, including SQLite-named objects not created by the canonical schema;
7. the database is hashed;
8. the final archive is reopened and fully validated;
9. only then is it moved into the requested output path.

The exporter refuses to overwrite an existing backup.

## Import/restore contract

`inspect` and `restore` treat backup files as untrusted input.

Validation fails closed when:

- the ZIP is malformed;
- entries are missing, duplicated, unexpected, directories or symlinks;
- the manifest shape/version is unknown;
- size metadata does not match;
- the SHA-256 does not match;
- SQLite integrity fails;
- `user_version` is unsupported or disagrees with the manifest;
- the persistent application schema differs from the canonical schema for that version, including an added/removed/modified table, explicit index, view or trigger.

The schema comparison includes SQLite-created persistent schema rows such as canonical auto-index entries rather than trusting an `sqlite_*` name prefix. This keeps the rule simple and fail-closed: the backed-up database must have the same persistent schema objects as a clean database built from the versioned canonical schema. Derived planner statistics are not part of the current user-v2 contract; if the app intentionally introduces them later, that must be versioned and tested rather than silently accepted. This prevents a correctly re-hashed archive from smuggling altered triggers or views into the database that the app later opens normally.

The reference restore path writes only to a **new** destination database. It refuses to overwrite an existing SQLite database or publish next to leftover `-wal`, `-shm` or `-journal` sidecars.

The Android application must perform its eventual restore while its user database is closed, validate into a temporary app-private file, then publish through one coordinated database-lifecycle owner. Do not replace an open Room/SQLite database underneath live connections.

Backup restore must not invent a parallel migration system. When a future schema version is added, support for restoring that version must be explicit and regression-tested; older pre-v2 databases migrate through the existing application migration before export.

## Scope

Included:

- exposure events;
- review events;
- rebuildable memory-state cache;
- bookmarks;
- notes;
- preferences.

Excluded:

- `content.sqlite`;
- Source Vault artifacts;
- Quran/Hadith evidence packs;
- search indexes that can be rebuilt from content;
- external-AI data.

This separation prevents user backup from becoming a second evidence-distribution channel and keeps replaceable data out of precious-state archives.

## Android UX

The intended visible flow stays small:

**Settings → Backup & restore → Export backup / Restore backup**

Android's Storage Access Framework can use `ACTION_CREATE_DOCUMENT` for export and `ACTION_OPEN_DOCUMENT` for restore. The system picker lets the user choose the file location/provider without granting broad storage access.

The app should explain one important privacy fact near export: the v1 archive is not encrypted. It may contain notes and learning history, so the user should store it somewhere they trust.

## Non-goals of v1

- no cloud account;
- no automatic upload;
- no hidden analytics;
- no password/encryption envelope yet;
- no merge of two independently modified user databases;
- no backup of replaceable content packs;
- no direct overwrite of a live Android database.

Encrypted backup/sync can be added later as a new envelope/version without invalidating the durable SQLite history underneath.

## Reference implementation

```bash
python tools/user_backup.py export /path/to/user.sqlite /path/to/aaris-backup.zip
python tools/user_backup.py inspect /path/to/aaris-backup.zip
python tools/user_backup.py restore /path/to/aaris-backup.zip /new/path/user.sqlite
```

Regression coverage is in `tests/test_user_backup.py`.
