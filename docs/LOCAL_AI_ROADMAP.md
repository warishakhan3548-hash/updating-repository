# Local AI implementation plan

The existing AI Hub remains the only AI control surface. SQLite, the reviewed
action protocol and the OCR/layout resolver remain the core, not parallel copies.

## Source map and responsibilities

| Existing core | Integration |
| --- | --- |
| `ui/ai_screen.dart` | Existing settings gain local models; composer gains capture/voice |
| `services/ai_service.dart` | Explicit local routing before any API configuration/network path |
| `domain/ai_protocol.dart` | Exact IDs, revision/replay checks, preview and atomic apply |
| `domain/medicine_understanding.dart` | Group evidence first; local semantic assessment once per draft |
| `services/scan_service.dart` | Same Latin/Hindi OCR and barcode evidence for every entry point |
| `ui/import_screen.dart` | Shared validated draft review; no model writes directly to SQLite |
| `services/media_import_service.dart` | Bounded video extraction and cleanup |
| `state/pharmacy_controller.dart` | Authoritative snapshot and transaction gateway |

## Delivery order

1. Pure, testable local-agent contract: bounded read tools, app-owned request IDs,
   no raw SQL, no fabricated stock facts, evidence-grounded scan suggestions.
2. One in-process llama.cpp runtime and private model store. Public GGUF search,
   revision-pinned downloads, streamed SHA-256 verification, explicit activation,
   serial inference and graceful model release. No inference server.
3. Integrate that active runtime into the existing AI Hub and import review.
   Show actual readiness/errors, not invented pharmacy scores. Add camera and
   offline-requested voice input without changing the review/apply boundary.
4. Durable intake drafts, bounded rapid capture/video work, regression tests,
   source checks and incremental main-branch checkpoints.

## Non-negotiable boundaries

- Model discovery/download is explicitly online; inventory, OCR and prompts are
  not sent to that service. Local inference never falls back to an external API.
- GGUF is a container, not a universal compatibility guarantee. Activation must
  load the file and test structured output. No arbitrary downloaded native code,
  remote Python, tokenizers or model-supplied instructions are executed.
- Download size is not working RAM. Device/model execution still needs physical
  validation; a successful JSON smoke test is not medical qualification.
- Local AI receives relevant paged stock facts and deterministic summaries, not
  a full-database prompt. Every suggested existing-ID change must reference an ID
  that was actually retrieved from the request snapshot.
- Printed pack size/MRP never become stock quantity/cost. Unknown fields remain
  unknown. Conflicting identities/dates require review. No prescribing advice.
- Automatic capture persistence means durable **drafts**, not unreviewed stock.
  A model's self-reported confidence cannot authorize inventory mutations.
- Background processing is app-process work, not a promise of surviving OS
  termination. Persisted jobs must recover to a reviewable/retryable state.
- No APK build, workflow dispatch or cloud/server sync. Checkpoints use
  `Auto-save: ... [skip ci]`; never force-push over concurrent owner changes.

## Release gates

Run pure domain/protocol regressions here. Before release, the owner must compile
and exercise native CPU model load/unload, interrupted downloads, low storage,
Hindi voice availability, process death and representative labelled medicine
packaging on actual target devices. Do not advertise universal model support,
clinical accuracy, 100% video recall or unattended authoritative auto-save.

## Checkpoints

- Safety contract: 20 initial checks passed; published to main as `e9edd09`.
- Model manager uses pinned `lib_llama_cpp 0.7.3` CPU command-stream inference,
  `file_selector 1.1.0` and streamed `crypto 3.0.7` verification. Public catalogue
  downloads and the local inference client are separate. Existing provider calls
  are unreachable while a local selection exists, including load failures.
- Local mic uses Android's actual on-device recognizer (API 31+), not merely an
  offline preference on a potentially network-backed speech service. Unsupported
  devices/languages fall back to typing, never online voice automatically.
- Available Flutter SDK executable crashed during dependency-tool startup;
  native integration is not device-tested. Source-only dependency/static checks
  are being attempted separately. No APK or CI was run.
- Source-only package resolution subsequently succeeded using the installed
  Flutter 3.47.2 sources and the working standalone Dart SDK; the lockfile now
  includes the pinned model runtime and also matches the existing secure-storage
  pin. `dart analyze lib test tool` passed. This is not native execution testing.
- AI Hub and import share a durable, bounded capture inbox. Rapid capture
  acknowledges the private file + job write before OCR. Video is processed in
  20-second windows, preserving unresolved evidence across boundaries and
  checkpointing completed drafts + cursor together. Drafts never auto-write stock.
- Duplicate OCR frames still count as one confidence vote, but now retain all
  source frame IDs. Without that provenance, a video window could lose the one
  weak view containing EXP when carrying the clearer front view forward.
- Combination suggestions are salt/adjacent-strength pairs with source quotes,
  not two independently sorted lists. Unsupported/reordered pairings are rejected.
- Native model import copies/hashes large GGUF files on a worker thread, not
  Android's activity-result UI thread. Partial download ranges and storage are
  checked; disabling local routing rolls back if its settings cannot be saved.
- The pinned Android runtime supplies arm64 artifacts. Local activation is gated
  to arm64 Android 9+; optional NNAPI/Vulkan build features are disabled so the
  original app's older Android minimum need not be raised for the plain scanner.
- The original Upload video action now uses the same durable windowed queue as
  AI Hub. Photos cannot be starved by a long video. Queue recovery rejects invalid
  cursors, mismatched IDs and corrupted evidence instead of silently dropping it.
- Read tools distinguish expired from future-expiring stock, exclude sold/archive
  from active searches, provide bounded detailed/archive reads, and count exactly
  the requested number of civil sales days. Follow-up context survives tool rounds.
- Dependency source audit found missing generation completion events and no
  prompt-memory reset in upstream 0.7.3. The minimal MIT-licensed inference core
  is now vendored via a normal path dependency, with fixes directly in its worker
  and native runtime. Unused server/client exports and the server dependency were
  removed. Platform binaries remain pinned; no inference server is introduced.
- Latest checks: local AI contract 54, model lifecycle 12, medicine understanding
  24, domain 52, date input 25 — **167 passing checks**. Full source analysis
  includes the vendored core. Lifecycle tests use controlled streams and a real
  worker's missing-library error path, not an actual model's semantic accuracy.

## Deliberately not claimed as finished

- No trained pharmacy-specialist weights or verified national drug corpus were
  supplied or fabricated. The model is user-selected; existing reviewed local
  knowledge remains the identity reference. Setup checks are not clinical scores.
- Only supported, complete GGUF language weights can be attempted, not every
  model format/repository. Public model search/download needs internet; inference
  and inventory remain on device. Gated downloads are not impersonated/bypassed.
- The repository's native app remains Android-focused. Desktop runtime selection
  is portable code, not a promise of tested desktop packaging or camera support.
- Unattended stock auto-save, direct SQL and permanent delete power are not
  enabled. Captures/drafts persist automatically; reviewed actions still use the
  existing transaction, revision, duplicate and replay guards.
- Native model loading, low-memory behavior, process-death recovery, voice and
  representative packaging/video accuracy require the owner's device tests.
