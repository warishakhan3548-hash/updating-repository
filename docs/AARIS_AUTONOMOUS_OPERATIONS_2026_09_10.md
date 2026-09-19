# Aaris Autonomous Stock Operations Upgrade — 2026-09-10

This upgrade extends the existing local-first Aaris Pharmacy architecture; it does not create a second medicine database or a parallel mutation engine.

## What changed

### Aaris Brain can now prepare reviewed stock operations

The deterministic command layer understands explicit, quantity-bound stock commands such as:

- `Dolo 650 stock add 12 units`
- `Dolo 650 restock 4 units`
- `Dolo 650 quantity 20 set karo`
- `isko stock add 7 units` after an exact stock row has already been selected

Medicine strength numbers are not treated as quantities unless a quantity is attached to an explicit stock-operation phrase. Hindi/Devanagari digits are normalized locally. Ambiguous or incomplete language does not become an automatic stock mutation.

Every command still resolves through the existing unified Medicine Database search. A low-confidence or multi-row result requires the pharmacist to choose the exact batch.

### Review → confirm → atomic commit

Stock receiving and exact quantity correction now use a revision-bound review object in `PharmacyController`.

The controller records:

- inventory revision,
- stock ID,
- medicine-record revision,
- operation kind,
- current quantity,
- reviewed final quantity,
- prior SOLD state.

The UI shows the pharmacist the before/after state and requires an explicit confirmation. `applyStockAdjustment` revalidates the review against live inventory immediately before the SQLite mutation. A concurrent edit invalidates the review instead of being overwritten.

### Receiving stock is different from correcting stock

`receive` means a genuine positive stock arrival. It requires a known current quantity, rejects expired physical stock rows, checks overflow, and may explicitly reopen a SOLD row while preserving historical sale records.

`setExact` is a stock-count correction. It never invents a sale event. Setting an active row to zero does not silently mark the row SOLD. A SOLD row cannot be changed to a positive exact quantity through correction; it must use the explicit receive-stock path.

### Unknown-quantity sale safety hole closed

A sale can still be recorded against stock whose current quantity is unknown, because the sale movement itself may be known. However, that sale can no longer claim that the entire stock row is finished. `markSoldOut=true` is rejected when the current quantity is unknown, preventing an arbitrary sale quantity from silently turning unknown stock into zero/SOLD.

### Bulk removal now requires a reviewed snapshot token

The protected Profile flow creates a `BulkArchiveReview` before confirmation. It includes the exact active stock-ID set and inventory revision. After the two user confirmations, `applyArchiveAll` verifies that the same inventory is still active. If anything changed while the dialogs were open, the action fails closed.

The old direct `archiveAll()` mutation gateway remains only as a compatibility symbol and always fails closed. This prevents future UI, AI, or service code from bypassing the protected review path accidentally.

### Persistence boundary hardened

Both SQLite and in-memory storage now reject malformed mutation shapes before event accounting or writes, including:

- duplicate medicine upsert/remove IDs,
- the same medicine ID appearing in both upsert and remove sets,
- duplicate or contradictory sale IDs,
- invalid request/undo IDs,
- invalid revisions and audit labels.

This closes a class of caller bugs where duplicate objects could otherwise corrupt event accounting even if the final map happened to contain only one row.

## Safety invariants preserved

- SQLite remains the sole authoritative medicine database.
- AI/OCR output never bypasses deterministic validation or pharmacist review.
- No patient or customer identity is introduced.
- No medical fact is fabricated.
- Expired stock is not automatically reopened by receiving logic.
- Stock corrections do not fabricate sales.
- Every accepted mutation is atomic, audited, revision-checked, and compatible with the existing Undo model.
- Natural-language bulk deletion remains blocked.

## Regression coverage

`test/autonomous_stock_operations_test.dart` covers command parsing, context reuse, strength/quantity separation, stock receipt + Undo, SOLD restock behavior, unknown-baseline protection, expired-stock protection, exact corrections, stale review rejection, unknown-quantity sold-out prevention, revision-bound bulk removal, fail-closed legacy bulk mutation, and persistence mutation-shape validation.
