# Aaris Reviewed Operational Orchestration — 2026-09-10

This pass extends the existing Aaris Brain rather than adding another inventory or mutation engine.

## Reviewed stock relocation

Aaris Brain can understand explicit stock-location commands such as `Dolo 650 location Block B2 Row R4 Vertical V3 set karo` and `isko shelf Cold Cabinet 2 set karo` after an exact stock row is already in context.

The command parser only accepts explicit location vocabulary plus a mutation verb. Medicine strength numbers are not location fields. Structured Block / Row / Vertical values and bounded free-form shelf/rack locations are extracted deterministically; ambiguous or malformed location commands do not become writes.

A relocation produces a revision-bound review token containing the exact stock ID, record revision, inventory revision and before/after physical location. The pharmacist sees the before/after location and must confirm. The controller then re-reads live inventory and fails closed if any relevant fact changed. The final write goes through the existing authoritative controller/database integrity and Undo path. SOLD rows cannot be relocated as if physical stock still exists.

## Intent-aware removal reasons

Explicit reasons such as Expired, Damaged, Returned and Correction are captured as bounded deterministic intent slots. The reason text is removed from fuzzy medicine targeting, improving exact-match quality. A supplied reason skips only the redundant reason picker; the final destructive confirmation is still mandatory. A `sold` / `stock finished` hint routes to the existing SOLD confirmation instead of archiving a sale as a generic removal.

## Preserved invariants

- SQLite remains the only authoritative medicine database.
- No location command can edit clinical identity, expiry, quantity, sales or price.
- Uncertain medicine resolution still requires exact pharmacist selection.
- Every actual location write is reviewed, revision checked, atomic and undoable.
- Natural-language bulk deletion remains blocked.
- OCR/AI confidence never bypasses deterministic validation.
- No patient/customer identity or cloud persistence is introduced.
