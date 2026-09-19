# Aaris Pharmacy — Medicine Extraction Hardening V27 (2026-09-14)

## Scope

This checkpoint stays inside the existing medicine-capture authority. It does not
add a second parser, database, model, cloud dependency, or UI write path.

The mapped capture path remains:

```text
camera / photo / video / pasted text
        ↓
MedicineVisionService
        ↓
ML Kit Latin + Devanagari OCR + barcode + layout boxes
        ↓
bounded OCR normalization / evidence merge
        ↓
deterministic understanding
        ↓
spatial + regulatory + date + semantic reasoning
        ↓
MedicineProductResolverV2
        ↓
review / evidence validation
        ↓
PharmacyController revision/CAS gate
        ↓
SQLite medicine database
```

SQLite remains the only inventory source of truth. OCR and AI outputs remain
reviewable proposals.

## V27 surgical changes

### One OCR surface for flattened and geometry evidence

Previously the flattened OCR stream and geometry-backed layout stream could see
different text surfaces. Script digits, full-width Latin/unit glyphs and Unicode
separator variants could therefore be understood by one lane but missed by
another lane that drives date adjacency, product prominence or semantic roles.

`medicine_ocr_text.dart` now owns one bounded, semantic-preserving
normalization function and `MedicineVisionService` applies it to both paths.

It normalizes:

- Devanagari and Arabic-Indic digits to ASCII digits.
- Full-width ASCII letters, numbers and punctuation to compatible ASCII.
- Unicode slash/dash/decimal presentation variants.
- Greek/micro `μ/µ` to the existing `u` micro-unit spelling.
- O/0 and I/l/1 confusion only inside a numeric token immediately followed by a
  pharmaceutical unit and only when the token already contains a real digit.

The last gate is intentionally narrow: words such as `OIL` and `ILL` cannot turn
into invented doses.

### Compact MMYY recovery

A common printed `MM/YY` date can become `MMYY` after OCR loses punctuation.
The date parser now recognizes four-digit compact month/year syntax.

This syntax is deliberately role-unsafe. It becomes MFG/EXP only when:

- an explicit/adjacent date label owns it, or
- exactly two isolated compact values form one plausible chronological
  manufacturing-to-expiry shelf-life pair.

A singleton compact number, lot-owned value, batch number, serial or other
non-date context still fails closed.

## Performance and regression boundary

The normalization pass is linear in the bounded OCR line length and reuses the
existing resolver. No model inference, network request or new persistence is
introduced.

Regression coverage verifies:

- full-width product names and units,
- Devanagari / Arabic-Indic strength digits,
- Unicode decimal and micro-unit glyphs,
- bounded O/0/I/l strength repair,
- full-width brand-to-semantic-role flow,
- labelled compact MMYY recovery,
- unlabeled two-date chronology,
- singleton and lot-owned compact-number rejection.

This checkpoint is source-only and carries `[skip ci]`; it does not modify the
release workflow or build an APK.
