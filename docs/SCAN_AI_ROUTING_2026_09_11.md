# Aaris Pharmacy scan → AI → inventory map

## Dependency tree

`ScannerScreen`
→ `MedicineVisionService`
→ ML Kit Latin + Devanagari OCR + barcode
→ `MedicineFrameEvidence`
→ `understandMedicineEvidenceMessage`
→ deterministic pharmacy entity extraction (`MedicineScanDraft`)
→ route policy
  - Local Brain ON + scan-ready model → `LocalAiService.understand`
  - Local Brain OFF/unavailable → deterministic on-device extractor only
  - explicit **Scan with cloud AI** action → separate `CloudScanReviewScreen` → `CloudScanAiService.refine`
→ exact-source validation (`validateLocalScan`)
→ duplicate / lot resolution (`resolveIntakeDraft`)
→ machine-save gate (`scanAutoSaveDecision`)
→ normalized `Medicine` (`medicineFromConfirmedScan`)
→ `PharmacyController.save`
→ revision-bound `InventoryMutation`
→ storage compare-and-swap commit.

## UI/state map

Capture → OCR evidence → route resolution → structured fields populate the scan preview.
A source-verified Local or Cloud AI result can proceed to automatic save only when
Brand + Salt + Strength + Form, overall confidence, batch/date integrity, duplicate
resolution, and live inventory revision all pass. Any ambiguity stops at review.

When no AI route is available, the existing deterministic pharmacy parser acts as
the offline NER/entity extractor and auto-fills supported fields, but it does not
grant itself unattended inventory-write authority.

## Privacy and routing invariants

1. Local Brain has priority when its owner switch is ON. A Local AI failure never
   silently leaks the scan to cloud.
2. Cloud routing is never inferred from a saved API configuration. It is entered
   only after the owner explicitly chooses **Scan with cloud AI** for that capture.
3. Before cloud handoff, local Medicine Database identity memory is removed from
   the provider-bound deterministic draft. Only bounded OCR evidence and
   deterministic candidates derived from that scan are sent.
4. Local and Cloud model output are proposals. `validateLocalScan` requires
   source-grounded evidence before fields can influence the preview.
5. AI services never write inventory. The deterministic domain gate and
   `PharmacyController` remain the only write authority.
6. Exact existing lots, ambiguous products, weak/conflicting fields, invalid
   chronology, or stale revisions fail closed to review.
