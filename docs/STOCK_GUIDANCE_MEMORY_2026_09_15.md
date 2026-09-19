# Stock guidance and recognition memory upgrade

Repository: `warishakhan3548-hash/updating-repository`, `main`.
Base: `2f91f3b7f17111c435f30f14f645d6cbe88397a7`.

The supplied screenshots showed the Needs attention page spending most of its
space on internal operational terminology and repeated paragraphs. This upgrade
keeps the existing stock planner and changes how its work reaches the pharmacist.

## Architecture and intervention points

| Path | Existing responsibility | Intervention |
| --- | --- | --- |
| `lib/data/inventory_database.dart` → `lib/state/pharmacy_controller.dart` | Authoritative local snapshot, sales and stock mutations | Unchanged; UI derives its work from the live snapshot and civil day. |
| `lib/domain/tracking.dart` → `attention.dart` → `operations_plan.dart` | Recorded movement, expiry/fact findings, prerequisite ordering | Expose the existing movement identity-conflict finding so a quiet-stock hint cannot use another ingredient's sales. Planner and purchasing calculations remain authoritative. |
| `lib/domain/stock_guidance.dart` | New presentation projection | Short Hindi action, medicine title and one factual reason. No clinical inference, unit conversion or automatic inventory mutation. |
| `lib/ui/attention_screen.dart` | Work list → stock editor/order screen | Replace eager paragraph cards with lazy compact rows, category chips and snapshot/day memoization. Resolve live prerequisites before opening; prevent repeated taps from stacking routes. |
| `lib/ui/order_screen.dart` | Quantity review → purchase-order PDF service | Cache derived work, allocate input controllers only for visible rows, retain drafts, remove per-keystroke screen rebuilds. Recheck selection before sharing and do not silently add newly discovered suggestions at that boundary. |
| `lib/ui/autopilot_beacon.dart` | Home work-queue entry point | Short Hindi signal consistent with the destination. |
| `medicine_review_pipeline.dart` / `medicine_intake_service.dart` → `offline_recognition_memory_service.dart` → medicine resolver | OCR frames, current shop knowledge and confirmed correction aliases | Preserve full strength semantics, check each alias-bearing frame, and require an unambiguous current variant before applying a remembered correction. |
| Confirmed review/editor save → recognition memory | Learn after a user-confirmed inventory save | Existing learning entry points and bounded private storage remain in place. |

The user journey is: tap a compact task → refresh from the live stock snapshot →
open its first outstanding fact, exact stock row or focused order item → save or
return → the list updates from the same database. No second inventory is created.

## User-facing behavior

- Missing expiry: **Expiry जोड़ें**; medicine/strength plus the recorded quantity.
- Missing quantity: **स्टॉक गिनें**. Unknown quantity never becomes zero.
- Supported order: **10 यूनिट मँगाएँ**, using the actual suggested quantity.
- Incomplete facts: **पहले Expiry जोड़ें** or the corresponding first fact.
- Expired stock: **अलग रखें · न बेचें**.
- Quiet stock: show the actual period and recorded sales. **अभी और न मँगाएँ**
  requires at least three recorded sale events and at least 30 days of stock at
  that recorded pace. Zero/unlogged sales only prompt a review. Conflicting
  identities, unknown expiry/quantity and existing repair/order tasks suppress
  conflicting quiet-stock advice.

Rows keep their full medicine title, support wrapping and do not use a fixed
height that would clip large text. The original high-elevation cards and verbose
operating-plan header are removed from these screens. Order quantity and price
inputs fit the available width. A blocked order can open its stock information
for review directly.

## Recognition corrections

The previous policy returned a sole saved candidate without checking the current
strength or form. It also flattened concentrations during comparison and combined
matches across alias-bearing frames. The new policy:

1. Checks the current evidence even when only one candidate exists.
2. Preserves `/`, `%`, `+` and microgram spelling through the existing shared
   strength grammar; bottle volume is not treated as ingredient strength.
3. Requires compatibility in every frame where the alias occurs. Evidence from
   other medicines cannot provide a missing strength/form/barcode witness.
4. Leaves conflicting confirmed identities unresolved; frequency cannot choose
   a medicine when the current capture remains ambiguous.
5. Applies the same contradiction check before activating a salt correction.
6. Hashes Unicode with UTF-8. Ordinary Latin identity keys stay compatible;
   legacy keys that lost concentration punctuation are not guessed into a new
   variant. A subsequent confirmed correction can teach the precise key.

The 16,000-alias/32,000-receipt bounds, collision completeness checks, private
storage and failure fallback remain. This is a correction-memory improvement,
not model training or a measured real-world medicine-recognition accuracy claim.

## Verification

**314 executable checks passed:**

| Check | Passed |
| --- | ---: |
| New stock-guidance scenarios | 63 |
| New recognition-memory policy scenarios | 26 |
| Existing inventory domain contract | 52 |
| Existing medicine understanding | 24 |
| Existing scan accuracy fixtures | 54 |
| Existing date input | 25 |
| Existing local-AI protocol contract | 70 |

The previous commit reproduces the sole-candidate/wrong-strength defect using the
new recognition fixture; the revised service passes it. Recognition checks execute
the actual service policy with native import declarations isolated for the Dart
VM; they do not claim to exercise SQLite or device plugins.

The changed stock screens, home beacon and existing design components compile
against the actual local Flutter SDK. That focused compilation uses stand-ins at
controller, supervisor, editor navigation and PDF/platform boundaries; it is not
a full application build or a runtime UI test. Source copies were checked against
the repository files.

Cloud prompts, the local-AI protocol file, cloud scan service and provider adapter
are byte-for-byte unchanged from the base. Whitespace checks and Dart syntax
formatting passed. No Flutter analyze, Flutter test, APK build, live model/provider
call or physical-device frame-rate measurement was run. Device smoothness and
real-world scan accuracy still require device/capture evaluation.

## Complete replay script

`tool/apply_stock_guidance_upgrade.py` contains the entire patch. It checks each
affected source hash before writing, refuses conflicting files and symlinks, and
is idempotent. It does not build, commit, push, contact a provider or run CI.

```sh
python3 tool/apply_stock_guidance_upgrade.py --repo /path/to/repository --check
python3 tool/apply_stock_guidance_upgrade.py --repo /path/to/repository
```
