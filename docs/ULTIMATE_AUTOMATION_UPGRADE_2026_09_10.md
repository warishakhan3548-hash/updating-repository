# Aaris Pharmacy — automation safety upgrade (2026-09-10)

This upgrade deepens the existing architecture instead of replacing it.

## Reviewed single-stock sales

Ordinary editor sales now use the same review/apply pattern already used by FEFO,
SOLD, removal, restore, stock adjustments and location changes. A review is bound
to the exact physical Medicine row shown to the pharmacist. Unrelated inventory
traffic can advance the global database revision without forcing a harmless retry,
but any edit to the reviewed row invalidates the operation. The persistence CAS
and sale-ledger firewall remain authoritative at commit time.

The editor additionally binds its sale review to the exact Medicine snapshot that
was visible while the dialog was open. A background or competing edit to that row
therefore cannot be silently accepted after confirmation.

## Human field-edit commands

Aaris Brain now understands natural commands such as `Dolo expiry change karo`,
`batch number update`, `price correct`, and equivalent Hindi phrases. These commands
only resolve the exact local stock target and open the existing reviewed editor;
they never invent a new expiry, price, salt, batch, barcode, strength or other
medicine fact.

The same deterministic mutation firewall handles field edits. Negated, deferred
or compound instructions fail closed before target search, while read-only expiry
questions, stock quantity commands and physical-location commands retain their
specialized deterministic routes.

## Invariants preserved

- One authoritative Medicine Database.
- No silent destructive mutation.
- No AI/OCR output can bypass pharmacist review.
- No invented clinical or medicine facts.
- Sale audit remains append-only outside audited Undo/backup recovery.
- FEFO and expiry validation remain deterministic.
- All mutation commits remain revision-checked, atomic and undoable.
- The design remains local-first and stores no customer/patient identity.
