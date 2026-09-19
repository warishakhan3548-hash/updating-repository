# Daily sales and stock advice

Repository: `warishakhan3548-hash/updating-repository`, branch `main`.
Base: `4faeb6130b5b1ee1d01b594a42eaaa1fc2ab0cdd`.

The previous compact Hindi interface exposed a purchasing calculation with a
minimum order of ten units, confidence based on receipt count, and an expiry
forecast that used a different sales velocity. This change replaces those rules
at their source. It supersedes the purchasing and quiet-stock evidence rules in
`STOCK_GUIDANCE_MEMORY_2026_09_15.md`.

## Architecture and user journey

| Source → consumer | Responsibility and change |
| --- | --- |
| Database → `PharmacyController.snapshot`, sales, civil day | Authoritative records and existing sale/Undo persistence. No new inventory store or background stock mutation. |
| `SaleEvent` snapshots → `dailyDemandByProduct` → `daily_demand.dart` | Aggregate receipts by their original medicine identity and civil day. Reject conflicting composition and impossible dates as forecast evidence. |
| Daily profile + current batches → `stock_projection.dart` | Shared earliest-expiry-first consumption, expected leftovers and usable coverage. |
| Profile + projection → `TrackingStats.reorder` and `PharmacyStockRiskReport` | Current purchase quantity and expiry risk use the same rate and batch allocation. Historical analytics still use their selected date range. |
| Attention findings → existing `PharmacyOperationsPlan` → `StockGuidance` | Keep all live prerequisites. Present a Hindi action, medicine name and short factual reason. Attach structured expiry risk without parsing explanatory paragraphs. |
| Attention/order card → `demand_history_sheet.dart` | Tap to see today, yesterday, 30-day total, weekly comparison and each day's recorded quantity. Cache by snapshot identity and civil day; rebuild from current data after sales or Undo. |
| Order fields → existing PDF service | Refresh untouched quantity/price defaults from current evidence, retain manually edited drafts, and revalidate current selection and blockers before PDF creation. |
| `autopilot_supervisor.dart` worker → home indicator | Carry 30 completed days plus today and future-date anomalies so worker and foreground use the same evidence window. Existing revision/generation guards remain. |

Cards remain lazy and support wrapping and larger text. Opening a detail sheet
does not create another inventory copy; repeated taps are guarded. The sales
category now includes supported sufficient-stock and changing-pace guidance,
alongside low-evidence reminders. Products with existing repair/expiry/order work
keep that work instead of receiving a contradictory stock-pause card.

## Calculation

1. Store 30 completed daily totals plus today's partial count in a bounded
   read-only profile. The displayed rolling 30-day total includes today and the
   preceding 29 days. No recorded sale is not proof of zero actual demand.
2. The forecast window ends yesterday. Its observed span is bounded to 7–30 days;
   no completed positive history means no numerical forecast. Let `u[a]` be
   recorded valid units `a` days ago and `w[a] = 0.5^((a-1)/7)`. Planning pace is
   `sum(w[a] * u[a]) / sum(w[a])`. The finite weights are normalized, so a constant
   daily series stays constant without seeding from a single bulk receipt.
