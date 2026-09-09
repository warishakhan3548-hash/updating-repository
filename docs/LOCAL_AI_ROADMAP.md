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
