# Aaris Brain — reviewed recovery & dispensing upgrade

Date: 2026-09-10

This pass extends the existing Aaris Pharmacy architecture. It does **not** create a second inventory store, a shadow AI database, or an autonomous write path.

## Invariants preserved

- The existing Medicine Database remains the single source of truth.
- Archived/removed stock remains a projection of the same `Medicine` records.
- OCR, fuzzy search and natural-language parsing can discover and rank evidence, but they cannot silently mutate inventory.
- Recovery, sales, stock adjustments, location changes and removals still commit through `PharmacyController` → `InventoryStorage` with optimistic revision checks and persistence-boundary integrity guards.
- No medical facts are generated or inferred by the new logic.
- Removed-stock search is local-only and contains no patient/customer data flow.

## Removed-stock recovery kernel

Previously, Profile displayed every archived row and exposed a direct restore button. This was functional, but weak for a long-running pharmacy because removed history can become large and a user could restore a row without reviewing a revision-bound token.

The upgraded flow is:

`Aaris Brain/Profile → RemovedStockScreen → PharmacyController.searchArchived → MedicineSearch (same ranker) → exact archived row → reviewArchivedRestore → explicit confirmation → applyArchivedRestore → InventoryStorage.commit`

Important properties:

1. **One database** — archived search reads the same `Medicine` objects as active inventory.
2. **Lazy archive index** — native search keeps the existing active hot index and builds the archived index only when Removed stock is opened. This avoids making normal medicine search slower as historical rows grow.
3. **Same search semantics** — removed history uses the existing barcode, fuzzy medicine/brand/salt, batch, location, OCR keyword and strength-conflict ranking logic rather than a duplicate search implementation.
4. **Barcode is discovery, not mutation authority** — one product barcode may legitimately map to several historical batches. Exact barcode search can return all matching removed rows; the pharmacist still selects the exact row.
5. **Revision-bound restore token** — the review captures inventory revision, row revision, archive reason and archive time. Any intervening inventory mutation invalidates the review.
6. **Persistence guard remains final authority** — if restoring a row would create a contradictory physical-lot state, the existing integrity guard rejects the commit.
7. **Undo remains available** — successful restore is an ordinary audited mutation and can be reversed through Activity.

## Aaris Brain command upgrades

The deterministic App Brain now understands recovery and common pharmacy dispensing imperatives without bypassing the existing review surfaces.

Examples:

- `restore Dolo 650` → opens Removed stock prefiltered for Dolo 650. It does **not** restore automatically.
- `removed stock dikhao` → opens local removed history.
- `restore backup` → routes to Profile/Backup semantics, never medicine restore.
- `Dolo 650 5 units sell` → enters the existing reviewed FEFO sale path with quantity 5.
- `Dolo 650 sell` → opens the existing sale editor/review because quantity is not safely specified.
- `Dolo 650 sell which batch first` → remains a read-only FEFO question and cannot become a sale.

This separation is deliberate: language understanding decides **which safe workflow to open**, while deterministic domain logic and human review decide whether a write is valid.

## Activity recovery safety

Activity's Undo action now asks for explicit confirmation and shows the exact latest audited event/revision before calling the existing revision-protected undo transaction. This makes Profile recovery behavior consistent with Aaris Brain's confirmation policy.

## Adversarial cases covered by tests

The new regression tests cover:

- fuzzy removed-stock search excluding active rows;
- one barcode mapping to multiple removed batches without automatic selection;
- exact archived-row restore preserving batch/quantity facts;
- restore remaining undoable;
- stale restore review rejection after any inventory revision change;
- integrity-guard rejection when restore would duplicate a physical lot;
- targeted vs targetless recovery language;
- backup-restore wording isolation;
- English/Hindi explicit sale quantities;
- FEFO/read questions containing `sell` or `dispense` remaining non-mutating;
- question-shaped sale language never creating a write intent.

## Design rule for future Brain capabilities

New Aaris Brain capabilities should follow the same pattern:

**Understand → resolve local evidence → show exact facts → create revision-bound review → explicitly confirm → commit through one controller/storage boundary → audit → allow recovery.**

AI may make the interface feel intelligent; it must not become a second authority over medicine truth.
