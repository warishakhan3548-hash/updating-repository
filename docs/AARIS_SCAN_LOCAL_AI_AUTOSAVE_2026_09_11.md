# Aaris Scanner → Local AI → Safe Auto-Save

## Dependency tree

`ScannerScreen` still capture → `MedicineVisionService` OCR/barcode → deterministic medicine understanding → `ImportInboxScreen._prepare` → `LocalBrainRoutePolicy` privacy/readiness/lease authority → selected on-device `LocalAiService.understand` → `validateLocalScan` source validation → live `resolveIntakeDraft` collision check → `scanAutoSaveDecision` machine-commit gate → `medicineFromConfirmedScan` domain validation → `PharmacyController.save(expectedRevision)` serialized CAS persistence → controller notification/UI refresh.

## UI / state map

User opens **Scan medicine** → taps **Capture & automate** → still-frame OCR completes → scanner returns automatically (no **Use scan** tap) → Aaris Brain leases the active Local AI when enabled → validated AI evidence is merged → one safe new-stock/new-batch draft can auto-save (no **Confirm & add** tap) → inventory revision changes → UI refreshes from the authoritative database.

If Local AI is absent/off, the active model is not scan-verified, multiple medicines are detected, evidence conflicts, core confidence is below 0.88, an exact lot already exists, or inventory changes during reasoning, automatic save stops and the normal review UI remains authoritative.

## Surgical intersection

The LLM never receives database mutation authority. Automation is injected after validated Local-AI enrichment and immediately before the existing revision/CAS save boundary. OCR/LLM work stays probabilistic upstream; duplicate identity, lot integrity, chronology, confidence and persistence stay deterministic.

## Safety invariants

- Direct camera scanner only; photo/video/text/prepared batch imports keep explicit review.
- Exactly one medicine draft can auto-commit.
- Aaris Brain must be enabled and the exact active Local AI must both review the draft and have passed scan setup verification.
- Brand, Salt, Strength and Form must each be non-conflicting and at least 0.88 confidence.
- Existing `scanQuickAddDecision` must also pass.
- Exact saved lots and ambiguous matches never auto-create duplicate rows.
- Live inventory is re-resolved immediately before commit.
- `expectedRevision` CAS remains the final persistence authority.
- A scanner session makes only one automatic save attempt; any race or failure falls back to review rather than silently retrying a write.
