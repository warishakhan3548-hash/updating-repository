# Medicine Extraction V43 — evidence retention and raw-date Unicode hardening

Date: 2026-09-14

## Scope

This pass stays inside the existing deterministic medicine-extraction system. It does not add a second database, a second extraction engine, an LLM dependency, cloud lookup, or an automatic mutation path.

## Architecture map

The authoritative scan/import path is:

1. Camera/photo/video/file ingestion produces bounded OCR/layout evidence.
2. `LocalScanEvidence` selects complete, contiguous source spans when raw text exceeds the local context budget.
3. `medicine_ocr_text.dart` canonicalizes OCR surfaces without inventing medicine facts.
4. `medicine_semantic_roles.dart` assigns bounded roles such as identity, ingredient, strength, form and manufacturer.
5. `medicine_date_parser.dart` plus date intelligence own calendar parsing, date roles and chronology.
6. `medicine_resolution_v2.dart` fuses OCR, geometry, reviewed local memory/catalog evidence and safety rules into drafts.
7. Review/cardinality/commit layers keep uncertain evidence out of authoritative inventory until the pharmacist confirms it.
8. SQLite remains the single source of truth; dashboard/search/tracking are projections over those records.

The key intersection for this pass is before semantic resolution: information that is dropped by the evidence budget cannot be recovered later, even if downstream parsing is otherwise correct.

## Audit findings fixed

### 1. Long OCR could discard valid late medicine facts

The long-text selector recognized a narrow dose-unit set. A late electrolyte dose such as `20 mEq/15 ml`, `25 ug`, `25 µg`, `25 μg` or `I.U.` could fail to become an anchor. On long package inserts, that could remove the ingredient/strength line before the medicine resolver ever saw it.

The selector also had no dedicated retention anchors for explicit late `PRODUCT NAME`, `BRAND NAME`, `TRADE NAME`, `GENERIC NAME`, `DOSAGE FORM`, or manufacturer-owner rows. This was especially risky when marketing/legal text preceded the actual medicine panel.

V43 broadens only evidence selection. It does not assign or authorize facts. The existing semantic, temporal, confusion and review firewalls remain authoritative.

### 2. Geometry-aware dates could bypass general OCR Unicode cleanup

Spatial MFG/EXP evidence can be parsed directly by `medicine_date_parser.dart`. That parser already normalized several digit and separator variants, but it did not mirror the general OCR canonicalizer for full-width ASCII, ideographic space, full-width decimal punctuation, or Arabic decimal punctuation.

V43 performs one-code-point-to-one-code-point normalization before date matching. This preserves character offsets while allowing examples such as full-width `ＭＦＧ：０５．０４．２０２７` and Arabic-digit `٠٤٫٢٠٢٨` to use the same deterministic date grammar.

## Safety invariants preserved

- No OCR text can write inventory directly.
- Evidence selection does not create a medicine name, salt, strength, manufacturer or date; it only retains original contiguous source text.
- Batch/lot/date ownership remains deterministic.
- Compact or ambiguous dates keep the existing role/chronology gates.
- No new network call, model download, cloud dependency or Firebase path is introduced.
- No second source of truth is introduced.
- Existing bounded input limits remain unchanged.

## Regression coverage

`test/medicine_extraction_hardening_v43_test.dart` covers:

- a raw OCR document longer than 7,000 characters with a late product-name row;
- a late `20 mEq/15 ml` dose row;
- late MFG/EXP rows;
- a late manufacturer row;
- full-width MFG/date text;
- Arabic digits plus Arabic decimal punctuation;
- a fully glued full-width compact EXP surface.

The release workflow remains responsible for static analysis, the full Flutter regression suite, release APK generation, SHA-256 verification and artifact upload.
