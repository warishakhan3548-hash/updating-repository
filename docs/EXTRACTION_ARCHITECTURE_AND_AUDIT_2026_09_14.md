# Extraction architecture and engineering audit — 14 September 2026

Repository: warishakhan3548-hash/updating-repository  
Inspected base: 4d0e075d771dd1452ab4ec03ecb8ba7733f44ecd

This is a complete structural map of the inspected Git tree and every direct
Dart import/export/part dependency under lib/. All 119 application Dart files
and both Android Kotlin bridges were retrieved from that exact revision.
Detailed behavioral review focused on acquisition, medicine extraction,
semantic/date reasoning, review/commit gates and intake/scanner lifecycle.
This does not claim an exhaustive proof of every repository function.

## Product and execution skeleton

| Layer | Entry points / ownership | Output and dependants |
| --- | --- | --- |
| Startup | main.dart: main → PharmacyBootstrap → PharmacyController.initialize | SqliteInventoryStorage load → PharmacyApp; failed loading exposes retry without replacing inventory |
| Shell | app.dart: _Shell with retained visited tabs | Home, Stock/search, Brain, tracking and Profile; controller notifications refresh derived views |
| Camera | scanner_screen.dart: _restartCamera → _start → _recognize / _captureStill | Immutable frame, generation-bound result, bounded capture evidence and scanner guidance |
| Native vision | scan_service.dart: MedicineVisionService.analyze | Concurrent Latin OCR, Devanagari OCR and barcode tasks for one admitted frame; geometry and physical image quality retained |
| Media | MediaImportService → MainActivity.kt document channel | Local picker, bounded video windows/frames and cleanup; native PDF operations are separate |
| Durable intake | MedicineIntakeService.addFile / addEvidence → _pump | Private source copy, jobs, OCR checkpoint, cursor, completed drafts and unresolved video carry |
| Review preparation | MedicineReviewPipeline.prepare → _prepareLocal / _prepareCloud | Bounded records/knowledge/catalogue snapshot and compute(understandMedicineEvidenceV2Message); optional model verification |
| Evidence normalization | medicine_evidence_normalization.dart and medicine_ocr_text.dart | Geometry fallback, Unicode/script digits, explicit roles and bounded unit/confusion repair |
| Baseline extraction | MedicineUnderstandingEngine.understand → _prepare → _extractCandidates → _fuse | Candidate fields, temporal medicine groups, source sequences, confidence and source text |
| Reconciliation | MedicineProductResolverV2.reconcile | Spatial traceability → regulatory traceability → date intelligence → semantic roles → product hypotheses |
| Identity knowledge | Shop identity snapshot, correction memory, bounded catalogue candidates | Name/brand/salt/form/strength/manufacturer candidates; no authority to invent stock facts |
| Review UI | MedicineReviewScreen._loadSource → _prepareMatches → _next | Existing-stock match, guarded one-tap add, receive-stock path or editor review |
| Authoritative writes | medicine_scan_commit.dart guards → PharmacyController.save/_commit | Expected revision → serialized InventoryStorage transaction → new snapshot → reactive projections |

MedicineProductResolverV2 reuses the original baseline engine; it is not a second
inventory system. Dates and physical lot facts remain observed evidence.
Product-level canonicalization cannot overwrite fields marked conflicted.

## UI and state map

| User action | State and asynchronous work | Visible result / write boundary |
| --- | --- | --- |
| Open camera | Scanner generation created, camera initialized; one OCR lease per frame | Preview and capture guidance; old callbacks rejected after pause/exit |
| Capture a photo | Still capture and OCR drain as part of the camera lease | Evidence handed to review or copied into the durable capture queue |
| Rapid capture / upload photo | addFile persists source and job; _photoStep checkpoints OCR before source cleanup | Intake card advances to review or optional reasoning |
| Upload video | _videoStep samples one window, OCRs selected frames, computes grouped drafts | Completed drafts + carry + cursor persist together; next window resumes remaining evidence |
| Paste/import text | medicineListEvidence supplies explicit item boundaries | Each bounded item reaches the shared review pipeline |
| Open review | _sourceGeneration and _matchGeneration reject stale asynchronous results | Prepared fields and current inventory matches displayed |
| Next | Live resolution and scanQuickAddDecision recomputed | Exact stock action or editor; uncertain identity/composition cannot one-tap save |
| Auto-save eligible scan | scanAutoSaveDecision additionally requires the configured verifier and all domain gates | Authoritative controller save, then advance; deterministic conflict stays blocking |
| Save in editor | Form validation, duplicate/revision review and controller transaction | Local stock saved; Home/Stock/expiry/tracking update from the same snapshot |
| Cancel/leave/pause | Generation invalidation and recognizer drain, intake worker barriers and model ownership checks | Stale scan/review work cannot own a replacement session |

## Persisted state and dependencies

There is one authoritative medicine stock database. The implementation also has
auxiliary local stores for resumable work and recognition knowledge; these do not
own inventory quantities, expiry buckets or dashboard medicine copies.

| Store | Owner | Purpose |
| --- | --- | --- |
| aaris_pharmacy_v1.db | SqliteInventoryStorage | Authoritative medicines, revisions, settings, sales, events and undo/version facts |
| jobs.db in intake support directory | MedicineIntakeService | Durable capture jobs, OCR evidence, drafts and video cursors |
| aaris_medicine_catalog.db | CanonicalMedicineCatalogService | Optional bounded identity catalogue |
| aaris_offline_recognition_memory.db | OfflineRecognitionMemoryService | Pharmacist-confirmed, field-scoped recognition corrections |
| OS secure storage | AiService | Provider credentials, excluded from inventory exports |

The manifest pins Flutter/Dart compatibility, SQLite, camera/Camera2, ML Kit
text/barcode recognition, speech, HTTP, secure storage, sharing, picker/path
support and crypto. Local inference uses the vendored lib_llama_cpp package and
Android local-AI bridge. This change adds no package, model, server or migration.

## Surgical findings and changes

### Named full dates were silently shortened

The shared parser lacked MONTH DAY FOUR-DIGIT-YEAR syntax. Its later partial
patterns could reinterpret the day as a two-digit year.

| OCR | Previous grammar result | Repaired grammar result |
| --- | --- | --- |
| EXP APR 30, 2028 | 2030-04 | 2028-04-30 |
| MFG January 5 2026 | 2026-05 | 2026-01-05 |
| EXP फरवरी २९, २०२८ | 2029-02 | 2028-02-29 |
| EXP APR 31, 2028 | 2031-04 | Rejected |
| EXP FEB 29, 2027 | 2029-02 | Rejected |

medicine_date_parser.dart now reserves and validates the complete named full
date before any month-only fallback. Existing day-first, year-first, compact
numeric and month-only grammar remains in the same function. Four digits are
required for the new year position to avoid introducing ambiguous numeric order.

### Geometry sort violated ordering requirements

medicine_semantic_roles.dart mixed pairwise row tolerance and horizontal order
inside a sort comparator. With points (left, top) = (100, 0), (50, 5), (0, 10),
all height 10, its comparisons formed a cycle. Six permutations produced three
different sorted orders in the source-derived probe.

The original comparator now uses a total spatial/text/dimension order. The
original reading-order builder separately groups rows against a fixed anchor
and sorts each row horizontally. Row tolerance cannot chain through neighbours.

### Equal text was being mistaken for equal physical evidence

The semantic reading stream globally deduplicated normalized text. Two different
ingredients followed by separate identical "5 mg" rows therefore lost a dose.
Repeated semantic labels could also lose their positional meaning.

The semantic builder now preserves distinct physical occurrences, suppresses
exact duplicate observations of the same location, and accounts for how many
raw lines the layout already represents. The resolver's raw normalizer also
retains repeated raw lines rather than deleting them before semantic reasoning.
Both streams retain their existing input/output limits.

### One frame could hide dose conflicts or inflate confidence

