# Aaris Pharmacy — Medicine Extraction Hardening V29 (2026-09-14)

## Scope and mapped execution path

This pass stays inside the existing local-first medicine-capture authority. The
repository tree, `docs/ARCHITECTURE.md`, `docs/CODEBASE_TREE.md`, scanner service,
intake worker, deterministic understanding engine, Resolver V2, semantic/date
reasoners, controller CAS boundary and SQLite write path were cross-checked before
changing the hot OCR boundary.

```text
camera / photo / video / pasted OCR
        ↓
MedicineVisionService (Latin + Devanagari OCR, barcode, geometry)
        ↓
medicine_ocr_text.dart  ← V29 surgical target
        ↓
MedicineUnderstandingEngine
        ↓
spatial / regulatory / date / semantic reasoning
        ↓
MedicineProductResolverV2
        ↓
review + MedicineScanCommit gate
        ↓
PharmacyController revision/CAS
        ↓
InventoryDatabase / SQLite
```

No second parser, model, database, network route or inventory mutation path was
introduced. OCR remains evidence; pharmacist review and the existing revision-
bound controller/database gateway remain authoritative.

## Audit findings

The newest V27/V28 work correctly unified Unicode OCR normalization across flat
and geometry evidence and kept strong safety gates around dates and product
identity. The next practical accuracy gaps were all at the same original OCR
boundary:

- OCR could split a printed dose into single-digit tokens (`6 5 0 mg`), causing
  otherwise clear strength evidence to be missed.
- Full-word units (`milligrams`, `micrograms`, `millilitres`) were not converted
  into the compact unit grammar consumed by deterministic extraction.
- Concentrations written as prose (`125 mg per 5 millilitres`) did not enter the
  existing slash-based concentration grammar.
- A common `ml` OCR confusion (`m1`) could turn a clear volume/concentration into
  unusable text.
- `1,000 mg` reached the downstream decimal-comma normalizer and could be treated
  as `1.000 mg` instead of one thousand milligrams.
- The per-line normalization hot path repeatedly constructed several regular
  expressions even though the grammar is immutable.

Scanner close/admission leasing, intake serialization/work barriers, Local-AI
lease ownership and final controller/database CAS boundaries already close the
relevant lifecycle and write races, so this pass deliberately does not add
parallel locks or wrapper state machines.

## V29 implementation

`lib/domain/medicine_ocr_text.dart` remains the single original normalization
surface and now performs only tightly context-bound repairs:

1. Precompiled immutable regexes remove avoidable hot-path allocation.
2. Two-to-five separated single digits are joined only when immediately owned by
   a pharmaceutical unit.
3. Spaced decimal punctuation is compacted without assigning any medical role.
4. Numeric full-word units are canonicalized to `mg`, `mcg`, `ml`, `g`, `iu` or
   `%`; prose without a numeric owner is unchanged.
5. `m1` becomes `ml` only beside a real numeric token.
6. A non-zero `x,yyy` thousands shape is de-grouped only immediately before a
   pharmaceutical unit; `0,500 mg` remains decimal-comma evidence.
7. Numeric concentration prose using `per` is rewritten to the slash grammar
   already consumed by the deterministic strength parser.

These transformations happen before the existing baseline extractor, semantic
roles, product resolver and evidence conflict gates. They therefore improve raw
OCR understanding without granting new authority to OCR or inventing a product.

## Fail-closed boundaries

- `OIL milligrams` and other pure-letter pseudo-numbers are never converted.
- Ordinary prose such as `Take one tablet per day` is unchanged.
- Dates, batch numbers and serials cannot be joined by the separated-digit rule
  unless a pharmaceutical unit owns the token.
- No new fuzzy brand/salt catalogue is added and no medical fact is inferred from
  a unit normalization alone.
- Conflicting strength/date/product evidence still reaches the existing conflict
  and human-review layers.

## Regression coverage

`test/medicine_extraction_hardening_v29_test.dart` adds source-level contracts for:

- fragmented dose digits,
- full-word units,
- `per` concentration syntax,
- decimal spacing,
- `m1`/`ml` OCR confusion,
- thousands-versus-decimal-comma safety,
- equivalent OCR-line deduplication,
- unlabelled brand + two-ingredient composition inference after normalization,
- negative prose and pure-letter safety cases.

This checkpoint is source-only and uses `[skip ci]`. Release workflows and APK
building remain untouched.
