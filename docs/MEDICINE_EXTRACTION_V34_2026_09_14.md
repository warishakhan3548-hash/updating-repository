# Medicine Extraction V34 — Fused semantic-pack recovery

Date: 2026-09-14

## Architecture audit

The authoritative Android intake path remains `MedicineIntakeService._understand` → isolate `understandMedicineEvidenceV2Message` → canonical OCR normalization → baseline deterministic parser → spatial/regulatory traceability → date intelligence → semantic roles → coherent product resolver → reviewable draft. SQLite remains the only inventory authority and no extraction layer writes stock directly.

The audit found that V33 correctly recovered numeric glued roles and medicine+dose surfaces, but several high-value OCR collapses still crossed layer boundaries poorly:

- Named-month dates could remain invisible when the role and month were fused (`MFGAPR2026`, `EXPDEC2028`).
- Explicit multi-word medicine roles could collapse into one token (`BRANDNAMECALPOL`, `GENERICNAMEPARACETAMOL...`).
- Company ownership could collapse (`MANUFACTUREDBYACME`, `MFG.BYACME`), weakening manufacturer extraction and company-vs-product firewalls.
- A dose unit could glue to the dosage form (`CALPOL500MGTablets`), preventing the strength parser from seeing a safe unit boundary.
- Liquid composition scaffolds could fully collapse (`EACH10MLCONTAINSParacetamol250MG`), hiding the denominator from composition reasoning.

## V34 changes

`medicine_ocr_text.dart` now repairs those cases at the single canonicalization seam before any downstream field parser runs:

- Named-month role recovery requires a complete known date role followed by a valid month-name + year surface; unrelated words such as `EXPANSION2028` remain unchanged.
- Only strong collapsed multi-word labels (`BRAND NAME`, `TRADE NAME`, `PRODUCT NAME`, `GENERIC NAME`, `ACTIVE INGREDIENT(S)`, `MANUFACTURER`) are restored. Bare `BRAND`/`GENERIC` prefixes are intentionally not split.
- Glued owner headings restore the boundary after `... BY` without inventing a manufacturer value.
- Dose-to-form recovery reuses the shared `medicineFormAliases` vocabulary, so form knowledge still has one authority and no duplicate list can drift.
- Fully glued `EACH + numeric ml/g + CONTAINS` scaffolds are restored, then the existing concentration binder keeps the printed denominator attached only to composition-owned strengths.

## Safety and performance

The patch adds no LLM, TFLite model, network lookup, database scan, background worker or persistence layer. All new rules are precompiled/bounded and run on the already bounded OCR line. They recover only missing lexical boundaries; they do not invent brand, ingredient, strength, date, manufacturer or form facts. Existing contradiction, chronology, traceability, confidence and review gates remain authoritative.

The intake queue itself already serializes queue writes and uses a work barrier around active OCR/reasoning jobs, so this pass does not add another concurrency layer or wrapper.

## Regression coverage

`test/medicine_extraction_hardening_v34_test.dart` covers:

1. Named-month MFG/EXP role recovery with a negative `EXPANSION2028` control.
2. Strong semantic-label and manufacturer-owner boundary recovery.
3. Fully glued 10 ml composition denominator preservation.
4. Dose-unit-to-form recovery through the shared form vocabulary while keeping batch context out of dose promotion.
5. End-to-end Resolver V2 extraction of medicine name/brand, salt, strength, form, manufacturer, batch, MFG and EXP from heavily fused OCR with no local LLM, cloud API, local inventory knowledge or canonical catalogue input.

## Verification boundary

Per the repository release contract, this checkpoint does not run Flutter workflows or build an APK. Verification is source/diff based and the commit is marked `[skip ci]`; device camera/vendor OCR behavior remains a physical Android QA boundary.
