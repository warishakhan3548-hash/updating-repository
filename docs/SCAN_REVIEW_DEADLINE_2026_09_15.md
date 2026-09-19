# Scan preview remains usable during optional Local AI review

Base: `487f50ab88d3b9c227eb0905e887aacf4a4995d0`.

## Report and confirmed defect

The phone displayed `Medicine preview / Improving medicine details…` for several
minutes. This is the durable intake queue's `reasoning` state, reached after OCR
has produced and persisted a medicine draft. The panel previously hid that draft
and its Next action until the optional model finished. Each native generation had
a two-minute deadline, but setup and bounded retries could extend a scan beyond
one generation. A chat holding the shared runtime could also keep a draft queued.
This code-level finding does not identify the handset's exact model performance.

## Architecture and state ownership

| Component | Responsibility |
| --- | --- |
| `scan_service.dart` / media import | Camera, image and video OCR evidence |
| `medicine_intake_service.dart` | Persist capture and deterministic draft; schedule optional AI |
| `local_brain_route_policy.dart` | Recheck the owner's switches, selected model and runtime availability |
| `local_ai_service_io.dart` | Exclusive model lease, load, extraction and bounded recovery |
| `local_scan_request.dart` | One 30-second AI review budget across waiting, setup and retries; cancel only the owned native operation |
| `medicine_intake_panel.dart` | Show available fields during reasoning; Next freezes the draft before opening review |
| `medicine_review_pipeline.dart` | Apply the same budget to direct review entrypoints and reject stale results |
| Existing review/editor/controller | Human confirmation and authoritative inventory writes |

OCR completion now shows available details and Next immediately. AI can refine
that draft while the owner reads it. Next or Ask AI stops this scan's optional
review before continuing. If 30 seconds pass after the saved draft enters the
reasoning queue, the queue freezes its best available draft, removes the progress
indicator and permits normal review. Incomplete video OCR cannot be skipped by
this transition. For a multi-medicine scan the budget covers the whole AI review,
so remaining medicines retain their deterministic drafts when time runs out.

Native cancellation uses the runtime's existing transport retirement. It is bound
only during the requesting scan's exclusive operation and detached before the
runtime becomes available to another caller. A timeout while queued cannot stop
somebody else's chat. Checks after asynchronous stages prevent a late answer or
route repair from restoring a skipped scan, changing the AI index or replacing
the review snapshot. Timers close on completion; restored pending drafts get a
fresh bounded review window.

## Validation and limits

- 41 focused deadline/state/native-boundary checks: usable pending draft,
  persistence, no premature completion of OCR, timeout, user continuation, late
  answers, stale lease releases, stalled settings reads and chat after timeout.
- Existing 89 chat-response, 12 error/cancellation, 70 evidence-contract and
  25 setup-probe checks passed: 237 focused checks in total.
- Exact changed UI and service sources compiled against Flutter. External native,
  SQLite, OCR and cloud boundaries were controlled stubs for this compilation;
  it is not an Android APK build or a device inference test.
- No Flutter test suite, analyzer, CI or APK build was run. No on-device OCR
  accuracy, model throughput, or 2 GB/4 GB memory guarantee is implied.
- The 30-second budget limits optional AI review after draft preparation. Native
  cleanup can continue while the draft is already visible. It does not promise
  that camera capture, video decoding or OCR itself finishes within 30 seconds.
- Cloud/chat prompts, scan extraction instructions, evidence validation, model
  selection, inventory schema and human save confirmation remain unchanged.

Build from the published revision. With Local AI scan review ON, scan a legible
pack: available fields and Next should appear after OCR. Check early Next, then a
second capture allowed to reach the AI deadline. Compare fields to the physical
pack and verify ordinary chat still responds. Repeat the same pack with scan AI
OFF to check the deterministic path independently.

`tool/apply_scan_review_deadline_fix.py` is the complete replay for the base above.
It checks all affected file hashes before applying, refuses conflicts and symlink
targets, verifies the result, and is idempotent. It does not commit, push or build.
