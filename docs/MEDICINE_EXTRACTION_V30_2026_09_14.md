# Aaris Pharmacy — Medicine Extraction Hardening V30 (2026-09-14)

## Mapped boundary

This checkpoint keeps the existing local-first capture and write architecture intact:

```text
camera / photo / video / pasted OCR
        ↓
MedicineVisionService
        ↓
medicine_ocr_text.dart
        ↓
MedicineUnderstandingEngine
        ↓
semantic / spatial / date / regulatory reasoning
        ↓
MedicineProductResolverV2
        ↓
review + MedicineScanCommit
        ↓
PharmacyController revision/CAS
        ↓
SQLite
```

The repository tree, architecture map, scanner recognizer lifecycle, deterministic intake path, Resolver V2, semantic-role layer and final revision-bound database gateway were cross-checked before changing the extraction hot path. No second parser, database, cloud dependency, lock, model or write route is introduced.

## Root cause fixed

A common liquid-medicine label writes the denominator before the ingredient rather than after the strength, for example:

`Each 5 ml contains Paracetamol I.P. 125 mg`

The existing composition parser correctly recognized the heading but consumed `Each 5 ml contains` before strength extraction. The remaining evidence therefore became `Paracetamol 125 mg`, losing the clinically important `5 ml` concentration basis. The semantic component parser could also leave the leading `5 ml` attached to the ingredient segment because the basis appeared before the first strength.

## V30 implementation

`medicine_ocr_text.dart` now performs one bounded, evidence-preserving normalization when an explicit numeric `ml`/`g` composition basis and `contains` heading own the same OCR line:

- `Each 5 ml contains Paracetamol 125 mg` becomes `Each 5 ml contains; Paracetamol 125 mg/5 ml`.
- Full-word units and fragmented digits continue to flow through the existing V29 canonicalizer first.
- Multi-ingredient composition lines inherit the same explicit basis for each numerator strength, up to the existing bounded component count.
- The inserted semicolon retains every observed token while making the already-real heading/ingredient boundary explicit to the existing semantic segmenter.
- A strength that already has a slash denominator is never denominatorized again, including spaced slash OCR.
- Ordinary dose instructions and container-volume prose cannot trigger the rule because they do not have the required `numeric basis + contains` ownership shape.

This fixes the information-loss bug at the original OCR boundary, so baseline extraction, semantic roles and Resolver V2 all receive the same corrected evidence instead of adding downstream overrides.

## Regression coverage

`test/medicine_extraction_hardening_v30_test.dart` covers:

- full-word and fragmented-unit composition basis recovery,
- `mg/5 ml` and `mg/5 g` concentration ownership,
- already-explicit concentration idempotence,
- negative instruction/container-volume cases,
- semantic ingredient identity without `5 ml` contamination,
- multi-ingredient suspension concentration inheritance,
- final Resolver V2 draft propagation including form, MFG and EXP.

The change remains deterministic, linear in the bounded OCR line, offline and review-first. Inventory mutation authority and scanner lifecycle ownership are unchanged.
