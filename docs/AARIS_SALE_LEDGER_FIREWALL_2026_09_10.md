# Aaris Sale Ledger Firewall — 2026-09-10

This upgrade hardens the existing Aaris Pharmacy transaction architecture. It does **not** add a second inventory, a parallel sales database, or an AI-owned mutation path.

## Why this exists

The app already validates normal sale flows in `PharmacyController`, but the authoritative persistence API can also be called by future UI, automation, import, AI-review or maintenance code. A caller bug at that lower boundary could previously construct a `SaleEvent` that did not match the stock delta, rewrite an existing sale event, or delete sale history outside Undo/backup recovery.

That is a dangerous architectural gap for an increasingly autonomous app: controller correctness alone is not enough when more features converge on the same database.

## New invariant: sale audit and stock movement must reconcile atomically

`lib/domain/sale_ledger_guard.dart` adds a deterministic local-only safety kernel. `InventoryStorage` invokes it before an ordinary transaction can become authoritative.

For every newly appended sale event the firewall verifies:

- the sale targets an exact stock row that existed before the transaction;
- the row was active and not already SOLD before the sale;
- the sale's medicine identity/salt snapshot comes from that authoritative row rather than invented caller data;
- the sale date does not contradict recorded MFG/EXP facts;
- known stock decreases by exactly the combined recorded sale quantity;
- an unknown stock baseline stays unknown instead of a sale inventing a remaining quantity;
- a sale cannot be combined with hidden removal or medicine-identity rewriting;
- SOLD cannot be asserted while known units would remain.

A mismatch fails closed before SQLite or memory state changes.

### One business-clock authority

Whether a user-entered sale date is in the future remains a `PharmacyController` policy checked against the controller's injectable app clock. The persistence firewall deliberately does not compare sale timestamps with `DateTime.now()`: doing so would create a second time authority that could disagree with deterministic tests, restored historical data, or an app-level clock policy. The storage boundary still independently revalidates immutable MFG/EXP chronology and all ledger-to-stock invariants.

## Sale history is append-only during ordinary operations

Recorded sale events are now immutable under normal app mutations:

- ordinary transactions cannot delete an existing sale event;
- ordinary transactions cannot rewrite an existing sale event under the same ID;
- exact no-op re-submission is harmless, but it cannot change audit facts.

The existing audited **Undo** path is intentionally exempt because it must restore the exact immediately previous transaction. The existing explicitly reviewed **backup restore** path is also exempt because recovery must reproduce the reviewed source snapshot, including legacy data. These are the only current destructive/recovery gateways for sale history.

## Existing pharmacist workflows remain unchanged

This firewall sits underneath the current flows rather than replacing them:

`Brain / UI / FEFO / scanner / reviewed AI -> PharmacyController -> InventoryStorage -> inventory integrity firewall + sale ledger firewall -> one authoritative snapshot`

There is no extra confirmation for a valid existing sale flow. The protection activates only when a caller attempts an inconsistent or destructive transaction.

## Regression coverage

`test/sale_ledger_firewall_test.dart` adversarially covers:

- valid atomic stock + sale reconciliation;
- forged sale without stock decrement;
- mismatched medicine/salt snapshots;
- identity edit hidden inside a sale transaction;
- unknown-quantity movement without fabricated remainder;
- blocked ordinary sale deletion;
- blocked sale-event rewriting;
- blocked create-and-sell hidden transaction;
- expiry-day historical sale acceptance and after-expiry rejection.

The pre-existing persistence, FEFO, Undo, backup and injected-clock stock-operation suites remain the integration gates and prove that recovery semantics and legitimate sale flows do not regress.

## Product invariant preserved

SQLite remains the sole authoritative pharmacy database. AI/OCR still cannot bypass review or deterministic validation. No medical fact is inferred here, no patient/customer identity is added, no cloud service is introduced, and no automatic destructive behavior is added.
