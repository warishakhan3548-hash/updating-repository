# Aaris Brain Intent Firewall & Work Orchestration — 2026-09-10

This upgrade extends the existing Aaris Brain and the one authoritative Medicine Database. It does not add a second inventory, a direct AI write path, a cloud dependency or an automatic destructive executor.

## Human-like command safety before target search

Natural-language inventory writes now pass through a deterministic intent firewall before medicine resolution. Aaris explicitly distinguishes a positive immediate command from three unsafe semantic shapes:

- **Negated write** — `Dolo delete mat karo`, `don't sell Dolo`, `remove nahi karna` do nothing. A negative sentence can never be transformed into a positive action merely because it contains a write verb.
- **Conditional or future write** — `if stock is zero delete Dolo`, `kal sell karna`, `restore later`, or an explicit clock-time write do nothing now. The current app has no background write scheduler, so deferred language is never executed early.
- **Compound write** — `receive 5 then move rack B`, `set quantity then sell`, or `delete or mark sold` is rejected as one command. Aaris will not silently execute only the parser's first matching branch. Each inventory-changing operation must be reviewed independently against the exact live stock state.

Existing safe read questions such as FEFO guidance and stock/expiry/location lookup remain read-only and are not caught by the firewall. Natural-language bulk deletion remains separately blocked by the protected owner flow.

## Better exact conversational context

Exact session context now understands a closed English/Hinglish/Hindi deictic grammar such as `that medicine`, `woh wali medicine`, `us medicine me`, `उस मेडिसिन को`, and `previous one`. Grammar words are removed only from this closed context check; arbitrary medicine names are never accepted by prefix similarity. The context still stores only an exact stock ID plus an identity fingerprint and re-reads quantity, dates, price, status and location from the authoritative live snapshot every time.

Polite positive wording such as `Can you please delete Dolo 650?` is cleaned before medicine search and still enters the same exact-target reviewed Remove path. No confirmation gate is bypassed.

## One dependency-aware “next task” truth

Aaris Brain now understands `next task`, `agla kaam`, and equivalent phrases. The Brain's attention summary no longer calls the flat severity-sorted first finding “next”. It builds the same `PharmacyOperationsPlan` used by Needs Attention and reports the first unblocked task, including ready-vs-blocked counts. This prevents a downstream FEFO or reorder recommendation from being presented ahead of a known physical-fact prerequisite.

## Preserved invariants

- SQLite remains the sole authoritative medicine database.
- No negated, future, conditional or compound natural-language write mutates stock.
- No fuzzy or guessed implicit target is introduced.
- Every positive inventory write still uses the existing review, confirmation, revision/CAS, audit and Undo boundaries.
- AI/OCR output still cannot bypass deterministic validation or pharmacist review.
- No medical facts, patient data, cloud sync or silent destructive automation were added.
