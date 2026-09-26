# PR Progress

## Scope
Second-pass production audit after merged PR #338, focused on high-confidence resilience, lifecycle, sharing, and release-verification gaps without broad rewrites.

## Bugs / risks found
- Hadith database can be fully verified and then rejected solely because the tiny verification-marker write fails; the marker is an optimization, not evidence.
- Translation TTS owns the Activity context instead of the application context, increasing lifecycle/leak risk around slow TTS initialization and rotation.
- Research PDF provider authority is hard-coded in the manifest while runtime derives it from the application package; future build variants/applicationId changes can break URI sharing.
- Ambient overlay startup assumes the default display lookup is always non-null on API 30+, creating an avoidable service crash edge case.
- CI verifies debug packaging/lint but does not exercise the release variant.
- Gradle distribution and checked-in wrapper JAR integrity were not explicitly guarded.
- CI root build/wrapper path coverage was incomplete and workflow actions used movable major tags.
- Push and pull-request events could duplicate the same expensive verification for one branch checkpoint.

## Fixed
- Hadith/audio marker resilience, TTS context ownership, variant-safe sharing, display lookup guarding, release CI, CI deduplication, and build-integrity guards are implemented on this PR branch.

## Pending
- No product-code fix remains in this PR. Final handoff is review/merge after the metadata-only checkpoint is verified.

## Tests / CI
- Base main: latest commit 5f3eb0d merged PR #338.
- Main Actions visible: GitHub Pages succeeded; app verification workflow is PR/audit-branch scoped and will run on this branch.
- Branch CI: run 36213778969 passed deterministic evidence rebuild, offline integrity/search regressions, Android debug/release assemble, and debug/release lint on code head 25322bdcf90f20149930e98617dc69da367a8960.

## Next exact step
Verify this metadata-only checkpoint, confirm the branch is still mergeable and not behind main, then mark PR #339 ready for review.
