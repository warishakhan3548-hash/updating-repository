# Aaris Brain live analytics and purchase-order cost safety

Date: 2026-09-10

## Why this upgrade exists

Aaris Pharmacy already uses one authoritative local Medicine Database, immutable sale-event snapshots, deterministic FEFO/reorder logic, reviewed stock mutations, and a revision-safe Aaris Brain command firewall. This upgrade closes two remaining pharmacist-workflow gaps without creating a second source of truth.

First, sales and movement questions such as “aaj ki bikri kitni”, “fast moving this week”, “slow moving this month”, and bounded “last N days” requests are now answered directly inside Aaris Brain from the local sale ledger and current inventory projection. The command is read-only; no AI provider is required, no medical inference is made, and no stock mutation path is reachable from the analytics engine.

Second, purchase-order unit cost is no longer auto-filled from an arbitrary first batch. Aaris auto-fills cost only when known active batch prices have one consensus value. If active stock has no saved price, one unambiguous historical SOLD price may be used. Conflicting evidence deliberately returns no suggested unit cost, forcing pharmacist review before the purchase-order PDF can contain that accounting value.

## Safety properties

- Analytics is a deterministic read projection over `TrackingStats`; it never owns a write API.
- Analytics range parsing supports civil-day today, week-to-date, month-to-date, and bounded last-N-day windows, including Devanagari digits.
- Sale/dispense commands still route through the existing reviewed sale and FEFO mutation pipeline; the analytics parser does not recognize those write phrases.
- Missing sale amount stays missing. Aaris reports that uncertainty instead of inventing revenue.
- Fast/slow movement ranking uses recorded sale units only and remains operational inventory intelligence, not clinical advice.
- Conflicting purchase-price evidence becomes an empty cost field with an explicit “Unit cost needs review” cue.
- Undo confirmation now shows the exact newest audited event label, revision, business day/time, while the controller/database revision gate remains authoritative at commit.
- Existing bulk-delete protection, scanner/OCR review, integrity firewall, sale-ledger guard, backup/Undo recovery, and local-first privacy rules are unchanged.

## Verification added

`test/brain_analytics_test.dart` covers read-only Brain routing, English/Hindi/Devanagari time windows, civil week/month ranges, write-vs-read separation, exact sale-ledger summaries, missing-revenue honesty, and purchase-order price consensus/conflict behavior.
