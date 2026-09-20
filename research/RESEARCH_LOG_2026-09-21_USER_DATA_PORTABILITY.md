# Research Log — User Data Portability — 2026-09-21

| Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---:|---|---|
| SQLite exposes application-owned \`PRAGMA user_version\`, a full \`integrity_check\`, and \`foreign_key_check\`. | https://www.sqlite.org/pragma.html | 2026-09-21 | high | Bind backups to an explicit user-schema version and validate SQLite structure before export/restore. |
| SQLite transactions provide atomic commit semantics; interrupted transactions do not become partially committed logical state. | https://www.sqlite.org/lang_transaction.html ; https://www.sqlite.org/atomiccommit.html | 2026-09-21 | high | Keep durable user state in SQLite rather than creating a second mutable persistence model solely for backup. |
| Android Storage Access Framework lets the user explicitly choose files/locations through the system picker without broad storage permissions; documents can remain outside app-private storage after uninstall. | https://developer.android.com/training/data-storage/shared/documents-files | 2026-09-21 | high | Future Android export/import should use \`ACTION_CREATE_DOCUMENT\` / \`ACTION_OPEN_DOCUMENT\`, not a custom broad-storage permission flow. |

## Architectural inference

A portable SQLite snapshot plus a small versioned manifest is safer than serializing every current table into an unrelated bespoke object model. It preserves schema constraints, append-only historical rows and future migration leverage while keeping the backup format library-independent.

\`memory_state_cache\` is explicitly excluded because ADR-003/ADR-018 define scheduler state as a projection of durable history. Restoring stale cache state would make a replaceable scheduler implementation part of the permanent backup contract.

The manifest SHA-256 is an accidental-corruption check, not an authenticity primitive. Backup v1 therefore declares itself plaintext and unauthenticated. Encryption/authentication should be a deliberate later envelope with reviewed key management, not a misleading local password feature.

## Experimental hypothesis

Before Android UI wiring, the host reference implementation must prove:

- durable rows round-trip;
- migrated legacy review events keep their original semantics;
- derived scheduler cache does not round-trip;
- database/member tampering fails closed;
- unexpected archive members fail closed;
- future/unknown schema versions fail closed;
- restore never overwrites an existing database implicitly.

If those invariants hold in CI, the format can become the contract used by a later minimal Android picker flow.
