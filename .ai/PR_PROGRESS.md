# PR Progress

## Scope
Second-pass production audit after merged PR #338, focused on high-confidence resilience, lifecycle, sharing, release verification, and supply-chain integrity without broad rewrites.

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

## Fixed
- Hadith/audio marker resilience, TTS application-context ownership, variant-safe sharing, display lookup guarding, release CI, CI deduplication, and Gradle/wrapper integrity guards are implemented on this PR branch.
- The manual SDK release builder now expands `${applicationId}` itself and rejects any unsupported remaining manifest placeholder instead of packaging it literally.
- The HadeethEnc capture workflow now pins checkout to the reviewed immutable v4 revision; `tools/check.py` guards both this pin and the manual release manifest invariant.

## Pending
- No identified high-confidence product-code or release-path fix remains in this PR.
- Review and merge PR #339 when desired.

## Tests / CI
- Base main at verification: 5f3eb0d5438351f8b6e048d1d57b4420bdd49aea (merged PR #338).
- Final full verification run 36215140358 passed on head faafccacb1a65ede2f53f4209e29ddad5a2f064f.
- PASS: deterministic local Quran/translation/Hadith evidence rebuild.
- PASS: offline integrity, source-contract, and search regressions.
- PASS: Android debug assemble + lint.
- PASS: Android release assemble + lint.
- This final checkpoint changes only this progress file and uses [skip ci]; product/build code is identical to the verified head above.

## Next exact step
Review and merge PR #339. If later work is requested, first read this file, verify the PR/base state, and continue only if the new task is genuinely related.