3. Exponentially decreasing weights give recent observations more influence,
   as described in [NIST's exponential smoothing reference](https://www.itl.nist.gov/div898/handbook/pmc/section4/pmc431.htm).
   The seven-day half-life is an explicit application policy, not a fitted or
   universally optimal parameter.
4. Trend compares the most recent seven completed days against the seven before
   them. A supported change of at least 25% gets an up/down label. Insufficient
   coverage, a zero comparison period or suspicious data gets a record/review
   message. Highly variable sales take precedence over a confident trend label.
5. Evidence depends on distinct selling days, observed span and variability,
   never the number of receipts split across a day. Fewer than three selling
   days, less than seven days of history, no recorded sales in the last seven
   completed days, or daily coefficient of variation above 1.5 require review.
   Evidence scores are tiers, not calibrated probabilities. Raw bulk sales are
   retained rather than silently removed from reports.
6. Remaining typical demand today is `max(0, pace - today's recorded units)`.
   Demand for `h` calendar days including today is that remainder plus
   `pace * (h-1)`. Today's sales therefore reduce stock and outstanding demand
   once, while the completed-day pace remains stable.
7. Retain the existing seven-day supply and 30-day stock policy, now shown in
   the detail sheet. Add a variability allowance bounded by one supply window:
   `min(pace * 7, daily standard deviation * sqrt(7))`. It is a heuristic buffer,
   not a guaranteed service level. The shop can edit an order for a different
   supplier lead time; this change does not claim to know that lead time.
8. Allocate expected demand to known, usable batches by expiry, batch and ID.
   Expiry is inclusive. Only consumption allocated to earlier batches is
   subtracted from later demand; leftovers that expire cannot consume future
   demand. Keep fractional expectations internally and round final unit outputs.
9. Trigger a low-stock suggestion when stock minus expected waste inside the
   supply window cannot cover that window plus its allowance. The order is the
   30-day target plus allowance, less stock usable over that target. Remove the
   old minimum-five reorder point, minimum-ten target and historical SOLD-size
   fallback. Unknown demand, count, positive-stock expiry or contradictory facts
   yields no supported numerical order. A stockout still requests manual review.
10. Quantity caps and low evidence require review; orders are not sent or stock
    changed by this calculation. Existing expiry and fact-repair prerequisites
    still apply to numerical suggestions and manually selected rows.

## Concrete examples

These are executable fixtures, not claims about the user's shop history.

| Recorded evidence | Result |
| --- | --- |
| 30 completed days at 2 units/day, no sales yet today, 5 usable units, distant expiry | **55 यूनिट मँगाएँ**; stock covers about 2.5 typical days. |
| Same evidence at 1 unit/day, 5 usable units | **25 यूनिट मँगाएँ**. |
| First case after two normal sales today and stock drops to 3 | Still 55; today's demand is not charged twice. |
| 2/day; 20 units expire in three days and 5 have distant expiry | About 12 units may remain at expiry; order 47 after counting the 13 expected usable units. |
| No usable sales history, including a historical SOLD batch of 5,000 units | Ask for quantity review; no invented ten-unit or 5,000-unit order. |
| Fifty receipts on one day | One selling day; manual review, no high-confidence or expiry-waste forecast. |
| Already expired | **अलग रखें · न बेचें**. |

Near-expiry information is operational stock guidance. The engine does not infer
tablet/strip conversions, prescribe treatment or identify a medicine from demand.
Cloud prompts, scanner code and local-model/provider behavior are unchanged.

## Verification and limits

**325 focused executable checks passed:** 210 daily stock-advice checks, 63 stock
guidance checks and the existing 52 inventory domain contracts. The new checks
cover partial days, receipt splitting, changing pace, sparse/bulk/future and
lifecycle-invalid records, identity corrections, unknown facts, arbitrary report
ranges, prices, quantity caps, expiry boundaries, leap day and task prerequisites.
Eighty seeded batch scenarios compare the cumulative FEFO calculation with an
independent day-by-day stock-consumption simulation, including conservation checks.

```sh
dart tool/check_daily_stock_advice.dart
dart tool/check_stock_guidance.dart
dart tool/check_domain.dart
```

Existing Flutter test fixtures have been updated for intentionally changed
quantity/confidence semantics. Their runner was not executed. Exact attention,
order, history-sheet, design, beacon and supervisor sources also passed a
compiler-only check against the installed Flutter SDK. Controller, editor and
native PDF boundaries were stand-ins; this was not a full application build or
a runtime widget/device check.

No Flutter analyze/test, APK build, live model/provider call or device frame-rate
measurement was run. Forecast logic checks establish arithmetic and invariants;
they do not establish real-shop forecast accuracy. Missing logs, stockout days,
seasonality and actual supplier delivery times remain unobserved. Real accuracy
evaluation needs held-out periods in chronological order, following
[time-series cross-validation](https://otexts.com/fpp3/tscv.html), before claiming
a measured accuracy gain.

## Complete replay script

`tool/apply_daily_stock_advice_upgrade.py` embeds the complete change, including
checks and this document. It verifies affected source hashes, refuses conflicting
edits and symlink paths, validates the whole patch before applying, and verifies
the result. Re-running it on the exact completed upgrade changes nothing.

```sh
python3 tool/apply_daily_stock_advice_upgrade.py --repo /path/to/repository --check
python3 tool/apply_daily_stock_advice_upgrade.py --repo /path/to/repository
```

The replay script does not build, commit, push or contact external services.