Per-frame ingredient collection used an ingredient-only key. A second dose for
the same ingredient could overwrite/disappear before cross-frame conflict logic.
Text observed by multiple semantic rules could also increment independent support
more than once within one physical frame.

Ingredient collection now deduplicates ingredient-plus-dose pairs. Conflicting
doses reach the existing ingredient conflict logic. Brand/generic support is
counted at most once per key per independent frame, retaining the highest
observed rule confidence.

A separate compositionConflicted result survives semantic abstention.
The existing resolver marks salt/strength for review, including empty fields, so
later catalogue inheritance cannot fill over a known source contradiction.
Independent clean brand identity remains usable. Conflict-only semantic results
are no longer discarded by isEmpty.

### Date tokenization repeated work on every frame

Bare compact-pair detection, date role assignment and adjacent-date checks
previously reparsed overlapping bounded lines. Date intelligence now computes
one match list per line and shares it within that frame's reasoning pass.
The unused reparsing helper was removed. This is a structural work reduction;
device latency and memory have not been benchmarked.

## Ripple effects and limits

| Changed origin | Downstream effect | Preserved boundary |
| --- | --- | --- |
| Shared date parser | Baseline dates, spatial dates, date intelligence and manual date parsing read full named dates consistently | Calendar validation and MFG/EXP roles remain separate |
| Semantic layout/voting | Camera, imported layout and raw OCR retain ingredient/dose ownership | Bounded inputs; duplicate frames do not become independent votes |
| Resolver normalization/conflict transfer | Review sees missing/contradictory composition as unresolved | Existing one-tap guards and catalogue conflict checks stay authoritative |
| Date match reuse | Fewer repeated parser calls per line | Same spans, adjacency rules, chronology and field confidence thresholds |

Existing scanner generation/lease checks, drain-before-close, intake work barriers,
atomic checkpoints and controller revision checks were traced and retained.
This pass found no evidence requiring their replacement. Hardware timing, native
camera behavior and process-death recovery were not executed in this environment.

The engine remains evidence based. A missing label can be recovered from reliable
layout, paired doses, explicit adjacent roles or supported local knowledge.
Ambiguous medicine identity or conflicting physical facts still require review.
A future upgrade should first collect a pharmacist-labelled OCR/layout corpus
and measure field precision, recall, abstention and device latency before changing
confidence calibration or adding trained weights. No clinical fact should be
filled merely to maximize extraction rate.

## Verification and reproducibility

- Complete non-truncated base tree: 372 tracked files.
- All 119 application Dart source files retrieved; 436 local import/export/part
  directives resolve to existing files. Both Kotlin bridges were also retrieved.
- All five changed source preimages independently match Git blob SHA-1 from the
  pinned base tree.
- Fifteen source-derived ECMAScript date grammar probes passed; six demonstrated
  repaired failures and the remaining nine checked valid/invalid existing forms.
  These execute the parser's extracted regular-expression patterns with a small
  calendar harness; they are not Dart VM tests.
- Source-derived comparator probes confirmed the old cycle and stable sorting in
  all six input permutations after repair.
- Patch-manifest replay checks: original source changes five files; already-fixed
  source changes none; mixed before/after source repairs only pending files;
  divergent source is rejected.
- Twelve focused Dart regression tests were added in
  ../test/medicine_extraction_evidence_integrity_test.dart. They cover dates,
  repeated-dose ownership, ordering, independent support and source-conflict
  propagation through the resolver and one-tap boundary.
- No Dart/Flutter runtime or local shell is exposed by the editing environment.
  The new Dart tests and the Python script were therefore not executed here.
  Flutter analyze/test, APK builds and workflow dispatch were not run, honoring
  the requested verification/release restriction. This is not a compiled/device
  acceptance claim.

The complete stdlib-only reapplication script is
../tool/apply_extraction_evidence_fix.py. It checks every expected source hash and
unique anchor before replacing files, rejects divergent revisions, stages writes,
attempts rollback on failure and accepts already-repaired files. Its --check mode
makes no changes. It performs no tests, builds, network requests, commits or pushes.
The repository commit applies the same embedded replacement manifest directly.

Primary references consulted:

