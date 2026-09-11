# Aaris Medicine Resolver V2 — product-first offline recognition

This document is the implementation contract for the scanner intelligence upgrade added on 11 September 2026. It extends, rather than replaces, the existing deterministic OCR parser.

## Non-negotiable invariant

The scanner must resolve **one coherent product identity before canonical identity fields may be inherited**. Brand, salt, strength, form and manufacturer are not allowed to become an impossible hybrid assembled from different product variants.

When evidence is insufficient or contradictory, the resolver abstains and leaves the draft in review. A confident wrong mutation is considered worse than `UNKNOWN`.

## Runtime path

```text
Camera / photo / video
  -> ML Kit OCR + barcode + layout evidence
  -> durable MedicineIntake queue
  -> deterministic MedicineUnderstandingEngine
  -> GS1 traceability authority
  -> Tier-1 shop + Tier-2 canonical candidate retrieval
  -> product hypothesis scoring
  -> contradiction / margin / evidence-diversity gate
  -> coherent draft
  -> optional Local AI refinement
  -> existing IntakeResolution
  -> existing pharmacist-confirmed commit boundary
```

The Local/Cloud LLM path is not required for baseline recognition and does not become inventory authority.

## Two-tier knowledge

### Tier 1 — pharmacist-reviewed shop memory

The existing active-stock identity snapshot remains bounded to 12,000 entries. It is the strongest shop-specific prior and is rebuilt from authoritative local inventory, excluding operational facts that must never be copied during recognition.

### Tier 2 — versioned canonical product catalogue

`CanonicalMedicineCatalogService` owns a separate identity-only SQLite database. This is knowledge, not inventory. It can scale independently of the Medicine Database and stores stable `product_id`, monotonic revision, brand/name, salt, strength, form, manufacturer, aliases, OCR aliases and product barcodes.

It never stores stock quantity, pharmacy price/cost, location, batch, MFG or EXP.

The catalogue may be empty. An empty/unavailable catalogue must never stop scanning.

## Candidate retrieval

The full master catalogue is never loaded into Dart memory. Each scan retrieves a bounded candidate set using:

1. canonical barcode/GTIN exact matches;
2. weighted exact identity terms;
3. OCR-folded terms (`0/O`, `1/I/l`, `5/S`, `8/B`, `2/Z` only in bounded contexts);
4. precomputed one-delete keys (SymSpell-style candidate generation).

The candidate generator is not the final judge. Product hypotheses are re-ranked by cross-field evidence.

## Product hypothesis arbitration

Each candidate is scored from independent evidence channels:

- exact product barcode / GS1 GTIN;
- brand/name similarity using weighted OCR edit costs;
- salt compatibility;
- exact normalized strength compatibility;
- dosage-form compatibility;
- manufacturer compatibility;
- bounded shop prior.

Strong disagreements are hard conflicts, not small negative weights. A high aggregate score cannot override a trusted contradictory strength/form/salt or a conflicting known barcode.

A non-barcode product lock requires a calibrated absolute score, at least two independent evidence channels, a safe winner/runner-up margin and zero hard conflicts. Close product variants remain unresolved.

## GS1 authority

Validated GS1 healthcare payloads are interpreted before product arbitration:

- AI (01) -> canonical GTIN;
- AI (10) -> batch/lot;
- AI (11) -> manufacturing date;
- AI (17) -> expiry;
- AI (21) remains traceability evidence but is not inventory identity.

Structured GS1 facts outrank lower-confidence OCR guesses. Multiple contradictory GS1 payloads fail closed.

## Versioned delta ingestion

The master catalogue supports an append-only JSONL delta bundle. Every operation carries a globally increasing `rev` and stable `product_id`.

Example:

```json
{"op":"upsert","product_id":"in:dolo:650:tablet","rev":481,"brand":"Dolo","salt":"Paracetamol","strength":"650 mg","form":"Tablet","aliases_ocr":["D0L0","DOL0"],"verified":true}
```

Before apply, the complete bytes must match an expected SHA-256. Operations are validated and applied in one SQLite transaction. Any parse/validation/database failure rolls back the complete delta. `last_applied_revision` advances only after a successful transaction.

The service intentionally performs **no automatic network fetch**. A future owner-approved updater may acquire a signed manifest/delta over the network, but inference and scanning remain fully offline. A remote auto-updater must add authenticity verification (for example a pinned public-key signature), not rely on SHA-256 fetched from the same untrusted origin.

## Safety boundary

GREEN means safe identity prefill, never silent inventory save. Existing `medicine_scan_commit.dart`, revision/CAS, preview and pharmacist confirmation remain authoritative.

No visual model, NER model or LLM is treated as product authority by this upgrade. Future visual fingerprints and pharmacy-labelled NER can be added as bounded evidence channels after calibration without changing the product-first contract.
