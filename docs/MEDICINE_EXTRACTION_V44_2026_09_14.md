# Medicine Extraction V44 — 2026-09-14

V44 is a surgical deterministic extraction hardening pass. It does not add a model, network dependency, database, second state store, or alternate extraction pipeline.

## Architecture checkpoint

The production medicine path remains:

1. Camera / photo / video / file acquisition.
2. ML Kit Latin + Devanagari OCR, layout evidence and safe machine-code capture.
3. `medicine_ocr_text.dart` semantic-preserving OCR canonicalization.
4. Baseline candidate extraction plus `medicine_semantic_roles.dart` field-role reasoning.
5. `medicine_date_parser.dart` + date intelligence chronology/conflict resolution.
6. `medicine_resolution_v2.dart` bounded catalog / offline-memory hypothesis resolution.
7. Review-cardinality and commit safety gates.
8. SQLite inventory as the single persisted source of truth.

Local AI remains an optional post-extraction verifier. The deterministic draft is authoritative when no local model or cloud API is selected, and optional AI failure cannot erase that draft.

## Root causes fixed

### Strong semantic labels lost their ownership

OCR frequently flattens packaging roles such as:

- `ACTIVEINGREDIENTNAMEPARACETAMOL650MG`
- `ACTIVE-INGREDIENT-NAME: PARACETAMOL 650 mg`
- `MANUFACTURER_NAME: FDC LIMITED`
- `PRODUCT-NAME: CROCIN 650`
- `SALT_NAME: PARACETAMOL`
- `PROPRIETARYNAMECROCIN`
- `TRADEMARKCROCIN`

The previous canonicalizer handled several collapsed labels, but an embedded word such as `NAME` could survive as part of the field value. In the worst case `ACTIVE INGREDIENT NAME` or `MANUFACTURER NAME` could therefore contaminate the extracted salt/manufacturer.

V44 canonicalizes only strong, explicit pharmaceutical roles and restores only a missing role/value boundary. Bare ambiguous prefixes such as `BRAND...` and `SALT...` remain untouched, so recall is not bought by broad token splitting.

### Hindi date roles had an English-only named-month parser

The date-role grammar already understood Hindi manufacturing and expiry labels, and OCR digit repair already understood Devanagari digits. The named-month calendar grammar, however, accepted only English month words. A pack such as `निर्माण तिथि: अप्रैल २०२६` therefore had a valid role and valid digits but could still lose the date value.

V44 adds deterministic Hindi month names and common orthographic variants to the same calendar validator. It also accepts unambiguous four-digit-year-first named dates such as `2028 APR` / `२०२८ अप्रैल`. No date is inferred from manufacturing date and no chronology safety threshold is bypassed.

## Safety properties preserved

- No fuzzy medicine fact is invented during OCR normalization.
- Machine-code / batch ownership remains separate from dose parsing.
- MFG and EXP remain field-local, conflict-aware facts.
- Catalog knowledge remains a hypothesis/canonicalization layer, not permission to overwrite contradictory OCR.
- Local AI and cloud AI remain optional; V44 improvements work with both disabled.
- No inventory mutation occurs before the existing review/commit gates.
- No new runtime dependency or background service was added.

## Regression coverage

`test/medicine_extraction_hardening_v44_test.dart` adds adversarial coverage for:

- collapsed and punctuation-separated semantic labels;
- protection of ambiguous bare prefixes;
- Hindi month names with Devanagari digits;
- day-month-year and year-month named-date order;
- end-to-end V2 offline extraction of trade name, salt, strength, form, manufacturer, MFG and EXP from one noisy OCR frame.

The repository execution environment used for this code-upgrade pass does not expose the Dart/Flutter runtime, so no local `flutter test`, `flutter analyze`, APK build, or GitHub workflow was executed. Verification for this pass is architecture/static review plus committed regression coverage; the existing release workflow is untouched.
