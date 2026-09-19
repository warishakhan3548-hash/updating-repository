# Aaris Pharmacy — autonomous operations upgrade (9 September 2026)

This upgrade extends the existing architecture; it does not replace the master medicine database, reviewed AI protocol, scanner/OCR pipeline, FEFO rules, SQLite transaction layer or local-first privacy boundary.

## What changed

### Aaris Brain now deep-links into protected stock actions

Natural-language removal and whole-stock SOLD commands resolve against the existing unified search engine and require an exact, high-confidence stock target. If the result is ambiguous, Aaris presents the matching physical stock entries and requires the pharmacist to choose one.

After an exact selection, Aaris opens the Medicine Database context and immediately presents the existing protected operation instead of making the pharmacist find the action again. Removal still requires a reason and a second confirmation, remains a soft archive, and keeps Undo/history. Whole-stock SOLD still requires confirmation, refuses expired stock, creates no fake customer sale, and updates reorder intelligence through the authoritative controller.

Bulk destructive language remains blocked. Inventory revision changes during confirmation invalidate the command instead of applying it to stale state.

### Deterministic attention engine

`domain/attention.dart` adds a local operational-risk layer over current inventory and reorder facts. It does not own data and never mutates stock. It prioritizes:

- expired active stock;
- zero quantity that has not been explicitly marked SOLD;
- short-expiry stock;
- conflicting medicine identities sharing one barcode;
- urgent and review-required reorder suggestions;
- missing expiry or quantity where that missing optional fact reduces automation confidence.

Same-identity batches may share a barcode without being treated as a conflict. Archived stock is excluded. The engine does not infer treatment, dosage, indications or any other clinical fact.

`AttentionScreen` exposes this as a live, ranked pharmacist queue. A single-record item opens the exact stock entry. Barcode conflicts show the involved records. Reorder items open the reviewed purchase-order workflow.

### Reorder control from Aaris Brain

Commands such as `order now`, `reorder list`, `low stock review` and `kya order karna hai` route directly to the existing 30-day deterministic reorder engine. Confidence-gated suggestions remain unchanged: weak-evidence suggestions are visible but are not preselected into an order.

Targetless `stock khatam` is now informational and opens the SOLD projection. It cannot accidentally become a mutation. A targeted command such as `Dolo 650 stock khatam` remains a reviewed whole-stock SOLD action.

## Safety invariants preserved

1. SQLite inventory remains the sole source of truth.
2. AI/OCR output never directly mutates inventory.
3. Uncertain medicine resolution never chooses a stock entry automatically.
4. Destructive operations remain explicit, reviewable and recoverable.
5. Expired stock cannot be silently relabelled SOLD.
6. Quantity zero does not silently imply SOLD.
7. Reorder quantities remain deterministic operational suggestions, not clinical recommendations.
8. The attention engine is read-only and recomputes from live inventory; it creates no second database or hidden state.
9. No customer/patient identity is introduced.
10. All new automation remains local-first.

## Verification added

- App Brain routing regressions cover reorder commands and targetless SOLD language.
- A widget regression checks that an exact Brain remove command opens the protected reason/confirmation flow and does not mutate inventory before confirmation.
- Attention-engine checks cover priority ordering, barcode-conflict discrimination and archived-stock exclusion.

The normal `Pharmacy checks` workflow remains the release gate for static analysis and the full Flutter test suite. Because this change touches `lib/**`, the existing release workflow also builds the Android release APK after the main-branch push.
