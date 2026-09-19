# Scanner UI and connected-flow review — 12 September 2026

Base: `main` at `53d81a55954b2f5dcb6db22973db8129a7358c61`.
Scope: capture-button displacement, scanner ownership/failure recovery and
connected search/import/review paths. Existing stock rules and routing remain.

## Dependency and user-state map

| Journey | Execution path | Changed intersection |
| --- | --- | --- |
| Launch and navigation | `main.dart` → SQLite → `PharmacyController` → app shell → tabs | Read-only review; no alternate database writer |
| Capture | Search / Brain / Import → `ScannerScreen` → camera + `MedicineVisionService` → Resolver V2 → `ScanResult` | Camera serialization, callback generation and successful-still handoff |
| Visible controls | Scanner state → `ScannerView` → action callbacks | Fixed action area above scrolling camera/result content |
| Scan search | `ScanResult` → scoped local search → optional owner-enabled catalogue | Exact selected-scan check before lookup and publication |
| Local review/save | Evidence or durable queue → understanding / optional Local AI → inbox → duplicate/date/revision gates → controller → SQLite → projections | Existing boundaries reviewed; scanner cannot write stock directly |
| Explicit cloud review | Owner-selected cloud lane → bounded evidence → validator → review → Confirm/Add or editor → controller | Review eligibility repaints on inventory changes |

## Confirmed problems and fixes

1. **Buttons below the viewport:** the camera, result and buttons shared an
   outer scroll. Even the existing 180-pixel text limit allowed buttons to leave
   the screen. `ScannerView` replaces that original layout: controls own a fixed
   area, while the preview and full selectable OCR text scroll separately. Rapid
   mode uses “Capture photo” / “Finish captures”; opening/busy controls disable.
2. **Overlapping camera operations:** bootstrap/retry bypassed lifecycle
   serialization, and invalidation occurred later in the queued stop operation.
   Opening, retry and resume now share one queue; invalidation is immediate.
   Stream callbacks carry their creating generation. Retired initialization
   results are disposed without publishing state or opening a second camera.
3. **Old preview submitted after failed still:** recognition returned no outcome
   and auto-submit checked previously populated text/barcode. Auto-submit now
   requires successful nonempty recognition from this still and the same capture
   session. Complementary live evidence remains; empty/failed stills show an
   error and stay on the scanner instead of automatically submitting old text.
4. **Live scan stopped after failure:** stream recovery runs after both success
   and failure, only for the owning session. Cancelled work cannot restart an old
   camera or pop another screen. Teardown drains still capture and OCR before
   native disposal. Already-durable rapid-photo acknowledgements remain valid
   across app pause.
5. **Old scan starting catalogue work after typing:** selected-scan identity is
   checked after local search and before/after the optional catalogue request.
   Changing the query or choosing another scan invalidates delayed work.
6. **Stale duplicate eligibility in cloud review:** controller notifications now
   refresh review buttons, including saves through the field editor. Listeners
   are removed/rebound on disposal/controller changes. Commit-time checks remain
   authoritative.

## Verification

- **442 Flutter tests passed across 41 runnable test files**, including **14
  scanner UI tests**. The production view was tested at 320×568, 360×720, 390×844
  and 780×360, each with text scale 1.0, 1.6 and 2.0. Tests grow OCR to 180 lines,
  verify unchanged action positions, scroll content and tap both controls without
  bringing them into view. Opening, busy, retry and rapid modes are covered.
  The rendered long-text phone screenshot was inspected locally.
- Available suites cover domain status/search, dates, medicine evidence/resolver,
  scan commit policy, Brain intents, reorder/tracking, privacy source contracts,
  local context/capture and date-input UI. This is not the full app suite.
- **430 counted standalone contracts** passed across domain, scan capture,
  offline context, medicine understanding, dates, local AI, model preflight and
  catalogue fixtures. The separate default-AI policy check passed too. These
  overlap Flutter coverage and are not 430 additional independent scenarios.
- Targeted Dart analysis of all `lib/domain`, `scanner_view.dart` and its test
  found no issues. Scanner sources parse/format; `git diff --check` passes.

### Environment and limits

Pinned app packages are missing: offline resolution fails at
`sqflite_common_ffi 2.4.2+1`; camera, ML Kit and other app plugins are absent too.
Full-app analysis and the remaining suites could not run. Camera-session guards
and search/cloud-review changes were inspected at source level; their actual
plugin-driven execution has not been tested here.

Passing Flutter checks used an isolated temporary harness against actual repo
source, Flutter 3.47.2 and Dart 3.13.2. Missing framework support packages came
from these official source snapshots, with harness-only path overrides:

| Source | Snapshot |
| --- | --- |
| characters 1.4.1, dart-lang/core | `b59ecf4ceebe6153e1c0166b7c9a7fdd9458a89d` |
| vector_math 2.4.0-wip, google/vector_math.dart | `cf3b5db7340d317dd3489e5a35434b408020a852` |
| material_color_utilities 0.13.1, material-foundation/material-color-utilities | `5b3618b16fdc3825e21d5679bafd144662088ea1` |
| Leak tracker support, dart-lang/leak_tracker | `bfb2d612bfda485470573db66ff37de8beac1628` |

These overrides do not change the app's pubspec, lockfile, vendored runtime or
release dependencies. Results establish the tested source/layout behavior, not
compatibility of every pinned plugin. Physical Android permission/camera/OCR,
background/resume during capture, real GGUF inference, native SQLite and live
authenticated endpoints remain unverified. No inventory or provider credentials
were used.

## Delivery

The delivery commit carries `[skip ci]`. Existing workflows use push,
pull-request or manual-dispatch triggers; none is edited or manually started.
No APK is compiled/generated/uploaded. Changes target the existing repository's
`main` without rewriting remote history.
