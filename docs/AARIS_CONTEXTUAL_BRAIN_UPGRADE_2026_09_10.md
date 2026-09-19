# Aaris Contextual Brain Upgrade — 2026-09-10

This upgrade extends the existing Aaris Pharmacy architecture rather than creating a second inventory or AI system.

## Safety invariants preserved

- The existing inventory database remains the only authoritative medicine/stock state.
- Aaris Brain never keeps a private copy of stock facts.
- Natural-language commands cannot bypass existing review/confirmation paths.
- Scanner/OCR/local-model output remains evidence and draft data until pharmacist review.
- Bulk removal remains unavailable to the natural-language command surface.
- Expired stock, FEFO, sales, stock correction, receipt and archive rules continue to be enforced by deterministic controller/storage logic.
- No patient/customer identity is added to operational context.
- No local-model failure silently falls through to cloud inference.

## 1. Exact session operational context

`lib/state/operational_context.dart` adds a session-only exact-target context for the existing `PharmacyController`.

The context stores only a medicine/stock record ID. Every read resolves the ID again from the current authoritative inventory snapshot. If that record was removed or no longer exists, the context clears itself and fails closed.

This makes conversational follow-ups such as `isko edit karo`, `same medicine`, or `this one` useful after an exact medicine has been opened or saved elsewhere in the app without caching stale quantities, dates, locations or prices.

The context is intentionally not persisted across process restarts. It is navigation/interaction context, not business data.

## 2. Scanner is now a first-class Brain action

Scanner phrases no longer merely switch to the Medicine Database tab. Aaris Brain launches the existing scanner and then sends captured barcode/OCR evidence into the existing Import Inbox review workflow.

The flow is:

1. User asks Aaris Brain to scan a medicine.
2. Existing camera + barcode + OCR pipeline captures evidence locally.
3. Existing fuzzy inventory search checks for a high-confidence local stock target.
4. A single exact target may become session context only when the same strict confidence gate can isolate it.
5. Import Inbox performs the existing ranked match / draft review flow.
6. Any new or edited stock still requires pharmacist review and the normal inventory write path.

This avoids a parallel scanner database or a hidden AI mutation route.

## 3. Installed Aaris Default AI cold-start recovery

`AiService` now centralizes local-route preflight:

1. initialize the existing local runtime;
2. restore an already-installed Aaris Default AI when no user-selected local model is active;
3. prefer the selected local route;
4. only use a configured cloud provider when no local selection exists.

AI Hub configuration loading warms this route without reading/exporting inventory, and the actual `ask()` call repeats the same preflight at the execution boundary. This means a process restart cannot silently turn a locally configured pharmacy into a cloud request merely because the default model had not yet been reactivated.

## 4. Shared exact selection from medicine editor

The existing `openEditor()` gateway now records an exact active medicine ID as operational context. After a successful save, the saved record remains the current exact context. If the entry is archived, that context is cleared.

Because existing Search, Import, Attention and other surfaces already converge on `openEditor()`, this supplies useful cross-surface conversational continuity without adding wrappers around inventory mutation logic.

## Verification added

- Brain parser tests verify English/Hinglish/Hindi scanner language maps to the dedicated non-destructive scanner action.
- Operational-context tests verify exact-ID storage, live snapshot re-resolution, removal fail-closed behavior and target-specific clearing.

The intended architecture remains:

`UI / Brain / Scanner / AI -> review + exact target resolution -> PharmacyController -> InventoryStorage -> one authoritative inventory snapshot`
