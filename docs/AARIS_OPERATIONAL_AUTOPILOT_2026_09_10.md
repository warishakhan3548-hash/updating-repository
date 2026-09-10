# Aaris Brain — Deterministic Operational Autopilot (2026-09-10)

This upgrade makes Aaris Brain behave more like a pharmacist work coordinator
without turning AI into an inventory authority.

## What changed

- `next task`, `next safe task`, `start next task`, `start work`, Hindi/Hinglish
  variants and the existing quick action all use the same deterministic route.
- The next task is selected from `PharmacyOperationsPlan`, which already orders
  safety and fact-verification prerequisites ahead of dependent FEFO/reorder work.
- Immediately before navigation, Aaris rebuilds the live attention report and
  requires the exact task key to still exist and remain unblocked. Concurrent
  inventory changes therefore invalidate stale recommendations.
- A single expired stock row routes directly to the existing Expired removal
  review with the exact stock ID and `Expired` reason already identified from the
  deterministic date engine. The pharmacist still must explicitly confirm; no
  archive occurs from the command alone.
- Other exact-row verification/location/quantity/FEFO work opens the existing
  authoritative medicine editor without guessing missing values.
- Multi-row conflicts and grouped readiness findings open Needs Attention for an
  explicit physical-row choice rather than guessing. Reorder work opens the
  existing reviewed Order Review surface.
- When the workflow closes, Aaris recomputes the queue from authoritative current
  state and reports whether the attempted task is still pending, resolved, or has
  been replaced by another safe task.

## Safety properties

There is still one Medicine Database and one mutation gateway. The autopilot is a
router only: it does not write SQL, invent medicine facts, trust uncertain OCR/AI,
mark a task complete by UI navigation, or bypass explicit review. Existing
revision checks, stale-review rejection, atomic commits, audit history and Undo
remain intact.

## Regression coverage

Parser tests prove new autopilot phrases remain non-mutating intents. A widget
regression proves an expired-stock `next task` opens the protected review directly
while database revision and archive state remain unchanged until confirmation.
