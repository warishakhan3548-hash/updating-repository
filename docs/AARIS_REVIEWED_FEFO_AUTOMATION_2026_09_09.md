# Aaris Reviewed FEFO Automation — 2026-09-09

This upgrade extends the existing local-first Aaris Pharmacy architecture without creating a second inventory authority.

## New operational path

When Aaris Brain receives an explicit sale command with a physical unit quantity, for example `Dolo 650 12 units record sale`, it now:

1. parses only an explicit `unit / units / pcs / pieces / qty / quantity` count; medicine strengths such as `650 mg` are never treated as stock quantity,
2. resolves one medicine identity conservatively,
3. builds a deterministic First-Expiry-First-Out allocation across current physical batches,
4. excludes expired, SOLD, removed, and future-manufacturing-date rows,
5. stops if an earlier FEFO batch has unknown quantity rather than skipping or guessing it,
6. shows every batch, quantity, expiry and location that will be affected,
7. requires explicit pharmacist confirmation,
8. commits every batch movement and sale event in one revision-checked SQLite transaction,
9. leaves the whole transaction undoable through the existing audit history.

No AI model can bypass this transaction boundary. Local/remote AI may understand language, but deterministic inventory facts, revision checks and human confirmation remain authoritative.

## Proactive integrity checks

The Needs Attention engine additionally surfaces:

- future manufacturing dates as high-priority data-quality issues,
- likely duplicate physical batch rows when medicine identity + batch + barcode/location repeat,
- existing barcode identity conflicts, expiry risks, unknown quantities/expiries and reorder evidence.

Reorder intelligence now uses the same dispensability predicate as FEFO. Future-MFG rows do not count as usable current stock and any reorder suggestion influenced by that condition is forced into pharmacist review instead of being high-confidence/preselected.

## Safety invariants preserved

- one authoritative medicine database,
- no silent destructive action,
- no invented medicine or clinical facts,
- no automatic mutation from uncertain OCR/AI,
- local-first data processing,
- optimistic revision concurrency control,
- atomic audited mutations and undo,
- patient/customer identity is not collected by the sale automation.
