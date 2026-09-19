
# Aaris reviewed-action concurrency upgrade — 2026-09-10

This pass removes false-stale confirmation failures from reviewed pharmacy work without weakening Aaris's single-database, local-first or fail-closed safety boundaries.

## What changed

- Exact stock quantity corrections and stock receipts are bound to the reviewed physical row revision and reviewed before/after facts instead of the entire inventory revision. Unrelated inventory traffic may occur while the pharmacist reads a dialog; the action is rebased only when the exact target is unchanged.
- Removed-stock restore uses the same exact-row rule. The archived row revision, removal reason and removal timestamp must still match exactly. Cross-row lot/barcode/date integrity remains enforced by the persistence safety kernel.
- FEFO sale review carries revisions for every physical row shown in the allocation. If unrelated inventory changes, Aaris verifies those rows and recomputes FEFO from the live Medicine Database. The action proceeds only when the ordered allocation is equivalent. A newly added or changed earlier-priority batch invalidates the review before any sale is written.
- Every rebased action still commits against the current authoritative SQLite revision. A race after revalidation is rejected by the existing compare-and-swap persistence boundary.

## Preserved safety invariants

- SQLite remains the sole authoritative Medicine Database.
- OCR/AI/local-model output never bypasses pharmacist review or deterministic validation.
- Bulk removal, Undo, backup restore and multi-change AI plans remain snapshot-scoped because their correctness depends on the wider inventory state.
- No medical facts, quantities, locations, expiry values or batch identities are guessed.
- FEFO remains deterministic and fails closed for changed reviewed rows, newly relevant batches, unknown priority quantities, expired stock and future-MFG stock.
- Existing atomic audit, sale-ledger, integrity and Undo behavior remains intact.

## Regression coverage

Focused tests cover unrelated-write survival for stock adjustments, stale exact-row rejection, unrelated-write survival for archived restore, exact-row restore invalidation, unrelated-write FEFO rebasing, newly earlier FEFO batch invalidation, and existing exact-row FEFO staleness. The one-shot verification job formats changed Dart sources, runs static analysis, the focused suites, the full Flutter test suite and an Android debug compile before committing the source upgrade to `main`.
