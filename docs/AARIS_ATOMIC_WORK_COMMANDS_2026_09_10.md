# Aaris Brain atomic pharmacist work commands — 10 September 2026

This upgrade removes a real workflow tax without weakening the pharmacy safety
boundary. A pharmacist can now express one tightly-scoped sequential job such as
`Dolo 650 stock add 5 units then location Rack C set karo`. Aaris does not run
two independent writes. It resolves one exact physical row, computes the before
and after stock/location facts, shows one explicit review, then commits both in
one serialized SQLite mutation. Undo restores the pair together.

## Safety envelope

- Supported composition is deliberately limited to exactly one receive/exact-count
  adjustment plus exactly one physical-location update. It is not a general macro
  or autonomous scripting language.
- Each clause goes through the existing deterministic intent parser. Negation,
  conditional/future language, incomplete quantities and unsafe intents cannot be
  promoted into the atomic path.
- `or/either/ya`, destructive lifecycle actions and more than two clauses are not
  eligible. The ordinary compound-command firewall remains authoritative.
- If both clauses name a medicine, their normalized exact target wording must
  agree. Otherwise the composite route is rejected. One clause may use the exact
  session context only under the existing fingerprint rules.
- Fuzzy search never gains mutation authority. Ambiguous rows still enter the
  revision-bound candidate chooser, and the final action uses the selected exact
  stock ID.
- The reviewed token is bound to the row revision and all quantity/location facts.
  Unrelated inventory activity may continue, but any target-row change forces a
  fresh review. The persistence compare-and-swap remains the final authority.
- Receiving a previously SOLD row explicitly reopens current stock while retaining
  historical sale events. Exact correction to zero still does not invent a SOLD
  lifecycle or a sale event.

## Temporal intent hardening

A previous conservative date detector treated every calendar-looking token inside
a write command as a future schedule. That safely blocked bad automation but also
blocked legitimate exact stock targeting by printed dates. The detector now grants
one narrow exception only when a date is immediately labelled as EXP/expiry,
MFG/MFD or manufacturing date. Scheduling prefixes invalidate the exception.
Therefore `remove Dolo EXP 12/09/2026` can proceed to exact-row review, while
`remove Dolo on 12/09/2026`, `remove Dolo 12/09/2026` and
`remove Dolo on expiry 12/09/2026` still fail closed. Clock-time and relative-time
guards are unchanged.

## Verification contract

Dedicated tests cover parser admission/rejection, target mismatch, alternatives,
future/negative clauses, atomic commit + Undo, unrelated-write rebasing, stale-row
rejection, SOLD recovery with preserved sales, no silent SOLD/sale creation, and
calendar-date firewall boundaries. The upgrade workflow also runs full static
analysis, the complete Flutter regression suite and a debug Android compile before
the temporary upgrade machinery removes itself.
