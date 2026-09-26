# PR Progress

## Scope
Second-pass production audit after merged PR #338, focused on high-confidence resilience, lifecycle, sharing, and release-verification gaps without broad rewrites.

## Bugs / risks found
- Hadith database can be fully verified and then rejected solely because the tiny verification-marker write fails; the marker is an optimization, not evidence.
- Translation TTS owns the Activity context instead of the application context, increasing lifecycle/leak risk around slow TTS initialization and rotation.
- Research PDF provider authority is hard-coded in the manifest while runtime derives it from the application package; future build variants/applicationId changes can break URI sharing.
- Ambient overlay startup assumes the default display lookup is always non-null on API 30+, creating an avoidable service crash edge case.
- CI verifies debug packaging/lint but does not exercise the release variant.

## Fixed
- Hadith/audio marker resilience, TTS context ownership, variant-safe sharing, display lookup guarding, release CI, CI deduplication, and build-integrity guards are implemented on this PR branch.

## Pending
1. Finish the current-head CI run.
2. Resolve any failing step at its root cause.
3. Re-check the final PR diff and mergeability.
4. Mark PR #339 ready for review.

## Tests / CI
- Base main: latest commit 5f3eb0d merged PR #338.
- Main Actions visible: GitHub Pages succeeded; app verification workflow is PR/audit-branch scoped and will run on this branch.
- Branch CI: final-head verification pending after the latest checkpoint.

## Next exact step
Inspect the current-head CI result; resolve any failure, then verify mergeability and mark PR #339 ready.
