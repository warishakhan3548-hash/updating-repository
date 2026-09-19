# Aaris Brain — deterministic operational routing upgrade

Date: 2026-09-09

This upgrade keeps Aaris Brain local-first and conservative while making common pharmacist language faster and less ambiguous. It does **not** create a second inventory engine, a second scanner, or an AI-only mutation path.

## Design rule

Natural language is only an intent router. The existing Medicine Database, search engine, scanner, Tracking/Calculator, reviewed editor, FEFO rules and inventory controller remain authoritative.

Write-side commands still require exact/high-confidence stock resolution and the existing protected confirmation/editor workflow. Bulk removal remains blocked from natural-language execution.

## New deterministic routing behavior

- Targeted quantity questions such as `Dolo 650 stock kitna hai` now search that medicine instead of incorrectly returning global inventory totals.
- Location questions such as `Dolo kahan hai` route to local stock search so the saved Block / Row / Vertical / location facts remain authoritative.
- Expiry questions such as `Dolo expiry kab hai` route to recorded stock facts instead of asking an LLM to infer a date.
- FEFO questions such as `Dolo pehle kaunsi batch` route to the existing medicine/batch view rather than inventing a separate FEFO decision engine.
- Read-only sales/movement phrases such as `aaj ki bikri kitni`, `sales report`, `fast moving medicines`, and `slow moving stock` route to the existing Calculator/Tracking surface and can never become a sale mutation.
- Scanner phrases route to the Medicine Database surface where the app's existing scanner/OCR/barcode safety gates live.
- Context references now cover more natural Hindi/Hinglish possessives such as `iska`, `iski`, `uska`, `uski`, `इसका`, and `उसकी` while still requiring a previously remembered exact stock record.
- Short-expiry/month-expiry dashboard commands retain their existing scope semantics and are resolved before targeted expiry wording, preventing command collisions.

## Safety invariants preserved

1. One authoritative Medicine Database.
2. No silent destructive action.
3. No bulk deletion from voice/natural language.
4. No medical fact is invented by command parsing.
5. OCR/AI uncertainty does not bypass review.
6. Read-only questions cannot accidentally become write-side sale commands.
7. Existing search confidence and ambiguity handling remain authoritative.
8. Existing inventory revision checks, audit history and Undo remain unchanged.

## Regression coverage

The App Brain contract now explicitly tests targeted-vs-global stock routing, location, expiry, FEFO, analytics/write separation, scanner routing, expiry-card command precedence, and expanded Hindi/Hinglish contextual references.

The protected remove widget test also avoids `pumpAndSettle` while the Brain intentionally displays a busy progress animation behind a modal confirmation. This removes a false CI timeout without weakening the no-mutation-before-confirmation assertion.
