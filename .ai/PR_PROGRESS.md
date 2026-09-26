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
- Functional checkpoints are present on this PR branch; this progress file is being reconciled with the actual diff.

## Pending
1. Make Hadith verification marker best-effort after cryptographic/database verification.
2. Harden TTS context ownership and overlay display fallback.
3. Make provider authority applicationId-safe.
4. Add release-variant CI verification and regression guards.
5. Run/inspect PR CI and resolve every failure.

## Tests / CI
- Base main: latest commit 5f3eb0d merged PR #338.
- Main Actions visible: GitHub Pages succeeded; app verification workflow is PR/audit-branch scoped and will run on this branch.
- Branch CI: pending first code checkpoint.

## Next exact step
Patch HadithStore marker handling and add a regression assertion in tools/check.py, then push as the first functional checkpoint.