- [Dart RegExp semantics](https://api.dart.dev/dart-core/RegExp-class.html)
- [Dart comparator ordering contract](https://api.dart.dev/dart-core/Comparator.html)
- [ML Kit Android text recognition and geometry](https://developers.google.com/ml-kit/vision/text-recognition/v2/android)

## Full inspected tree

The following is the complete file tree at 4d0e075d771dd1452ab4ec03ecb8ba7733f44ecd; directories are represented
by full paths. The new audit, regression file and repair script are listed after
the base tree.

| Path | Bytes at inspected base |
| --- | ---: |
| `.github/workflows/aaris-review-concurrency-upgrade-v2.yml` | 2915 |
| `.github/workflows/aaris-review-concurrency-upgrade-v3.yml` | 4211 |
| `.github/workflows/aaris-review-concurrency-upgrade-v4.yml` | 5586 |
| `.github/workflows/aaris-review-concurrency-upgrade-v5.yml` | 6856 |
| `.github/workflows/aaris-review-concurrency-upgrade-v6.yml` | 4071 |
| `.github/workflows/aaris-review-concurrency-upgrade.yml` | 38217 |
| `.github/workflows/flutter.yml` | 1520 |
| `.github/workflows/release-apk.yml` | 2626 |
| `.gitignore` | 175 |
| `README.md` | 1845 |
| `analysis_options.yaml` | 245 |
| `android/app/build.gradle.kts` | 1522 |
| `android/app/proguard-rules.pro` | 392 |
| `android/app/src/main/AndroidManifest.xml` | 1751 |
| `android/app/src/main/java/io/flutter/plugins/GeneratedPluginRegistrant.java` | 3716 |
| `android/app/src/main/kotlin/com/aaris/pharmacy/LocalAiPlatform.kt` | 16516 |
| `android/app/src/main/kotlin/com/aaris/pharmacy/MainActivity.kt` | 38638 |
| `android/app/src/main/res/drawable/ic_launcher.xml` | 365 |
| `android/app/src/main/res/values/styles.xml` | 408 |
| `android/build.gradle.kts` | 377 |
| `android/gradle.properties` | 533 |
| `android/gradle/wrapper/gradle-wrapper.jar` | 43764 |
| `android/gradle/wrapper/gradle-wrapper.properties` | 203 |
| `android/gradlew` | 8755 |
| `android/gradlew.bat` | 2865 |
| `android/settings.gradle.kts` | 642 |
| `assets/fonts/Manrope-OFL.txt` | 4384 |
| `assets/fonts/Manrope.ttf` | 165420 |
| `assets/fonts/NotoSansDevanagari-OFL.txt` | 4386 |
| `assets/fonts/NotoSansDevanagari.ttf` | 647144 |
| `docs/AARIS_AUTONOMOUS_OPERATIONS_2026_09_10.md` | 4585 |
| `docs/AARIS_BRAIN_INTENT_FIREWALL_2026_09_10.md` | 3286 |
| `docs/AARIS_BRAIN_LIVE_ANALYTICS_AND_ORDER_SAFETY_2026_09_10.md` | 4614 |
| `docs/AARIS_BRAIN_RECOVERY_AND_DISPENSING_2026_09_10.md` | 5028 |
| `docs/AARIS_CONTEXTUAL_BRAIN_UPGRADE_2026_09_10.md` | 4076 |
| `docs/AARIS_CONVERSATIONAL_AUTONOMY_2026_09_10.md` | 1596 |
| `docs/AARIS_DURABLE_REMOVAL_AND_RECOVERY_2026_09_10.md` | 1834 |
| `docs/AARIS_EXACT_CONTEXT_AND_LIFECYCLE_HARDENING_2026_09_10.md` | 2579 |
| `docs/AARIS_EXPIRY_WASTE_INTELLIGENCE_2026_09_10.md` | 2045 |
| `docs/AARIS_FINDABILITY_AND_CONCURRENCY_2026_09_10.md` | 2383 |
| `docs/AARIS_MEDICINE_RESOLVER_V2_2026_09_11.md` | 5168 |
| `docs/AARIS_OPERATIONAL_AUTOPILOT_2026_09_10.md` | 2201 |
| `docs/AARIS_PATCH_DIAGNOSTIC.txt` | 57 |
| `docs/AARIS_REVIEWED_FEFO_AUTOMATION_2026_09_09.md` | 2255 |
| `docs/AARIS_REVIEWED_OPERATIONAL_ORCHESTRATION_2026_09_10.md` | 2179 |
| `docs/AARIS_SALE_LEDGER_FIREWALL_2026_09_10.md` | 4478 |
| `docs/AARIS_SCAN_LOCAL_AI_AUTOSAVE_2026_09_11.md` | 2443 |
| `docs/APP_BRAIN_OPERATIONAL_ROUTING_2026_09_09.md` | 3021 |
| `docs/ARCHITECTURE.md` | 14096 |
| `docs/AUTONOMOUS_PHARMACY_UPGRADE_2026_09_09.md` | 4036 |
| `docs/CODEBASE_TREE.md` | 14218 |
| `docs/DEFAULT_LOCAL_AI.md` | 2441 |
| `docs/DESIGN_RESEARCH_2026_09_07.md` | 10215 |
| `docs/ENGINEERING_MISSION_2026_09_14.md` | 18857 |
| `docs/LOCAL_AI_ROADMAP.md` | 8406 |
| `docs/LOCAL_AI_UPGRADE_2026_09_09.md` | 8825 |
| `docs/MEDICINE_EXTRACTION_V27_2026_09_14.md` | 3098 |
| `docs/MEDICINE_EXTRACTION_V29_2026_09_14.md` | 4625 |
| `docs/MEDICINE_EXTRACTION_V30_2026_09_14.md` | 3272 |
| `docs/MEDICINE_EXTRACTION_V31_2026_09_14.md` | 2770 |
| `docs/MEDICINE_EXTRACTION_V32_2026_09_14.md` | 2206 |
| `docs/MEDICINE_EXTRACTION_V33_2026_09_14.md` | 2540 |
| `docs/MEDICINE_EXTRACTION_V34_2026_09_14.md` | 3823 |
| `docs/MEDICINE_EXTRACTION_V38_2026_09_14.md` | 3028 |
| `docs/MEDICINE_EXTRACTION_V43_2026_09_14.md` | 3938 |
| `docs/MEDICINE_EXTRACTION_V44_2026_09_14.md` | 3961 |
| `docs/OFFLINE_CAPTURE_CONTEXT_2026_09_12.md` | 10725 |
| `docs/OFFLINE_DECISION_ENGINE_MAP.md` | 14656 |
| `docs/PROGRESS.md` | 5448 |
| `docs/REVIEWED_ACTION_CONCURRENCY_2026_09_10.md` | 2519 |
| `docs/SCANNER_UI_REVIEW_2026_09_12.md` | 6427 |
| `docs/SCAN_AI_ROUTING_2026_09_11.md` | 2482 |
| `docs/SCAN_INGESTION_HARDENING_2026_09_11.md` | 4366 |
| `docs/SCAN_INTELLIGENCE_ARCHITECTURE_2026_09_12.md` | 6361 |
| `docs/SCAN_MEDIA_DEEP_AUDIT_2026_09_11.md` | 3315 |
| `docs/SIMPLE_LOCAL_AI_CONNECTIONS_2026_09_10.md` | 729 |
| `docs/SMART_CAPTURE_2026_09_12.md` | 8084 |
| `docs/UI_UX_UPGRADE.md` | 5826 |
| `docs/ULTIMATE_AUTOMATION_UPGRADE_2026_09_10.md` | 1960 |
| `docs/VIDEO_MEDICINE_AUDIT_2026_09_12.md` | 8338 |
| `lib/app.dart` | 8021 |
| `lib/data/inventory_database.dart` | 24141 |
| `lib/domain/ai_configuration.dart` | 7067 |
| `lib/domain/ai_protocol.dart` | 12184 |
| `lib/domain/app_brain.dart` | 46627 |
| `lib/domain/attention.dart` | 17699 |
| `lib/domain/automation_guard.dart` | 9521 |
| `lib/domain/automation_readiness.dart` | 6155 |
| `lib/domain/backup.dart` | 13164 |
| `lib/domain/brain_analytics.dart` | 8875 |
| `lib/domain/brain_clarification.dart` | 11855 |
| `lib/domain/brain_operations.dart` | 10220 |
| `lib/domain/capture_quality.dart` | 3329 |
| `lib/domain/date_input.dart` | 1504 |
| `lib/domain/default_local_model.dart` | 2562 |
| `lib/domain/dispensing_plan.dart` | 7049 |
| `lib/domain/gguf_metadata.dart` | 15554 |
| `lib/domain/gs1_healthcare.dart` | 6749 |
| `lib/domain/home_projection.dart` | 2845 |
| `lib/domain/import_text_guard.dart` | 655 |
| `lib/domain/intake_match_presentation.dart` | 2757 |
| `lib/domain/intake_resolution.dart` | 14008 |
| `lib/domain/inventory.dart` | 8521 |
| `lib/domain/inventory_integrity.dart` | 7903 |
| `lib/domain/local_ai_protocol.dart` | 27058 |
| `lib/domain/local_context_budget.dart` | 1055 |
| `lib/domain/local_model.dart` | 5978 |
| `lib/domain/local_model_checks.dart` | 9650 |
| `lib/domain/local_scan_evidence.dart` | 6389 |
| `lib/domain/local_scan_handoff.dart` | 4031 |
| `lib/domain/medicine.dart` | 15115 |
| `lib/domain/medicine_brief.dart` | 11084 |
| `lib/domain/medicine_confusion_firewall.dart` | 7856 |
| `lib/domain/medicine_date_intelligence.dart` | 1120 |
| `lib/domain/medicine_date_intelligence_core.dart` | 11083 |
| `lib/domain/medicine_date_intelligence_helpers.dart` | 9695 |
| `lib/domain/medicine_date_parser.dart` | 16116 |
| `lib/domain/medicine_discovery.dart` | 1938 |
| `lib/domain/medicine_evidence_normalization.dart` | 3574 |
| `lib/domain/medicine_intake.dart` | 11959 |
| `lib/domain/medicine_machine_code_safety.dart` | 4950 |
| `lib/domain/medicine_ocr_reliability.dart` | 678 |
| `lib/domain/medicine_ocr_text.dart` | 25536 |
| `lib/domain/medicine_resolution_v2.dart` | 81257 |
| `lib/domain/medicine_review_cardinality.dart` | 12441 |
| `lib/domain/medicine_scan_commit.dart` | 15633 |
| `lib/domain/medicine_scan_guidance.dart` | 14431 |
| `lib/domain/medicine_semantic_roles.dart` | 38792 |
| `lib/domain/medicine_understanding.dart` | 87087 |
| `lib/domain/model_catalogue.dart` | 4932 |
| `lib/domain/offline_decision_reliability.dart` | 5343 |
| `lib/domain/offline_evidence_graph.dart` | 16626 |
| `lib/domain/operations_plan.dart` | 9307 |
| `lib/domain/purchase_order.dart` | 4766 |
| `lib/domain/regulatory_medicine_code.dart` | 9024 |
| `lib/domain/retrieval_fusion.dart` | 4435 |
| `lib/domain/sale_history_integrity.dart` | 7412 |
| `lib/domain/sale_ledger_guard.dart` | 10509 |
| `lib/domain/sales_overview.dart` | 7210 |
| `lib/domain/search.dart` | 36077 |
| `lib/domain/spatial_traceability.dart` | 20599 |
| `lib/domain/stock_risk.dart` | 9315 |
| `lib/domain/tracking.dart` | 18230 |
| `lib/main.dart` | 3776 |
| `lib/services/aaris_default_ai_service.dart` | 105 |
| `lib/services/aaris_default_ai_service_io.dart` | 6209 |
| `lib/services/aaris_default_ai_service_stub.dart` | 625 |
| `lib/services/ai_provider_adapter.dart` | 9958 |
| `lib/services/ai_service.dart` | 37763 |
| `lib/services/backup_service.dart` | 946 |
| `lib/services/bounded_ai_response.dart` | 1736 |
| `lib/services/canonical_medicine_catalog_service.dart` | 27963 |
| `lib/services/cloud_scan_ai_service.dart` | 6037 |
| `lib/services/gguf_inspector.dart` | 451 |
| `lib/services/local_ai_runtime.dart` | 24774 |
| `lib/services/local_ai_service.dart` | 167 |
| `lib/services/local_ai_service_io.dart` | 33002 |
| `lib/services/local_ai_service_stub.dart` | 2611 |
| `lib/services/local_brain_route_policy.dart` | 11547 |
| `lib/services/local_chat_turn.dart` | 5568 |
| `lib/services/local_scan_turn.dart` | 7843 |
| `lib/services/media_import_service.dart` | 7892 |
| `lib/services/medicine_catalog_service.dart` | 15661 |
| `lib/services/medicine_intake_service.dart` | 28035 |
| `lib/services/medicine_review_pipeline.dart` | 18856 |
| `lib/services/model_catalogue_service.dart` | 7353 |
| `lib/services/offline_recognition_memory_service.dart` | 36836 |
| `lib/services/purchase_order_service.dart` | 1968 |
| `lib/services/scan_service.dart` | 11414 |
| `lib/services/search_worker.dart` | 13170 |
| `lib/state/autopilot_supervisor.dart` | 16500 |
| `lib/state/operational_context.dart` | 5169 |
| `lib/state/pharmacy_controller.dart` | 43793 |
| `lib/state/stock_location_operations.dart` | 4560 |
| `lib/state/voice_search_controller.dart` | 9717 |
| `lib/ui/ai_screen.dart` | 71888 |
| `lib/ui/attention_screen.dart` | 15619 |
| `lib/ui/autopilot_beacon.dart` | 4390 |
| `lib/ui/backup_screen.dart` | 18017 |
| `lib/ui/brain_screen.dart` | 65938 |
| `lib/ui/date_field.dart` | 10943 |
| `lib/ui/design.dart` | 38552 |
| `lib/ui/editor_screen.dart` | 42118 |
| `lib/ui/home_screen.dart` | 22006 |
| `lib/ui/import_screen.dart` | 10000 |
| `lib/ui/local_models_panel.dart` | 28018 |
| `lib/ui/medicine_capture.dart` | 6744 |
| `lib/ui/medicine_intake_panel.dart` | 17300 |
| `lib/ui/medicine_review_legacy_entry.dart` | 862 |
| `lib/ui/medicine_review_screen.dart` | 38542 |
| `lib/ui/order_screen.dart` | 14840 |
| `lib/ui/profile_screen.dart` | 13012 |
| `lib/ui/removed_stock_screen.dart` | 14981 |
| `lib/ui/scanner_screen.dart` | 17309 |
| `lib/ui/scanner_view.dart` | 11128 |
| `lib/ui/search_screen.dart` | 28996 |
| `lib/ui/stats_screen.dart` | 13465 |
| `lib/ui/version_history_screen.dart` | 5449 |
| `lib/ui/voice_sheet.dart` | 11917 |
| `pubspec.lock` | 26847 |
| `pubspec.yaml` | 1312 |
| `test/aaris_brain_command_safety_test.dart` | 6266 |
| `test/aaris_brain_recovery_test.dart` | 4248 |
| `test/ai_configuration_privacy_test.dart` | 2021 |
| `test/ai_provider_adapter_test.dart` | 6732 |
| `test/ai_routing_configuration_test.dart` | 1160 |
| `test/app_brain_test.dart` | 14149 |
| `test/app_test.dart` | 8540 |
| `test/attention_test.dart` | 8144 |
| `test/authoritative_business_clock_test.dart` | 4884 |
| `test/autofix_regression_test.dart` | 5574 |
| `test/automation_integrity_guard_test.dart` | 9554 |
| `test/automation_readiness_test.dart` | 7892 |
| `test/autonomous_stock_operations_test.dart` | 13195 |
| `test/autopilot_supervisor_test.dart` | 10400 |
| `test/backup_integrity_test.dart` | 6868 |
| `test/bounded_ai_response_test.dart` | 1908 |
| `test/brain_analytics_test.dart` | 5765 |
| `test/brain_clarification_test.dart` | 5180 |
| `test/brain_command_safety_widget_test.dart` | 2289 |
| `test/brain_field_edit_intent_test.dart` | 2959 |
| `test/brain_screen_test.dart` | 12037 |
| `test/cloud_scan_bounds_test.dart` | 4332 |
| `test/cloud_transport_contract_test.dart` | 8624 |
| `test/controller_read_cache_test.dart` | 2175 |
| `test/date_input_contract.dart` | 3827 |
| `test/date_input_test.dart` | 3897 |
| `test/domain_contract.dart` | 28116 |
| `test/domain_test.dart` | 195 |
| `test/fefo_automation_test.dart` | 8200 |
| `test/home_projection_test.dart` | 2553 |
| `test/import_text_guard_test.dart` | 1106 |
| `test/intake_match_presentation_test.dart` | 2252 |
| `test/intake_resolution_test.dart` | 8777 |
| `test/inventory_event_recovery_test.dart` | 2628 |
| `test/local_ai_context_fallback_test.dart` | 2205 |
| `test/local_ai_resilience_test.dart` | 3599 |
| `test/local_ai_streaming_recovery_test.dart` | 2256 |
| `test/local_chat_context_runtime_test.dart` | 3019 |
| `test/local_model_architecture_test.dart` | 808 |
| `test/local_model_readiness_test.dart` | 1941 |
| `test/local_scan_turn_recovery_test.dart` | 5190 |
| `test/medicine_adjacent_label_ownership_v20_test.dart` | 1193 |
| `test/medicine_brief_test.dart` | 5644 |
| `test/medicine_catalog_test.dart` | 5049 |
| `test/medicine_date_edge_cases_v21_test.dart` | 1947 |
| `test/medicine_date_label_arbitration_v19_test.dart` | 1845 |
| `test/medicine_date_layout_order_test.dart` | 1459 |
| `test/medicine_evidence_integrity_v27_test.dart` | 3183 |
| `test/medicine_evidence_normalization_test.dart` | 1886 |
| `test/medicine_extraction_hardening_v13_test.dart` | 3750 |
| `test/medicine_extraction_hardening_v14_test.dart` | 5063 |
| `test/medicine_extraction_hardening_v15_test.dart` | 4665 |
| `test/medicine_extraction_hardening_v16_test.dart` | 5024 |
| `test/medicine_extraction_hardening_v17_test.dart` | 4048 |
| `test/medicine_extraction_hardening_v18_test.dart` | 4096 |
| `test/medicine_extraction_hardening_v27_test.dart` | 3481 |
| `test/medicine_extraction_hardening_v28_test.dart` | 4704 |
| `test/medicine_extraction_hardening_v29_test.dart` | 2551 |
| `test/medicine_extraction_hardening_v30_test.dart` | 4197 |
| `test/medicine_extraction_hardening_v31_test.dart` | 3829 |
| `test/medicine_extraction_hardening_v32_test.dart` | 4777 |
| `test/medicine_extraction_hardening_v33_test.dart` | 2247 |
| `test/medicine_extraction_hardening_v34_test.dart` | 2990 |
| `test/medicine_extraction_hardening_v35_test.dart` | 2117 |
| `test/medicine_extraction_hardening_v36_test.dart` | 2469 |
| `test/medicine_extraction_hardening_v37_test.dart` | 1833 |
| `test/medicine_extraction_hardening_v38_test.dart` | 2082 |
| `test/medicine_extraction_hardening_v39_test.dart` | 2799 |
| `test/medicine_extraction_hardening_v40_test.dart` | 2985 |
| `test/medicine_extraction_hardening_v41_test.dart` | 5020 |
| `test/medicine_extraction_hardening_v42_test.dart` | 1769 |
| `test/medicine_extraction_hardening_v43_test.dart` | 1928 |
| `test/medicine_extraction_hardening_v44_test.dart` | 3810 |
| `test/medicine_identity_hardening_v25_test.dart` | 2717 |
| `test/medicine_intake_autorun_contract_test.dart` | 1506 |
| `test/medicine_intake_concurrency_test.dart` | 3520 |
| `test/medicine_machine_code_selection_test.dart` | 1406 |
| `test/medicine_ocr_date_hardening_v26_test.dart` | 2634 |
| `test/medicine_ocr_reliability_test.dart` | 802 |
| `test/medicine_ocr_semantic_hardening_v22_test.dart` | 4248 |
| `test/medicine_ocr_semantic_hardening_v23_test.dart` | 4317 |
| `test/medicine_resolution_v2_test.dart` | 14995 |
| `test/medicine_review_cancellation_test.dart` | 2611 |
| `test/medicine_review_cardinality_test.dart` | 4757 |
| `test/medicine_review_contention_test.dart` | 1377 |
| `test/medicine_review_evidence_normalization_test.dart` | 3785 |
| `test/medicine_scan_guidance_test.dart` | 5723 |
| `test/medicine_scan_window_diversity_test.dart` | 3604 |
| `test/medicine_semantic_adjacency_v21_test.dart` | 2380 |
| `test/medicine_spatial_assignment_v24_test.dart` | 2123 |
| `test/medicine_understanding_contract.dart` | 17600 |
| `test/medicine_understanding_test.dart` | 226 |
| `test/offline_capture_context_contract.dart` | 15683 |
| `test/offline_capture_context_test.dart` | 218 |
| `test/offline_counterfactual_v12_test.dart` | 5001 |
| `test/offline_date_intelligence_v10_test.dart` | 3881 |
| `test/offline_decision_engine_test.dart` | 7544 |
| `test/offline_evidence_budget_test.dart` | 5689 |
| `test/offline_evidence_graph_machine_test.dart` | 2547 |
| `test/offline_evidence_machine_authority_test.dart` | 1307 |
| `test/offline_level5_reasoning_test.dart` | 4385 |
| `test/offline_level6_reasoning_test.dart` | 6570 |
| `test/offline_recognition_learning_test.dart` | 5700 |
| `test/offline_recognition_variant_safety_v45_test.dart` | 3654 |
| `test/offline_scan_v3_safety_test.dart` | 6490 |
| `test/offline_search_evidence_v4_test.dart` | 3391 |
| `test/offline_search_evidence_v5_test.dart` | 3821 |
| `test/offline_semantic_brain_v11_test.dart` | 3449 |
| `test/operational_context_test.dart` | 6456 |
| `test/operational_safety_upgrade_test.dart` | 3035 |
| `test/operations_plan_test.dart` | 4389 |
| `test/persistence_test.dart` | 16608 |
| `test/prepared_medicine_review_ui_test.dart` | 2505 |
| `test/purchase_order_guard_test.dart` | 2119 |
| `test/recognition_candidate_completeness_test.dart` | 1605 |
| `test/removal_recovery_test.dart` | 6167 |
| `test/removed_stock_recovery_test.dart` | 5815 |
| `test/reorder_intelligence_test.dart` | 3000 |
| `test/retrieval_fusion_test.dart` | 1858 |
| `test/reviewed_sale_concurrency_test.dart` | 4015 |
| `test/sale_history_integrity_test.dart` | 5296 |
| `test/sale_ledger_firewall_test.dart` | 7569 |
| `test/sales_overview_test.dart` | 4393 |
| `test/scan_auto_save_decision_test.dart` | 4211 |
| `test/scan_capture_contract.dart` | 24472 |
| `test/scan_capture_test.dart` | 197 |
| `test/scan_ingestion_privacy_contract_test.dart` | 2529 |
| `test/scan_learning_and_durable_ai_recovery_contract_test.dart` | 1537 |
| `test/scanner_view_test.dart` | 6074 |
| `test/search_worker_index_reuse_test.dart` | 2417 |
| `test/search_worker_test.dart` | 3487 |
| `test/simple_ai_connections_source_test.dart` | 3564 |
| `test/stock_findability_test.dart` | 4384 |
| `test/stock_location_operations_test.dart` | 6749 |
| `test/stock_risk_test.dart` | 4903 |
| `test/tracking_integrity_test.dart` | 5372 |
| `test/unified_ai_hub_ui_test.dart` | 2455 |
| `test/video_medicine_contract.dart` | 9249 |
| `test/video_medicine_test.dart` | 201 |
| `test/video_sampling_contract_test.dart` | 3188 |
| `test/voice_search_test.dart` | 8323 |
| `third_party/lib_llama_cpp/LICENSE` | 1062 |
| `third_party/lib_llama_cpp/README.md` | 1604 |
| `third_party/lib_llama_cpp/lib/lib_llama_cpp.dart` | 194 |
| `third_party/lib_llama_cpp/lib/src/context_budget.dart` | 741 |
| `third_party/lib_llama_cpp/lib/src/inference_isolate.dart` | 11945 |
| `third_party/lib_llama_cpp/lib/src/lib_llama_cpp.dart` | 2092 |
| `third_party/lib_llama_cpp/lib/src/llama_command.dart` | 6030 |
| `third_party/lib_llama_cpp/lib/src/llama_content.dart` | 4813 |
| `third_party/lib_llama_cpp/lib/src/llama_response.dart` | 2749 |
| `third_party/lib_llama_cpp/lib/src/llama_state.dart` | 2369 |
| `third_party/lib_llama_cpp/lib/src/llama_tool.dart` | 5361 |
| `third_party/lib_llama_cpp/lib/src/native_runtime.dart` | 46015 |
| `third_party/lib_llama_cpp/lib/src/token_text_decoder.dart` | 677 |
| `third_party/lib_llama_cpp/lib/src/tool_aware_streaming.dart` | 5841 |
| `third_party/lib_llama_cpp/lib/src/tool_call_fallback.dart` | 3388 |
| `third_party/lib_llama_cpp/pubspec.yaml` | 851 |
| `tool/apply_video_medicine_fix.py` | 37402 |
| `tool/bootstrap.sh` | 490 |
| `tool/check_date_input.dart` | 406 |
| `tool/check_default_local_ai.dart` | 1554 |
| `tool/check_domain.dart` | 419 |
| `tool/check_local_ai.dart` | 15989 |
| `tool/check_local_ai_runtime.dart` | 7600 |
| `tool/check_medicine_understanding.dart` | 490 |
| `tool/check_model_catalogue.dart` | 5097 |
| `tool/check_model_preflight.dart` | 8949 |
| `tool/check_offline_capture_context.dart` | 497 |
| `tool/check_scan_capture.dart` | 456 |
| `tool/check_video_medicine.dart` | 442 |
| `tool/one_shot_review_concurrency_upgrade.py` | 25161 |

New files in this change:

- `docs/EXTRACTION_ARCHITECTURE_AND_AUDIT_2026_09_14.md`
- `test/medicine_extraction_evidence_integrity_test.dart`
- `tool/apply_extraction_evidence_fix.py`

## Complete application dependency adjacency map

Each row lists all direct import/export/part directives in the inspected source.
SDK and external package edges are retained. Relative paths are resolved from
the importing file; this change adds no dependency edge.

| Source | Direct dependencies |
| --- | --- |
| `lib/app.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/app_brain.dart`, `lib/domain/inventory.dart`, `lib/state/autopilot_supervisor.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/attention_screen.dart`, `lib/ui/autopilot_beacon.dart`, `lib/ui/brain_screen.dart`, `lib/ui/design.dart`, `lib/ui/home_screen.dart`, `lib/ui/profile_screen.dart`, `lib/ui/search_screen.dart`, `lib/ui/stats_screen.dart` |
| `lib/data/inventory_database.dart` | `dart:convert`, `package:sqflite/sqflite.dart`, `lib/domain/automation_guard.dart`, `lib/domain/sale_ledger_guard.dart`, `lib/domain/medicine.dart`, `lib/domain/inventory.dart`, `lib/domain/tracking.dart` |
| `lib/domain/ai_configuration.dart` | `dart:convert` |
| `lib/domain/ai_protocol.dart` | `dart:convert`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/app_brain.dart` | `lib/domain/brain_analytics.dart`, `lib/domain/brain_operations.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine_brief.dart` |
| `lib/domain/attention.dart` | `lib/domain/automation_readiness.dart`, `lib/domain/inventory.dart`, `lib/domain/inventory_integrity.dart`, `lib/domain/medicine.dart`, `lib/domain/sale_history_integrity.dart`, `lib/domain/stock_risk.dart`, `lib/domain/tracking.dart` |
| `lib/domain/automation_guard.dart` | `lib/domain/inventory_integrity.dart`, `lib/domain/medicine.dart` |
| `lib/domain/automation_readiness.dart` | `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/domain/backup.dart` | `dart:convert`, `package:crypto/crypto.dart`, `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/brain_analytics.dart` | `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/brain_clarification.dart` | `lib/domain/app_brain.dart`, `lib/domain/medicine.dart` |
| `lib/domain/brain_operations.dart` |  |
| `lib/domain/capture_quality.dart` | `dart:math`, `dart:typed_data` |
| `lib/domain/date_input.dart` | `lib/domain/medicine.dart` |
| `lib/domain/default_local_model.dart` | `lib/domain/local_model.dart` |
| `lib/domain/dispensing_plan.dart` | `dart:math`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/domain/gguf_metadata.dart` | `dart:convert`, `dart:math`, `dart:typed_data` |
| `lib/domain/gs1_healthcare.dart` |  |
| `lib/domain/home_projection.dart` | `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/domain/import_text_guard.dart` |  |
| `lib/domain/intake_match_presentation.dart` | `lib/domain/intake_resolution.dart`, `lib/domain/search.dart` |
| `lib/domain/intake_resolution.dart` | `lib/domain/gs1_healthcare.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/domain/inventory.dart` | `lib/domain/medicine.dart` |
| `lib/domain/inventory_integrity.dart` | `lib/domain/medicine.dart` |
| `lib/domain/local_ai_protocol.dart` | `dart:convert`, `lib/domain/ai_protocol.dart`, `lib/domain/local_scan_evidence.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/search.dart`, `lib/domain/tracking.dart` |
| `lib/domain/local_context_budget.dart` |  |
| `lib/domain/local_model.dart` | `lib/domain/gguf_metadata.dart` |
| `lib/domain/local_model_checks.dart` |  |
| `lib/domain/local_scan_evidence.dart` | `dart:math`, `lib/domain/medicine_date_parser.dart` |
| `lib/domain/local_scan_handoff.dart` | `dart:convert`, `lib/domain/local_scan_evidence.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/domain/medicine.dart` | `dart:math` |
| `lib/domain/medicine_brief.dart` | `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/domain/medicine_confusion_firewall.dart` | `dart:math`, `lib/domain/medicine.dart`, `lib/domain/search.dart` |
| `lib/domain/medicine_date_intelligence.dart` | `dart:math`, `lib/domain/medicine_date_parser.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/offline_evidence_graph.dart`, `lib/domain/spatial_traceability.dart`, `lib/domain/medicine_date_intelligence_core.dart`, `lib/domain/medicine_date_intelligence_helpers.dart` |
| `lib/domain/medicine_date_intelligence_core.dart` |  |
| `lib/domain/medicine_date_intelligence_helpers.dart` |  |
| `lib/domain/medicine_date_parser.dart` |  |
| `lib/domain/medicine_discovery.dart` | `lib/domain/medicine.dart`, `lib/domain/search.dart` |
| `lib/domain/medicine_evidence_normalization.dart` | `dart:math`, `lib/domain/medicine_understanding.dart` |
| `lib/domain/medicine_intake.dart` | `dart:async`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/domain/medicine_machine_code_safety.dart` | `lib/domain/regulatory_medicine_code.dart` |
| `lib/domain/medicine_ocr_reliability.dart` |  |
| `lib/domain/medicine_ocr_text.dart` | `lib/domain/medicine.dart` |
| `lib/domain/medicine_resolution_v2.dart` | `dart:math`, `lib/domain/gs1_healthcare.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_confusion_firewall.dart`, `lib/domain/medicine_date_intelligence.dart`, `lib/domain/medicine_ocr_text.dart`, `lib/domain/medicine_semantic_roles.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/offline_decision_reliability.dart`, `lib/domain/offline_evidence_graph.dart`, `lib/domain/regulatory_medicine_code.dart`, `lib/domain/search.dart`, `lib/domain/spatial_traceability.dart` |
| `lib/domain/medicine_review_cardinality.dart` | `dart:math`, `lib/domain/medicine_date_parser.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/search.dart` |
| `lib/domain/medicine_scan_commit.dart` | `lib/domain/intake_resolution.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/domain/medicine_scan_guidance.dart` | `lib/domain/medicine_machine_code_safety.dart`, `lib/domain/medicine_scan_commit.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/offline_evidence_graph.dart`, `lib/domain/regulatory_medicine_code.dart`, `lib/domain/search.dart` |
| `lib/domain/medicine_semantic_roles.dart` | `dart:math`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/offline_evidence_graph.dart`, `lib/domain/search.dart` |
| `lib/domain/medicine_understanding.dart` | `dart:math`, `lib/domain/medicine.dart`, `lib/domain/medicine_date_parser.dart`, `lib/domain/medicine_discovery.dart`, `lib/domain/search.dart` |
| `lib/domain/model_catalogue.dart` | `lib/domain/local_model.dart` |
| `lib/domain/offline_decision_reliability.dart` |  |
| `lib/domain/offline_evidence_graph.dart` | `dart:math`, `lib/domain/medicine_machine_code_safety.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/regulatory_medicine_code.dart`, `lib/domain/search.dart` |
| `lib/domain/operations_plan.dart` | `lib/domain/attention.dart`, `lib/domain/medicine.dart` |
| `lib/domain/purchase_order.dart` | `lib/domain/medicine.dart` |
| `lib/domain/regulatory_medicine_code.dart` | `dart:convert`, `lib/domain/gs1_healthcare.dart` |
| `lib/domain/retrieval_fusion.dart` |  |
| `lib/domain/sale_history_integrity.dart` | `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/sale_ledger_guard.dart` | `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/sales_overview.dart` | `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/search.dart` | `dart:math`, `lib/domain/gs1_healthcare.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/domain/spatial_traceability.dart` | `dart:math`, `lib/domain/medicine_date_parser.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/offline_evidence_graph.dart`, `lib/domain/search.dart` |
| `lib/domain/stock_risk.dart` | `dart:math`, `lib/domain/medicine.dart`, `lib/domain/tracking.dart` |
| `lib/domain/tracking.dart` | `dart:math`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/main.dart` | `package:flutter/material.dart`, `package:flutter/foundation.dart`, `package:camera_android/camera_android.dart`, `lib/app.dart`, `lib/data/inventory_database.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/services/aaris_default_ai_service.dart` | `lib/services/aaris_default_ai_service_stub.dart` |
| `lib/services/aaris_default_ai_service_io.dart` | `dart:async`, `dart:convert`, `dart:io`, `package:flutter/foundation.dart`, `package:path_provider/path_provider.dart`, `lib/domain/default_local_model.dart`, `lib/services/local_ai_service.dart` |
| `lib/services/aaris_default_ai_service_stub.dart` | `package:flutter/foundation.dart` |
| `lib/services/ai_provider_adapter.dart` | `dart:convert`, `package:http/http.dart`, `lib/domain/ai_configuration.dart` |
| `lib/services/ai_service.dart` | `dart:async`, `dart:convert`, `dart:typed_data`, `package:flutter/services.dart`, `package:flutter_secure_storage/flutter_secure_storage.dart`, `package:http/http.dart`, `package:share_plus/share_plus.dart`, `lib/domain/ai_configuration.dart`, `lib/domain/ai_protocol.dart`, `lib/domain/local_ai_protocol.dart`, `lib/services/aaris_default_ai_service.dart`, `lib/services/local_ai_service.dart`, `lib/services/ai_provider_adapter.dart`, `lib/services/bounded_ai_response.dart` |
| `lib/services/backup_service.dart` | `dart:convert`, `package:flutter/foundation.dart`, `package:flutter/services.dart`, `package:share_plus/share_plus.dart`, `lib/domain/backup.dart` |
| `lib/services/bounded_ai_response.dart` | `dart:async`, `dart:typed_data` |
| `lib/services/canonical_medicine_catalog_service.dart` | `dart:convert`, `dart:math`, `dart:typed_data`, `package:crypto/crypto.dart`, `package:path_provider/path_provider.dart`, `package:sqflite/sqflite.dart`, `lib/domain/gs1_healthcare.dart`, `lib/domain/medicine_resolution_v2.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/retrieval_fusion.dart`, `lib/domain/search.dart` |
| `lib/services/cloud_scan_ai_service.dart` | `dart:async`, `package:flutter_secure_storage/flutter_secure_storage.dart`, `package:http/http.dart`, `lib/domain/local_ai_protocol.dart`, `lib/domain/local_scan_handoff.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/ai_configuration.dart`, `lib/services/ai_provider_adapter.dart`, `lib/services/bounded_ai_response.dart` |
| `lib/services/gguf_inspector.dart` | `dart:io`, `dart:isolate`, `dart:math`, `lib/domain/gguf_metadata.dart` |
| `lib/services/local_ai_runtime.dart` | `dart:async`, `package:lib_llama_cpp/lib_llama_cpp.dart`, `lib/domain/local_context_budget.dart` |
| `lib/services/local_ai_service.dart` | `lib/domain/local_model.dart`, `lib/domain/model_catalogue.dart`, `lib/services/local_ai_service_stub.dart` |
| `lib/services/local_ai_service_io.dart` | `dart:async`, `dart:convert`, `dart:io`, `dart:isolate`, `package:crypto/crypto.dart`, `package:file_selector/file_selector.dart`, `package:flutter/foundation.dart`, `package:flutter/services.dart`, `package:flutter/widgets.dart`, `package:path_provider/path_provider.dart`, `lib/domain/local_ai_protocol.dart`, `lib/domain/gguf_metadata.dart`, `lib/domain/local_model.dart`, `lib/domain/local_model_checks.dart`, `lib/domain/model_catalogue.dart`, `lib/services/gguf_inspector.dart`, `lib/services/model_catalogue_service.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/local_ai_runtime.dart`, `lib/services/local_chat_turn.dart`, `lib/services/local_scan_turn.dart` |
| `lib/services/local_ai_service_stub.dart` | `package:flutter/foundation.dart`, `lib/domain/local_ai_protocol.dart`, `lib/domain/local_model.dart`, `lib/domain/model_catalogue.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/services/local_brain_route_policy.dart` | `dart:async`, `dart:convert`, `package:flutter_secure_storage/flutter_secure_storage.dart`, `lib/services/local_ai_service.dart` |
| `lib/services/local_chat_turn.dart` | `dart:convert`, `dart:math`, `lib/domain/local_ai_protocol.dart`, `lib/domain/local_context_budget.dart` |
| `lib/services/local_scan_turn.dart` | `dart:math`, `lib/domain/local_ai_protocol.dart`, `lib/domain/local_context_budget.dart`, `lib/domain/local_scan_handoff.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/services/media_import_service.dart` | `dart:async`, `package:flutter/foundation.dart`, `package:flutter/services.dart` |
| `lib/services/medicine_catalog_service.dart` | `dart:convert`, `dart:math`, `package:http/http.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_discovery.dart`, `lib/domain/search.dart` |
| `lib/services/medicine_intake_service.dart` | `dart:async`, `dart:convert`, `dart:io`, `package:flutter/foundation.dart`, `package:flutter/services.dart`, `package:flutter/widgets.dart`, `package:path_provider/path_provider.dart`, `package:sqflite/sqflite.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_intake.dart`, `lib/domain/medicine_evidence_normalization.dart`, `lib/domain/medicine_resolution_v2.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/canonical_medicine_catalog_service.dart`, `lib/services/local_ai_service.dart`, `lib/services/local_brain_route_policy.dart`, `lib/services/media_import_service.dart`, `lib/services/offline_recognition_memory_service.dart`, `lib/services/scan_service.dart` |
| `lib/services/medicine_review_pipeline.dart` | `dart:convert`, `package:flutter/foundation.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_evidence_normalization.dart`, `lib/domain/medicine_resolution_v2.dart`, `lib/domain/medicine_review_cardinality.dart`, `lib/domain/medicine_scan_commit.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/ai_service.dart`, `lib/services/canonical_medicine_catalog_service.dart`, `lib/services/cloud_scan_ai_service.dart`, `lib/services/local_ai_service.dart`, `lib/services/local_brain_route_policy.dart`, `lib/services/offline_recognition_memory_service.dart` |
| `lib/services/model_catalogue_service.dart` | `dart:async`, `dart:convert`, `dart:io`, `dart:typed_data`, `lib/domain/local_model.dart`, `lib/domain/model_catalogue.dart` |
| `lib/services/offline_recognition_memory_service.dart` | `dart:math`, `package:crypto/crypto.dart`, `package:flutter/foundation.dart`, `package:path_provider/path_provider.dart`, `package:sqflite/sqflite.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/search.dart` |
| `lib/services/purchase_order_service.dart` | `dart:convert`, `package:flutter/foundation.dart`, `package:flutter/services.dart`, `package:share_plus/share_plus.dart`, `lib/domain/medicine.dart`, `lib/domain/purchase_order.dart` |
| `lib/services/scan_service.dart` | `dart:async`, `dart:math`, `package:flutter/foundation.dart`, `package:flutter/services.dart`, `package:google_mlkit_barcode_scanning/google_mlkit_barcode_scanning.dart`, `package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart`, `lib/domain/capture_quality.dart`, `lib/domain/medicine_machine_code_safety.dart`, `lib/domain/medicine_evidence_normalization.dart`, `lib/domain/medicine_ocr_reliability.dart`, `lib/domain/medicine_ocr_text.dart`, `lib/domain/medicine_understanding.dart` |
| `lib/services/search_worker.dart` | `dart:async`, `dart:isolate`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/search.dart` |
| `lib/state/autopilot_supervisor.dart` | `dart:async`, `package:flutter/foundation.dart`, `lib/domain/attention.dart`, `lib/domain/medicine.dart`, `lib/domain/operations_plan.dart`, `lib/domain/sale_history_integrity.dart`, `lib/domain/tracking.dart`, `lib/state/pharmacy_controller.dart` |
| `lib/state/operational_context.dart` | `lib/domain/medicine.dart`, `lib/state/pharmacy_controller.dart` |
| `lib/state/pharmacy_controller.dart` | `dart:async`, `package:flutter/foundation.dart`, `lib/data/inventory_database.dart`, `lib/domain/ai_protocol.dart`, `lib/domain/backup.dart`, `lib/domain/dispensing_plan.dart`, `lib/domain/home_projection.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/sales_overview.dart`, `lib/domain/search.dart`, `lib/domain/tracking.dart`, `lib/services/search_worker.dart` |
| `lib/state/stock_location_operations.dart` | `lib/domain/brain_operations.dart`, `lib/state/pharmacy_controller.dart` |
| `lib/state/voice_search_controller.dart` | `dart:async`, `package:flutter/foundation.dart`, `package:speech_to_text/speech_to_text.dart` |
| `lib/ui/ai_screen.dart` | `dart:async`, `package:flutter/material.dart`, `package:flutter/services.dart`, `lib/domain/ai_protocol.dart`, `lib/domain/local_ai_protocol.dart`, `lib/domain/medicine.dart`, `lib/services/ai_service.dart`, `lib/services/local_ai_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/local_models_panel.dart`, `lib/ui/medicine_capture.dart`, `lib/ui/medicine_intake_panel.dart`, `lib/ui/voice_sheet.dart` |
| `lib/ui/attention_screen.dart` | `package:flutter/material.dart`, `lib/domain/attention.dart`, `lib/domain/medicine.dart`, `lib/domain/operations_plan.dart`, `lib/domain/tracking.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/editor_screen.dart`, `lib/ui/order_screen.dart` |
| `lib/ui/autopilot_beacon.dart` | `package:flutter/material.dart`, `lib/state/autopilot_supervisor.dart` |
| `lib/ui/backup_screen.dart` | `dart:async`, `package:flutter/foundation.dart`, `package:flutter/material.dart`, `package:flutter/services.dart`, `lib/domain/backup.dart`, `lib/domain/medicine.dart`, `lib/domain/tracking.dart`, `lib/services/backup_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/ui/brain_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/app_brain.dart`, `lib/domain/attention.dart`, `lib/domain/brain_analytics.dart`, `lib/domain/brain_clarification.dart`, `lib/domain/brain_operations.dart`, `lib/domain/dispensing_plan.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_brief.dart`, `lib/domain/medicine_discovery.dart`, `lib/domain/operations_plan.dart`, `lib/domain/search.dart`, `lib/domain/tracking.dart`, `lib/services/scan_service.dart`, `lib/state/operational_context.dart`, `lib/state/pharmacy_controller.dart`, `lib/state/stock_location_operations.dart`, `lib/ui/ai_screen.dart`, `lib/ui/attention_screen.dart`, `lib/ui/design.dart`, `lib/ui/editor_screen.dart`, `lib/ui/import_screen.dart`, `lib/ui/order_screen.dart`, `lib/ui/removed_stock_screen.dart`, `lib/ui/scanner_screen.dart`, `lib/ui/search_screen.dart` |
| `lib/ui/date_field.dart` | `package:flutter/material.dart`, `package:flutter/services.dart`, `lib/domain/date_input.dart`, `lib/domain/medicine.dart` |
| `lib/ui/design.dart` | `dart:ui`, `package:flutter/material.dart`, `lib/domain/date_input.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart` |
| `lib/ui/editor_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/date_input.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_discovery.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/offline_recognition_memory_service.dart`, `lib/state/operational_context.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/date_field.dart`, `lib/ui/design.dart`, `lib/ui/version_history_screen.dart` |
| `lib/ui/home_screen.dart` | `package:flutter/material.dart`, `lib/state/pharmacy_controller.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/ui/design.dart`, `lib/ui/search_screen.dart`, `lib/ui/editor_screen.dart` |
| `lib/ui/import_screen.dart` | `dart:async`, `package:flutter/material.dart`, `package:flutter/services.dart`, `lib/domain/import_text_guard.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/backup_service.dart`, `lib/services/media_import_service.dart`, `lib/services/medicine_intake_service.dart`, `lib/services/medicine_review_pipeline.dart`, `lib/services/scan_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/editor_screen.dart`, `lib/ui/medicine_capture.dart`, `lib/ui/medicine_intake_panel.dart`, `lib/ui/medicine_review_screen.dart`, `lib/ui/scanner_screen.dart`, `lib/ui/medicine_review_legacy_entry.dart` |
| `lib/ui/local_models_panel.dart` | `dart:async`, `package:flutter/material.dart`, `lib/services/aaris_default_ai_service.dart`, `lib/services/local_ai_service.dart` |
| `lib/ui/medicine_capture.dart` | `package:flutter/material.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/media_import_service.dart`, `lib/services/medicine_intake_service.dart`, `lib/services/medicine_review_pipeline.dart`, `lib/services/scan_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/medicine_review_screen.dart`, `lib/ui/scanner_screen.dart` |
| `lib/ui/medicine_intake_panel.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_intake.dart`, `lib/domain/medicine_review_cardinality.dart`, `lib/domain/medicine_scan_commit.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/medicine_intake_service.dart`, `lib/services/medicine_review_pipeline.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/medicine_review_screen.dart` |
| `lib/ui/medicine_review_legacy_entry.dart` | `package:flutter/material.dart`, `lib/services/medicine_review_pipeline.dart`, `lib/services/scan_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/medicine_review_screen.dart` |
| `lib/ui/medicine_review_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/intake_match_presentation.dart`, `lib/domain/intake_resolution.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine.dart`, `lib/domain/medicine_scan_commit.dart`, `lib/domain/medicine_understanding.dart`, `lib/domain/search.dart`, `lib/services/medicine_review_pipeline.dart`, `lib/services/offline_recognition_memory_service.dart`, `lib/state/operational_context.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/editor_screen.dart` |
| `lib/ui/order_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/attention.dart`, `lib/domain/medicine.dart`, `lib/domain/operations_plan.dart`, `lib/domain/tracking.dart`, `lib/services/purchase_order_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/ui/profile_screen.dart` | `package:flutter/material.dart`, `lib/state/pharmacy_controller.dart`, `lib/services/ai_service.dart`, `lib/ui/backup_screen.dart`, `lib/ui/design.dart`, `lib/ui/home_screen.dart`, `lib/ui/removed_stock_screen.dart` |
| `lib/ui/removed_stock_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/app_brain.dart`, `lib/domain/medicine.dart`, `lib/domain/search.dart`, `lib/state/operational_context.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/ui/scanner_screen.dart` | `dart:async`, `package:camera/camera.dart`, `package:flutter/foundation.dart`, `package:flutter/material.dart`, `package:flutter/services.dart`, `package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart`, `lib/domain/capture_quality.dart`, `lib/domain/medicine_resolution_v2.dart`, `lib/domain/medicine_scan_guidance.dart`, `lib/domain/medicine_understanding.dart`, `lib/services/media_import_service.dart`, `lib/services/scan_service.dart`, `lib/ui/design.dart`, `lib/ui/scanner_view.dart` |
| `lib/ui/scanner_view.dart` | `package:flutter/material.dart`, `lib/ui/design.dart` |
| `lib/ui/search_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/inventory.dart`, `lib/domain/medicine_discovery.dart`, `lib/domain/search.dart`, `lib/services/medicine_catalog_service.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart`, `lib/ui/editor_screen.dart`, `lib/ui/import_screen.dart`, `lib/ui/scanner_screen.dart`, `lib/ui/voice_sheet.dart` |
| `lib/ui/stats_screen.dart` | `package:flutter/material.dart`, `lib/domain/sales_overview.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/ui/version_history_screen.dart` | `dart:async`, `package:flutter/material.dart`, `lib/domain/medicine.dart`, `lib/domain/date_input.dart`, `lib/state/pharmacy_controller.dart`, `lib/ui/design.dart` |
| `lib/ui/voice_sheet.dart` | `dart:async`, `package:flutter/material.dart`, `package:flutter/services.dart`, `lib/state/voice_search_controller.dart`, `lib/ui/design.dart` |
