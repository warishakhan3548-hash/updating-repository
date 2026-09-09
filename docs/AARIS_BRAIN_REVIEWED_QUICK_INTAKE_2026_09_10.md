# Aaris Brain Reviewed Quick Intake — 2026-09-10

Aaris Brain now turns explicit pharmacist add commands into a pre-filled medicine
editor instead of throwing the typed facts away.

Examples:

- `add medicine Dolo 650 qty 20 exp 2027-05 batch AB12 shelf A1`
- `add medicine Amox 500mg capsule qty 30 block B1 row R3 vertical V4`
- `नई दवा Crocin qty ५ expiry २०२७-०५`

## Safety contract

This is **draft automation**, not autonomous inventory mutation.

- The parser only uses facts the pharmacist actually typed.
- Bare numbers are never guessed as stock quantity, price, or strength.
- Unit-bearing strengths and recognized dosage forms are extracted from the
  command text; no salt, indication, dose, substitution, or other medical fact
  is invented.
- Explicit dates are validated and invalid dates fail closed.
- Explicit quantity and money values use the same bounded rules as inventory.
- The existing medicine editor remains the save boundary.
- Existing duplicate/barcode/fuzzy-match confirmation still runs before a new
  stock entry can be saved.
- The global inventory revision check still rejects a stale editor save.
- The authoritative SQLite database, audit/Undo path, integrity firewall, FEFO,
  scanner/OCR review, and removed-stock recovery architecture are unchanged.

The result is less typing for pharmacists without granting natural-language AI
an unreviewed write path.
