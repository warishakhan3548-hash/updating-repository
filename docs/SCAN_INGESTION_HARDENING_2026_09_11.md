# Aaris Pharmacy — scan ingestion hardening (2026-09-11)

## Dependency tree

```text
Normal camera scan
  -> ScannerScreen live bounded evidence + captured still
  -> on-device OCR/barcode
  -> deterministic medicine understanding
  -> selected Local AI only when Aaris Brain is enabled
  -> source validation
  -> duplicate/lot/chronology gate
  -> verified local-AI auto-save OR review
  -> PharmacyController revision-bound save
  -> atomic SQLite inventory transaction

Explicit cloud scan
  -> owner chooses Scan with cloud AI
  -> on-device OCR/barcode
  -> CloudScanReviewScreen
  -> bounded scan-derived OCR only -> configured cloud AI
  -> source validation -> review -> revision-bound save

Gallery photo / video
  -> system picker staging file
  -> app-private copy
  -> durable intake SQLite job checkpoint
  -> photo OCR OR bounded video-window sampling
  -> deterministic resolver
  -> capture-bound Local AI when enabled
  -> durable review drafts
  -> pharmacist Confirm/Add
```

## Surgical fixes

### 1. Plain Scan can no longer infer cloud consent

The Add / Import `Scan medicine` route previously allowed a saved cloud API configuration to become an implicit OCR handoff whenever Local Brain was off. That contradicted the explicit cloud lane already exposed by `medicine_capture.dart` and the repository privacy invariant that configuration alone is not consent.

`ImportInboxScreen` is now local-only. Its cloud transport, cloud state and duplicated provider branch were removed. Cloud OCR exists only in `CloudScanReviewScreen`, reached after the owner explicitly chooses **Scan with cloud AI**.

### 2. Upload Photo is now crash-resumable

The standalone Upload Photo action previously performed transient OCR directly from the picker cache while Upload Video entered `MedicineIntakeService`. An accepted photo could therefore disappear if the process died between picker return and review.

Photo and video now share one `_queueMedia` path. `MedicineIntakeService.addFile` copies the source into private storage and commits the SQLite job before returning; OCR/Local-AI work can safely resume later. The picker staging file remains best-effort cleanup only.

## Invariants retained

- No scanner or AI owns an inventory database handle.
- Local AI output remains evidence-grounded proposal data.
- Normal scan/photo/video never fall through to cloud.
- Exact lot, duplicate, date/chronology and revision gates remain authoritative.
- Cloud scanning remains available as an explicit per-capture action.
- Photo/video queue capacity, private source ownership and worker barriers remain unchanged.


## Crash-consistency cleanup hardening

A successfully checkpointed photo/video draft is now independent from private-source housekeeping. If Android temporarily refuses source deletion, the job remains in its valid review/reasoning state and retains the validated private path for a later Retry/Dismiss cleanup attempt instead of being rewritten as `failed`.

Startup also removes only strict unreferenced `<32-hex-id>.jpg/.mp4` capture files from the private intake directory. This closes the narrow process-death window after private copy but before the SQLite job insert without touching database files or any source still referenced by a restored job.

## Machine-save authority cleanup

The explicit cloud scan screen is pharmacist-review-only, so the obsolete `ScanAutoSaveVerifier.cloudAi` authority was removed. Direct unattended scan save now has exactly one provenance: a source-verified, scan-verified Local AI route plus the deterministic duplicate/lot/date/confidence/revision gates.
