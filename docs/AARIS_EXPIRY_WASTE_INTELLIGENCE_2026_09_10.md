# Aaris Expiry-Waste Intelligence — 2026-09-10

Aaris now has a local, deterministic **expiry-waste pressure** engine inside the existing Needs Attention workflow.

## What it does

For each medicine identity, Aaris orders known positive stock by FEFO, combines the cumulative units that must move before each batch expiry, and compares that stock with recorded sales movement. The planning pace uses the faster of the observed-period and recent-seven-day velocity so a new or accelerating sales history is not diluted across an artificial 30-day denominator.

When the saved facts indicate that a meaningful portion of a batch may remain by expiry, the exact batch is surfaced in Needs Attention with its estimated at-risk units, evidence quality, current planning pace and physical stock cue.

## Safety design

- This is operational inventory forecasting, not medical advice.
- It never invents demand, dose, indication or medicine facts.
- It requires at least two recorded sale events for the product.
- A product with any unknown active quantity or expiry is excluded from the forecast; the existing missing-fact warnings remain authoritative instead.
- Recent demand is allowed to increase the planning pace, reducing false waste alarms when movement is accelerating.
- The expiry date is inclusive and FEFO cumulative stock is respected across batches.
- The risk horizon follows the pharmacist's configured month-expiry window.
- The engine is read-only. It cannot edit stock, sell, archive, merge batches or create/cancel purchase orders.

The result is a proactive queue that tells the pharmacist *where expiry loss may be forming* without turning an estimate into an automatic mutation.
