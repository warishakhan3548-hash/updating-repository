# Aaris Physical Findability and Concurrency Upgrade — 2026-09-10

This pass extends the existing deterministic Aaris operating system without adding another inventory database, AI mutation path or clinical inference layer.

## Physical stock findability

Aaris now treats a missing storage location as an operational attention signal for active stock. A stock row with no Block, Row, Vertical or shelf location is surfaced for pharmacist review. Short-expiry rows receive higher urgency because FEFO is only useful in practice when the pharmacist can find the exact pack quickly.

The operating planner places location work in its own **Make stock findable** lane. Missing location can block dependent physical FEFO work such as short-expiry handling and expiry-waste review, but it deliberately does **not** block reorder decisions: a shelf address is not demand or quantity evidence.

Aaris never guesses or auto-fills a storage location. Tapping the work item opens the exact authoritative stock row for human verification.

## Action-first operating plan

The Recommended Next card in Needs Attention is now directly actionable. One tap opens the exact next task, or the first verified prerequisite when downstream work is blocked. This removes a needless search step while preserving the same deterministic dependency graph and existing review screens.

## Target-scoped relocation concurrency

Reviewed stock relocation no longer becomes stale merely because an unrelated medicine changed while the pharmacist was reading the confirmation. The review remains valid only when the exact target row revision and every before/after location fact are unchanged.

The final save rebases onto the current inventory revision and still passes through the authoritative SQLite compare-and-swap transaction. A concurrent change to the exact stock row still fails closed, and a new race after revalidation is still rejected by persistence.

## Preserved invariants

- SQLite remains the single authoritative Medicine Database.
- No AI/OCR output can invent or silently mutate a location.
- No medical or clinical fact is inferred.
- Expired, SOLD and removed-stock behavior is unchanged.
- Reorder remains driven only by valid inventory/sales evidence.
- Exact-row location changes remain reviewed, atomic, auditable and undoable.
- Conflicting or stale target facts still fail closed.
