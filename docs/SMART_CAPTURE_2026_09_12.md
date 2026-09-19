# Smart capture: bounded inference and faithful OCR evidence

Scope: pharmacist scan/photo → offline understanding → optional selected Local
AI or explicitly selected cloud extraction → validated fields → existing review,
duplicate/lot/revision gates → inventory. No new database, backend, provider,
trained model, permissions, dependency or automatic stock-quantity rule.

## Architecture / UI-state intersection

| Entry / state | Core path | Changed behavior |
| --- | --- | --- |
| Live camera → preview | `ScannerScreen` → `CaptureQuality` + `MedicineVisionService` → Resolver V2 | At most 1024 sampled pixels with row/pixel-stride checks; light/glare/focus guidance. OCR continues even on low/unknown quality. |
| Photo / captured still / explicit cloud photo | `analyzeFile` / `qualityPath` → Android `photoMetrics` alongside OCR | Bounds-first subsampling to about 512px, private paths only, one optional metric decode at a time, two-second advisory timeout. Original full-resolution OCR image is not altered. |
| Latin + Devanagari OCR → offline fields | `mergeMedicineOcrLines` → existing semantic/date/conflict resolver | Only case/whitespace-equivalent lines deduplicate. Different numbers, punctuation, units and labels survive; no evidence-priority line reordering. |
| Optional AI → proposed fields | `LocalScanEvidence` → schema-13 `LocalScanHandoff` → quote validator | Compact policy and bounded hints; heading, composition and traceability spans selected in original order without cutting lines or forging adjacency. |
| Small local context → retry or review | `runLocalScanTurn` → existing exclusive `LocalAiRuntime` lease | Exact native counts first reduce output reserve if viable, then reduce evidence. At most four admission attempts, skipping identical intermediate prompts. |
| Preview → save → UI refresh | Existing commit policy → `PharmacyController` → atomic SQLite revision | Unchanged. Conflicts are not stock-write authority; no inferred quantities, dates or batch identity from old lots. |

## Root causes removed

1. The old scan system prompt contained repeated policy and the user payload
   repeated much of it again. Character-based evidence limits did not include
   all this overhead, and scan inference had no token-admission recovery.
   The system prompt is now 2,117 versus 6,201 characters (66% smaller by
   character count; this is not a tokenizer count or a measured speed gain).
2. A single middle OCR substring could omit a distant trade heading or MFG/EXP
   region, and could cut a dose denominator at its boundary. Selection now
   keeps complete lines and explicit source offsets. Each quote must be inside
   one transmitted span. Combination ingredients must share one contiguous span
   and retain printed order, units, decimals and denominators.
3. Fuzzy OCR deduplication could erase `650 mg` versus `850 mg` on otherwise
   almost identical composition lines. These readings now both reach the offline
   conflict resolver. The old priority-reordering and fuzzy-merge implementation
   were removed rather than overridden.
4. A field-only AI salt proposal could promote any quoted brand word when the
   original strength was empty. New salt/strength changes now require adjacent
   ingredient evidence in both cases. Unchanged deterministic fields remain.
5. Still photos and live frames previously defaulted to quality `1`. Actual
   measurements now feed the existing evidence-weighting path; unavailable
   measurements use `.65`, not perfect quality. This is an advisory heuristic,
   not a calibrated confidence or medical-accuracy probability.

## Token and failure semantics

Every scan is independent; no previous scan/chat is appended. Native KV reset,
model loading, memory-pressure handling and command-drain ownership remain in
the existing runtime. No model unload/reload is introduced for context overflow.

Only `LocalContextBudgetFailure`, emitted before inference with actual native
input/output/context counts, triggers scan re-budgeting. Output reserve uses
remaining context minus 32 tokens with a minimum viable reserve. Source shrinking
is a coarse selection step; the next native admission remains authoritative for
the tokenizer. Intermediate budgets that do not reduce the payload do not cause
another native call. Every final answer is validated against that attempt's
evidence selection, never an earlier larger window.

Cancellation/route changes are checked before admission, after status callbacks,
after generation and before retry. Malformed/truncated JSON, invented quotes and
transport failures are not mislabeled as token errors. An impossible safe fit
requests a closer single-pack crop and leaves the original deterministic draft
for review; the model selection is retained. The existing separate transport
recovery may still retire a genuinely failed native runtime.

Both local and explicit-cloud scanning use the same smaller schema-13 handoff and
validator. Cloud endpoint/auth/retry ownership is unchanged; ordinary scans do
not implicitly upload OCR because an API key happens to exist. No cloud provider
credentials or inventory data were used in this work.

## Local verification (no CI or APK)

Executed with the existing Dart 3.13.2 SDK:

| Standalone check | Passed |
| --- | ---: |
| `check_scan_capture.dart` | 43 |
| `check_offline_capture_context.dart` | 52 |
| `check_medicine_understanding.dart` | 24 |
| `check_domain.dart` | 52 |
| `check_date_input.dart` | 25 |
| `check_local_ai.dart` | 70 |
| `check_model_preflight.dart` | 140 |
| `check_model_catalogue.dart` | 24 |
| Total counted contracts | 430 |

`check_default_local_ai.dart` policy checks also passed. Targeted Dart analysis
of all domain files, chat/scan turn orchestration and the new pure contract
reported no issues. Formatting and `git diff --check` passed.

The new shared contract covers a 40-fixture × 7-budget span matrix, complete-line
and Unicode boundaries, late composition/dates, false brand→salt, denominator
loss, separated ingredient panels, no-model conflicting doses, exact context
recovery, cancellation, 32 independent sequential scan calls, stride/padding/
BGRA buffer safety and non-finite quality inputs. These are synthetic contracts,
not a measured medicine-recognition accuracy percentage or GGUF speed benchmark.

The Flutter wrapper is included for future normal test runs. Full Flutter tests,
full application analysis and native compilation were not executed: pinned app
packages are absent from the local dependency cache. No dependencies were
changed to bypass this limitation. No CI run was requested or inspected, no APK
was built, and existing workflow definitions were not edited. This delivery's
commit uses `[skip ci]`, as explicitly requested by the owner.

Still unverified on hardware: real camera/photo quality thresholds, Android
decoder/channel behavior, the owner's exact Gemma GGUF/tokenizer, thermal/RAM
behavior and authenticated cloud endpoints. A labelled real-pack corpus and
physical-device profiling are required before claiming accuracy/speed gains or
introducing a different mobile inference backend. Unreadable or ambiguous packs
still require pharmacist review.

## Primary references

- [ML Kit text recognition](https://developers.google.com/ml-kit/vision/text-recognition/v2/android): image resolution/focus and bounded frame processing matter; this patch keeps original-image OCR and the existing single-frame lease.
- [Android bitmap loading](https://developer.android.com/topic/performance/graphics/load-bitmap): bounds-first subsampled decode prevents loading a full photograph solely for an advisory metric.
- [GitHub workflow skips](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/skip-workflow-runs): `[skip ci]` applies to push/pull-request workflows, not arbitrary trigger types. Repository workflow triggers were inspected: main checks/release use push/PR/manual; historical one-shot patch workflows use path-filtered push. No workflow file changes or manual run is invoked.
