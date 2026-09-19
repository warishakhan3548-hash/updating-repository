# Medicine Extraction Hardening V32 — 2026-09-14

## Scope

V32 hardens deterministic, offline medicine understanding after a full architecture and extraction-path audit. SQLite remains the only inventory authority; OCR still creates reviewable evidence rather than direct stock writes.

## Shared dosage-form vocabulary

Form normalization and OCR extraction now consume one bounded alias table instead of independent copies. Common pharmaceutical presentation variants such as dispersible/orodispersible/chewable/effervescent/sublingual tablets, caplets, soft-gel capsules, oral drops and eye ointment resolve to the existing canonical forms without adding schema values or model cost. Brand cleanup uses the same vocabulary, preventing presentation text from leaking into medicine identity.

## Company-versus-product role firewall

A single company-identity marker is now shared by baseline OCR and semantic reasoning. LLP/PLC/incorporated, biotech, life-sciences, remedies and formulation-company rows cannot win the uncabelled product-name heuristic. The final semantic arbitration also replaces a high-confidence company-shaped legacy name when independent pack evidence yields a safe trade name, closing a typography/prominence failure mode rather than merely lowering confidence.

## Date and manufacturer alias hardening

The shared date grammar now recognizes conservative packaging aliases including `Date of Mfg`, `MFR DATE`, `E/D`, `XPRY` and `EXPN` while preserving the existing calendar, chronology, compact-token and non-date-owner gates. Punctuated/glued `MFD. BY`/`MFG.BY` manufacturer headings are accepted without turning manufacturer rows into product names.

## Safety and performance

All additions are deterministic and bounded. There is no network lookup, no new persistence layer, no unbounded fuzzy scan and no automatic inventory mutation. Resolver V2 remains the final contradiction/chronology/review boundary.

## Verification

`test/medicine_extraction_hardening_v32_test.dart` covers shared form aliases, conservative date-label recognition, punctuated manufacturer ownership, legal-company name suppression and an end-to-end no-LLM/no-cloud Resolver V2 pack extraction.
