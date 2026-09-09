# Pharmacist Work Queue

The work queue is a local, deterministic operational assistant. It does not diagnose, prescribe, invent medicine facts or write to inventory by itself.

## Priority order

1. **Critical** — expired stock that must be segregated/reviewed before dispensing.
2. **High** — short-expiry stock, explicit SOLD stock and zero-quantity entries that are not marked SOLD.
3. **Review** — velocity-based low-stock reorder suggestions, month-expiry planning and missing expiry/quantity/location facts.

Only one strongest record-level task is shown for a stock entry at a time. A stronger stock inconsistency suppresses a weaker duplicate reorder reminder for the same product.

## Inputs

The queue reads only the existing authoritative projections and facts:

- current `Medicine` records from local SQLite,
- `WarningSettings`,
- the deterministic expiry/status engine,
- aggregate `SaleEvent` history,
- the existing 30-day `TrackingStats` reorder engine.

No cloud service or local LLM participates in queue ordering.

## Actions

Selecting a task opens the exact saved stock record ID in the existing editor. All edits, sales, SOLD changes, archives and restores continue through `PharmacyController` and `InventoryStorage`, so revision checks, expiry guards, atomic commits, activity history and Undo remain authoritative.

## Non-goals

The queue never:

- automatically removes expired stock,
- marks quantity-zero stock SOLD without pharmacist confirmation,
- changes warning windows,
- creates a purchase order automatically,
- infers an unknown expiry, quantity or storage location,
- bypasses FEFO or dispensing validation,
- changes scanner/OCR/AI runtime behavior.
