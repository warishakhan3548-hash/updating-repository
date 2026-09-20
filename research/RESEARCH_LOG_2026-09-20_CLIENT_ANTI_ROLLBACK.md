# Research Record — Client Content-Pack Anti-Rollback — 2026-09-20

This record captures the narrow research that materially affected the Android client acceptance design. It does not change evidence-source licensing or promote any content dataset.

| Claim | Primary source | Verified | Confidence | Product implication |
|---|---|---:|---|---|
| A secure updater needs rollback memory: previously seen trusted metadata/content must not be silently replaced by an older validly signed version. | The Update Framework, Security: https://theupdateframework.io/docs/security/ | 2026-09-20 | High | Persist the highest accepted signed release sequence locally and reject lower values. |
| TUF separates rollback/freeze protection from ordinary signature validity and uses version/freshness metadata as independent protections. | The Update Framework specification/docs: https://theupdateframework.github.io/specification/latest/ and https://theupdateframework.io/docs/metadata/ | 2026-09-20 | High | Do not claim that signed release_sequence alone is a complete update protocol; freshness and recovery remain future work. |
| Android AtomicFile provides a fail-safe file-replacement primitive but does not provide locking semantics for callers. | Android SDK reference, android.util.AtomicFile: https://developer.android.com/reference/android/util/AtomicFile | 2026-09-20 | High | Persist acceptance state atomically and serialize access in-process. |
| Context.noBackupFilesDir is excluded from automatic backup. | Android SDK reference, Context.getNoBackupFilesDir(): https://developer.android.com/reference/android/content/Context#getNoBackupFilesDir() | 2026-09-20 | High | Keep rollback-security state separate from portable user learning data so restoring an old user backup cannot lower accepted pack state. |

## Architectural inference

The repository already authenticates approved pack manifests at build time with project-controlled Ed25519 trust policy and a signed monotonic `release_sequence`. The missing client property is memory of what has already been accepted. Therefore the smallest safe next layer is an app-local acceptance store, not a second signature verifier and not a network updater.

For equal release sequences, accepting different manifest or content hashes would make one monotonic sequence identify multiple release states. The client therefore treats that condition as equivocation/conflict and fails closed.

## Explicitly not concluded

- Atomic local state does not protect a rooted or fully compromised device.
- Uninstall/clear-data removes app-local acceptance history.
- This change does not provide freshness/expiry checks.
- This change does not make remote updates safe by itself.
- It does not alter or validate Quran/Hadith evidence bytes.
