# Research Record — Local User Data Portability v1 — 2026-09-21

Purpose: close the durability gap between append-only learning history and real phone/reinstall portability without introducing an account, cloud dependency, or second evidence store.

| Type | Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---|---:|---|---|
| fact | SQLite's Online Backup API creates a consistent snapshot of a live database and avoids holding the source locked for the full copy. | https://sqlite.org/backup.html | 2026-09-21 | High | Export user.sqlite through SQLite backup semantics instead of raw file copy. |
| fact | SQLite integrity_check performs low-level format/consistency checks; quick_check is faster but skips some checks. | https://sqlite.org/pragma.html | 2026-09-21 | High | Portability is infrequent and precious, so validate imported/exported snapshots with integrity_check before acceptance. |
| fact | SQLite's security guidance recommends checking database integrity before processing potentially hostile database files and suggests trusted_schema OFF, cell-size checking and mmap disabled as extra defenses. | https://sqlite.org/security.html | 2026-09-21 | High | Treat imported backups as untrusted input before querying application tables. |
| fact | SQLite documents that persistent schema contains tables, indexes, views and triggers, and its security guidance warns that hostile schema changes can route later application work through attacker-controlled views, triggers, constraints or expression indexes. | https://sqlite.org/schematab.html and https://sqlite.org/security.html | 2026-09-21 | High | A valid hash and table-name checklist are insufficient; restore must bind the database to the exact application schema contract for its version. |
| fact | Android ACTION_CREATE_DOCUMENT and ACTION_OPEN_DOCUMENT use the system document-provider UI for creating/selecting user-chosen files. | https://developer.android.com/reference/android/content/Intent#ACTION_CREATE_DOCUMENT | 2026-09-21 | High | Future Android backup UI can use the system picker rather than broad storage permissions. |
| fact | Android Storage Access Framework explicitly supports create-file and open-document flows over user-selected locations/providers. | https://developer.android.com/training/data-storage/shared/documents-files | 2026-09-21 | High | Keep backup/restore explicit and user-controlled; no mandatory cloud account. |
| finding | The historical `schemas/user_v1.sql` fixture does not set `PRAGMA user_version=1`; SQLite therefore reports the default `0` until the v1→v2 migration sets version 2. | Repository schema audit | 2026-09-21 | High | Backup format v1 accepts schema v2 only. Legacy databases migrate first; the backup layer must not invent a fictional version-1 marker. |
| inference | A versioned envelope containing only manifest.json + user.sqlite is sufficient for the first portable backup contract because the SQLite schema already versions/migrates durable learning history. | Repository schemas + sources above | 2026-09-21 | High | Do not duplicate learning rows into a second JSON history format. |
| inference | content.sqlite and evidence packs should be excluded because they are replaceable, separately versioned, and source/licence governed. | Repository architecture | 2026-09-21 | High | Backup only precious user state and reinstall compatible content packs independently. |
| hypothesis | Optional encrypted backup should be a later envelope/version after an Android threat-model and key-management review. | First-principles security review | 2026-09-21 | Medium | Do not rush custom cryptography into v1; visibly warn that manual backups are not encrypted. |

## Decision

Introduce `aaris-user-backup` format version 1 and a dependency-free Python reference implementation.

The archive is intentionally tiny in shape: exactly `manifest.json` and one self-contained `user.sqlite` snapshot. The manifest binds the database by SHA-256, byte size and `PRAGMA user_version` without duplicating private user content.

Export uses SQLite's backup API. Backup format v1 accepts only user schema v2; a legacy pre-v2 database must run the existing tested migration first. Import validates archive structure, hash, database integrity, supported schema version and the complete canonical persistent application schema before a destination is published. The contract is derived from the repository's versioned `schemas/user_v2.sql`; SQLite-owned internal `sqlite_*` objects are excluded, while application-defined tables, explicit indexes, views and triggers must match exactly. Restore refuses to overwrite an existing database so Android integration cannot accidentally become an uncontrolled live-database replacement path.

## Rejected alternatives

- **Raw filesystem copy of a live user.sqlite** — unsafe as the portable contract because journaling/WAL state may be relevant and SQLite already provides snapshot semantics.
- **JSON export of every table** — creates a second permanent schema/migration surface and can silently lose SQLite constraints or new fields.
- **Backing up content.sqlite with user.sqlite** — mixes replaceable/licensed evidence with precious personal state.
- **Mandatory Google Drive/account sync now** — violates local-first/privacy goals and is unnecessary for basic portability.
- **Custom encryption in v1** — key management and recovery need a separate threat-model; home-grown crypto would add risk rather than trust.

## Non-claim

This does not yet expose Android UI buttons. It establishes and tests the portable on-disk contract first so the later UI can remain a simple Export / Restore flow.
