# Medicine Extraction V38 — Compact role and traceability recovery

Date: 2026-09-14

## Architecture audit

The Android intake path remains intentionally layered and single-authority:

`MedicineIntakeService._understand` → isolate `understandMedicineEvidenceV2Message` → canonical OCR normalization → baseline deterministic evidence parser → spatial/regulatory traceability → date intelligence → semantic medicine roles → coherent product resolver → reviewable draft.

The intake queue already serializes durable queue writes and protects active OCR/reasoning work with a work barrier. SQLite inventory remains outside this extraction service, so this pass does not add concurrency wrappers or a second persistence path.

## Root causes found after V37

V37 safely restored MFG/EXP boundaries when the first month digit was OCR-confused as O/I/l and a visible month/year separator survived. Two compact packaging failures remained at the lexical boundary:

1. A fully compact month/year such as `MFGO42026` or `EXPI22028` retained the field label glued to the value. The date parser can repair a role-owned O/I glyph, but every downstream layer should first see the same explicit role boundary.
2. Traceability headings such as `BATCHNUMBERAB123`, `BATCHNUMAB123`, or `LOTNUMBERZX-77` could be split after only BATCH/LOT, leaving `NUMBER...` attached to the actual payload. That weakens the existing batch grammar and can leak traceability text into identity heuristics.

## V38 changes

`medicine_ocr_text.dart` remains the single canonicalization seam.

- Confusable fused MFG/EXP recovery now accepts either the existing separator form or a complete compact four-digit year after the two-character month surface. It restores only the missing field boundary; O/I/l-to-digit repair remains owned by the date parser.
- Fused `NUMBER`, `NUM`, and `NO` lot qualifiers are normalized to the existing `NO` role form. The batch/lot payload is preserved byte-for-byte apart from normal whitespace canonicalization.
- Negative ordinary-word behavior remains guarded by the known pharmaceutical role prefix and strict numeric/date shape.

No LLM, cloud API, model download, database scan, persistence layer, background worker, or unbounded fuzzy pass was added. The rules are precompiled and bounded to the already bounded OCR line.

## Regression coverage

`test/medicine_extraction_hardening_v38_test.dart` covers:

1. Compact confusable month/year role recovery plus a negative ordinary-word control.
2. `BATCHNUMBER`, `BATCHNUM`, and existing `BATCHNO` payload preservation.
3. End-to-end Resolver V2 extraction of trade name, salt, strength, MFG, EXP, and batch from fused OCR with empty local knowledge and empty canonical catalogue.

## Verification boundary

Per the repository checkpoint contract, this change is verified by source/diff inspection and focused regression coverage without running Flutter workflows or building an APK. Physical Android camera/vendor OCR behavior remains a device-QA boundary.
