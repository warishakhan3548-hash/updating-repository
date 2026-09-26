# PR Progress

## Scope
Second-pass production audit after merged PR #338, focused on high-confidence resilience, lifecycle, sharing, release verification, and supply-chain integrity without broad rewrites.

## Bugs / risks found
- Hadith database can be fully verified and then rejected solely because the tiny verification-marker write fails; the marker is an optimization, not evidence.
- Translation TTS owns the Activity context instead of the application context, increasing lifecycle/leak risk around slow TTS initialization and rotation.
- Research PDF provider authority was hard-coded in the manifest while runtime derives it from the application package; future build variants/applicationId changes could break URI sharing.
- Ambient overlay startup assumed the default display lookup is always non-null on API 30+, creating an avoidable service crash edge case.
- CI verified debug packaging/lint but did not exercise the release variant.
- Gradle distribution and checked-in wrapper JAR integrity were not explicitly guarded.
- CI root build/wrapper path coverage was incomplete and workflow actions used movable major tags.
- Push and pull-request events could duplicate the same expensive verification for one branch checkpoint.
- The non-Gradle signed release builder bypasses Gradle manifest merging, so the new `${applicationId}` ResearchFiles authority was not expanded on that release path.
- The HadeethEnc source-capture workflow still used movable `actions/checkout@v4`, leaving one workflow outside the immutable action-pinning policy.

## Fixed
- Hadith/audio marker resilience, TTS application-context ownership, variant-safe sharing, display lookup guarding, release CI, CI deduplication, and Gradle/wrapper integrity guards are implemented on this PR branch.
- The manual SDK release builder now expands `${applicationId}` itself and rejects any unsupported remaining manifest placeholder instead of packaging it literally.
- The HadeethEnc capture workflow now pins checkout to the reviewed immutable v4 revision; `tools/check.py` guards both this pin and the manual release manifest invariant.

## Pending
- Current-head CI run 36214995672 is still running on code head 736dda3df5ada6cc150bafd0af1ddd18918440e5.
- If it passes, re-check final mergeability/behind count and record the final verification checkpoint.
- If it fails, resolve the failing step at root cause on this same PR branch.

## Tests / CI
- Base main: 5f3eb0d5438351f8b6e048d1d57b4420bdd49aea (merged PR #338).
- Earlier branch CI run 36214283428 passed deterministic evidence rebuild, offline integrity/search regressions, Android debug/release assemble, and debug/release lint.
- Current verification run: 36214995672 — in progress.
- Before this progress-only commit the branch was 0 commits behind main and PR #339 was mergeable.

## Next exact step
Inspect workflow run 36214995672. If green, verify PR #339 is still 0 behind main and mergeable, update this file with the final PASS, and leave PR #339 ready for review/merge.
