# PR Progress

## Scope
Second-pass production audit after merged PR #338, focused on high-confidence resilience, lifecycle, sharing, release verification, recitation/audio reliability, and supply-chain integrity without broad rewrites.

## Bugs / risks found
- Hadith database could be fully verified and then rejected solely because the tiny verification-marker write failed; the marker is an optimization, not evidence.
- Translation TTS owned the Activity context instead of the application context, increasing lifecycle/leak risk around slow TTS initialization and rotation.
- Research PDF provider authority was hard-coded in the manifest while runtime derives it from the application package; future build variants/applicationId changes could break URI sharing.
- Ambient overlay startup assumed the default display lookup is always non-null on API 30+, creating an avoidable service crash edge case.
- CI verified debug packaging/lint but did not exercise the release variant.
- Gradle distribution and checked-in wrapper JAR integrity were not explicitly guarded.
- CI root build/wrapper path coverage was incomplete and workflow actions used movable major tags.
- Push and pull-request events could duplicate the same expensive verification for one branch checkpoint.
- The non-Gradle signed release builder bypasses Gradle manifest merging, so the new `${applicationId}` ResearchFiles authority was not expanded on that release path.
- The HadeethEnc source-capture workflow still used movable `actions/checkout@v4`, leaving one workflow outside the immutable action-pinning policy.
- Recitation service did not pause when a private audio route became noisy/disconnected.
- Whole-ayah recitation downloads could leave stale temporary bytes, had weak low-storage preflight behavior, and needed redirect handling that remains HTTPS-only.
- The existing offline-contract regression guard still required redirects to be disabled, contradicting the newly hardened HTTPS redirect behavior and causing CI run 36216281282 to fail.
- Interrupted word-audio replacement could delete the rollback `.old` pack merely because a new target file existed, without first re-verifying that target after a crash.
- Imported learning history could contain an implausibly far-future event timestamp; because new local events seed from the ledger max timestamp, one bad backup could pin future learning events to that poisoned clock.
- Learning backup export did not explicitly order event rows by ledger sequence, leaving equal-time replay fallback dependent on SQLite's incidental row order.
- A warm global Recall projection was discarded after every new learning event, forcing the next full Yaad/recall overview to replay the complete history instead of refreshing only the changed target.
- Ambient overlay recovery treated the plain Service context as a safe API 30+ fallback when the default display was transiently missing, but Android requires a display-associated window context for application overlays.

## Fixed
- Hadith/audio marker resilience, TTS application-context ownership, variant-safe sharing, display lookup guarding, release CI, CI deduplication, and Gradle/wrapper integrity guards are implemented on this PR branch.
- The manual SDK release builder now expands `${applicationId}` itself and rejects any unsupported remaining manifest placeholder instead of packaging it literally.
- The HadeethEnc capture workflow now pins checkout to the reviewed immutable v4 revision; `tools/check.py` guards both this pin and the manual release manifest invariant.
- Recitation now pauses on `ACTION_AUDIO_BECOMING_NOISY` and unregisters its private receiver with the Service lifecycle.
- Whole-ayah recitation download staging clears abandoned temp files, enforces size/storage headroom, follows normal HTTPS redirects, and rejects transport downgrade.
- `tools/check_offline_contract.py` now enforces the current HTTPS redirect boundary instead of the obsolete no-redirect behavior.
- Word-audio crash recovery now validates a newly installed target before deleting the previous rollback pack; if the target is invalid it restores the rollback copy instead of silently discarding it.
- `tools/check.py` now guards that fail-safe recovery invariant.
- Learning event creation now bounds recovery from an implausibly future persisted clock; backup validation rejects far-future learning events, and exported event rows are explicitly serialized in ledger sequence order.
- Once the global Recall projection is warm, appending a learning event now recomputes only that target's projection and preserves the rest of the cache instead of invalidating the entire history.
- Ambient recall now lazily retries until a valid display-associated overlay context is available; a transient display gap no longer consumes the recall interval or falls back to a non-visual Service context on API 30+.

## Pending
- GitHub Actions verification for checkpoint 263ea4b423fb528304152106d81b84345ef2b354 is pending.
- If CI exposes another real regression, fix it at the root and re-run verification.
- After a clean full run, record the verified SHA here and review/merge PR #339.

## Tests / CI
- Base main at verification: 5f3eb0d5438351f8b6e048d1d57b4420bdd49aea (merged PR #338).
- Earlier full verification run 36215140358 passed on head faafccacb1a65ede2f53f4209e29ddad5a2f064f.
- CI run 36216281282 failed in `tools/check_offline_contract.py` because the static contract still required `setInstanceFollowRedirects(false)` after the implementation intentionally switched to HTTPS-only redirect following. This guard has been corrected.
- Current verification run 36217482473 is pending for checkpoint 263ea4b423fb528304152106d81b84345ef2b354.
- Local container clone could not run because this execution environment has no GitHub DNS/network access; authoritative verification is therefore GitHub Actions.

## Next exact step
Wait for GitHub Actions run 36217482473 to complete. If it fails, inspect the failing job/log and fix the first genuine regression. If it passes, update this file with the verified SHA/run and leave PR #339 ready for review/merge.
