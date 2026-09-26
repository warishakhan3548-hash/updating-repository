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
- Word-audio Download All inspected installed packs before entering its failure/finally boundary; an unexpected storage/runtime failure there could leave the global downloader permanently busy.
- Isolated word/word-sequence playback did not pause when headphones or another private audio route disconnected, so pronunciation could unexpectedly continue on the speaker.
- A batch word-audio preflight failure before a concrete Surah was selected could surface a fabricated `Surah 0` error label.
- The reader's tappable Tanzil source label used a small text hit target without the explicit focus/accessibility affordance used by the rest of the interactive UI.

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
- Word-audio Download All now enters its guarded recovery path before installed-pack inspection, always releases `busy`, and publishes a terminal error instead of wedging the operation UI.
- Isolated word/ayah-fallback playback now owns a private `ACTION_AUDIO_BECOMING_NOISY` receiver only while playback is active and stops safely on route loss.
- Batch preflight errors now use a generic download failure message until a real Surah coordinate exists.
- The existing reader source action now has a 48dp minimum touch target, focusability, tooltip, motion consistency, and a descriptive accessibility label without adding another control.
- `tools/check.py` now guards these word-audio resilience and reader-accessibility invariants.

## Pending
- GitHub Actions verification run 36217882392 is running for code checkpoint ef570e3d8b40f4de8e4b974528a4266d8fef981c.
- If CI exposes another real regression, fix it at the root and re-run verification.
- After a clean full run, record the verified SHA/run here and leave PR #339 ready for review/merge.

## Tests / CI
- Base main at verification: 5f3eb0d5438351f8b6e048d1d57b4420bdd49aea (merged PR #338).
- Earlier full verification run 36215140358 passed on head faafccacb1a65ede2f53f4209e29ddad5a2f064f.
- CI run 36216281282 failed in `tools/check_offline_contract.py` because the static contract still required `setInstanceFollowRedirects(false)` after the implementation intentionally switched to HTTPS-only redirect following. This guard has been corrected.
- Current verification run 36217882392 is in progress for code checkpoint ef570e3d8b40f4de8e4b974528a4266d8fef981c.
- Local container clone could not run because this execution environment has no GitHub DNS/network access; authoritative verification is therefore GitHub Actions.

## Next exact step
Inspect GitHub Actions run 36217882392. If it fails, open the failing job/log and fix the first genuine regression. If it passes, update this file with the verified SHA/run and leave PR #339 ready for review/merge.
