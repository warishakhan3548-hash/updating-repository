# Medicine Extraction V33 — Role-aware fused OCR recovery

Date: 2026-09-14

## Architectural finding

The production intake path already converges through `understandMedicineEvidenceV2Message`, which normalizes OCR before the baseline parser, date intelligence, semantic-role inference and product resolver run. That canonicalization seam is therefore the safest place to recover OCR-lost token boundaries without creating a second extraction engine.

The previous core strength parser intentionally required a boundary before a dose, while the semantic layer was more permissive. This protected machine codes but meant common OCR surfaces such as `CALPOL500MG` or `Paracetamol5O0MG` could lose strength/name/salt evidence. Fused role labels such as `MFG04/2026`, `EXP04/2028` and `BATCHNOABC850MG` could also hide the label from downstream role/noise firewalls.

## V33 change

`medicine_ocr_text.dart` now performs bounded, deterministic role-aware recovery before field extraction:

- Restores a missing boundary between an alphabetic medicine token and a numeric token only when the number is immediately owned by a pharmaceutical unit.
- Keeps the existing requirement that at least one real digit must be present before OCR-confusable `O/I/l` characters are repaired.
- Restores glued manufacturing, expiry, price and packing role boundaries when the role is immediately followed by digits.
- Restores `BATCH` / `LOT` and optional `NO` boundaries so downstream traceability firewalls can see the role.
- Refuses glued-dose splitting in nearby batch, lot, serial, licence, GTIN, barcode, code, MRP, date or pack context. This prevents a code such as `BATCHNOABC850MG` from inventing an `850 mg` medicine strength.
- Leaves unrelated alpha-numeric tokens such as `VitaminB12` untouched.

## Performance and safety

The upgrade uses precompiled regular expressions and one bounded linear pass over the already bounded OCR line. It adds no model, network dependency, database lookup or unbounded fuzzy search. Existing downstream arbitration remains authoritative.

## Regression coverage

`medicine_extraction_hardening_v33_test.dart` covers:

1. Glued brand/generic dose recovery, including `5O0` -> `500` only in unit-owned numeric evidence.
2. Glued MFG/EXP role recovery.
3. Glued BATCH/LOT recovery without false strength promotion.
4. End-to-end resolver V2 extraction of name, salt, strength, form, batch, manufacturing date and expiry date without local LLM, cloud API, local inventory knowledge or canonical catalogue input.
