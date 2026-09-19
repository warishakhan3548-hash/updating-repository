# Medicine Extraction Hardening V31 — 2026-09-14

## Scope

This revision keeps the existing local-first extraction architecture and hardens two evidence-boundary failures discovered during a fresh repository/tree audit. It does not add cloud dependencies, parallel state authorities, scanner wrappers, or a second medicine database.

## 1. Composition ownership is now clause-bounded

V30 correctly recovered liquid concentration denominators such as `Each 5 ml contains Paracetamol 125 mg` → `125 mg/5 ml`, but a flattened OCR row could continue into a different semantic role:

`Each 5 ml contains Paracetamol 125 mg. Dose 250 mg after food`

The denominator must belong only to the composition clause. V31 detects high-confidence role switches (dose/dosage/directions, administration, storage/warnings, regulatory/date/pack/manufacturer fields and excipient presentation) and preserves the suffix without inheriting the liquid basis.

The semantic composition parser applies the same ownership principle before aligning ingredient/strength pairs, preventing an instruction such as `Dose 250 mg` from becoming a fabricated ingredient component.

## 2. Unlabelled compact date pairs survive OCR row flattening

The date intelligence layer already accepted two isolated compact dates on separate rows (`0426` then `0428`) when chronology was plausible, while rejecting singletons and lot-owned identifiers. OCR/layout flattening can legitimately emit the same pair as one row: `0426 0428`.

V31 accepts this shape only when:

- exactly two compact date tokens are present;
- everything around/between them is only harmless date punctuation/whitespace;
- no adjacent non-date owner such as LOT/BATCH claims the row;
- inferred shelf life remains within the existing bounded chronology window;
- the inferred manufacturing date is not implausibly future-dated.

Rows containing labels/IDs/noise or three compact numeric tokens continue to fail closed.

## Safety / architecture invariants

- SQLite remains the single source of truth.
- OCR evidence remains reviewable and is not written directly to inventory.
- No fuzzy deduplication of numeric strength evidence was introduced.
- Geometry remains authoritative when available.
- Existing revision/CAS and intake/scanner concurrency barriers are unchanged.
- All new parsing is deterministic, bounded, precompiled-regex based, and offline.

## Regression coverage

`test/medicine_extraction_hardening_v31_test.dart` covers:

- composition denominator scoping across a flattened dose instruction;
- prevention of a fabricated `Dose` ingredient;
- same-row compact MFG/EXP chronology recovery;
- fail-closed LOT/noisy compact numeric rows;
- end-to-end Resolver V2 propagation for composition, strength, MFG and EXP.
