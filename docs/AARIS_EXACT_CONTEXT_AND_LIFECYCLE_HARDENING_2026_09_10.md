# Aaris Exact Context & Lifecycle Hardening — 2026-09-10

This pass extends the existing Aaris Pharmacy architecture without adding a second database, a parallel AI mutation path, or any cloud dependency.

## Human-like exact context, without guessing

Aaris Brain may now continue a deterministic single-medicine command when the pharmacist omits the medicine name **only if** the current session already holds one exact active stock ID whose physical-identity fingerprint still matches the authoritative Medicine Database.

Examples after an exact medicine/batch is selected include stock receiving/correction, explicit sale commands, edit/remove, reviewed location changes and read-only expiry/location/FEFO questions. Ambiguous status wording such as targetless `stock khatam` remains informational. A bare targetless `sell` is not promoted into a mutation; quantity-qualified sale wording can reuse exact context but still enters the existing reviewed FEFO flow.

No operational facts are cached in conversational memory. Quantity, dates, price, status and location are re-read from the live inventory snapshot on every command. If exact context is absent or its identity fingerprint no longer matches, the command fails closed and asks the pharmacist to choose a row.

## Dependency-scoped lifecycle confirmations

Single-row Remove and whole-stock SOLD confirmations now use immutable review tokens. The reviewed token contains the exact medicine row shown to the pharmacist. At apply time Aaris compares the current authoritative row against that review:

- unrelated inventory traffic no longer forces a valid confirmation to be repeated;
- any change to the reviewed target row invalidates the confirmation;
- SOLD is rechecked against expiry at the apply-time business clock;
- Remove preserves the reviewed reason;
- no sale event is invented by whole-stock SOLD;
- all writes still pass through `PharmacyController -> InventoryStorage`, SQLite CAS, integrity guards and audit history.

The lifecycle transition timestamp and inventory audit timestamp now share one controller-captured instant, eliminating a midnight-edge mismatch between `archivedAt`/`soldAt` and the durable transaction business day.

## Safety invariants preserved

- one authoritative medicine database;
- no silent destructive action;
- no fuzzy mutation target from implicit context;
- no AI/OCR write bypass;
- no invented medical facts;
- local-first/privacy behavior unchanged;
- existing FEFO, sale-ledger, integrity, Undo, backup and removed-stock recovery guards remain authoritative.
