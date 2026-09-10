# Aaris Brain Control Plane Upgrade — 2026-09-10

This pass extends the existing Aaris Pharmacy architecture instead of creating a
second automation engine. SQLite and `PharmacyController` remain authoritative.

## Reviewed expiry-policy control

Aaris Brain can now understand explicit policy commands such as `short expiry
warning 10 days set karo` and a combined `10 days / 3 months` request. Values
must carry an explicit day/month unit; medicine strengths and ordinary expiry
questions cannot become settings. Hindi/Devanagari digits are normalized locally.

The same deterministic intent firewall runs before routing, so negated, deferred
or compound inventory + policy instructions fail closed. A proposed policy is
validated by `WarningSettings`, shown as current → new values, and requires an
explicit confirmation. The review is bound to the exact inventory revision;
stale confirmation cannot overwrite newer state. The accepted mutation is
atomic, audited and Undo-compatible. No medicine facts are edited.

## Deterministic activity brief

`what changed today`, `recent activity`, Hinglish and Hindi variants read the
existing bounded local audit ledger directly. Aaris reports saved event labels
and marks undone operations; it does not send history to a model or invent an
event when none exists.

## Why this matters

The Brain now controls an important app-level policy and can answer operational
history questions through the same local control center that already handles
search, scan, FEFO sale review, receiving, correction, relocation, removal,
restore, SOLD, reorder and attention routing. This improves pharmacist automation
without granting AI a hidden write path.
