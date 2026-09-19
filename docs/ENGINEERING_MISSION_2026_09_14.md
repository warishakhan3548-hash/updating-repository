# Aaris Pharmacy engineering mission — 14 September 2026

## Scope and verification boundary

Target: warishakhan3548-hash/updating-repository, main.
Starting commit: 84210488d776c21bc6516da1d504d46fe815bf70.

The session exposes GitHub source/object/ref operations, but no shell, Dart,
Flutter, SQLite or Android runtime. Source inspection and focused JavaScript
reasoning checks are possible; Dart execution, query-plan measurements and device
acceptance are not. No CI dispatch, APK build, Flutter analysis or Flutter tests
are authorized. Checkpoints carry [skip ci] and use non-force ref updates.
Earlier documents' recorded test results are not evidence for this pass.

## Runtime ownership traced from source

- main creates PharmacyController(SqliteInventoryStorage); PharmacyApp owns
  application lifecycle and the operational supervisor. Visited tabs are retained.
- Inventory SQLite schema v3 stores medicine/sale JSON facts by ID, metadata,
  request receipts and a 200-event audit window. Controller commands feed
  InventoryMutation; storage revalidates facts and revision in one transaction.
  Expired, sold and warning screens derive state from those same records.
- ScannerScreen owns camera generation, one frame operation and capture drain.
  MedicineVisionService runs Latin, Devanagari and barcode detectors on the same
  image, retains line geometry and quarantines conflicting trusted machine codes.
- Photo/rapid/video imports enter MedicineIntakeService's durable staging DB.
  Native MainActivity samples bounded video windows; Dart OCR feeds the same
  understandMedicineEvidenceV2Message used by interactive MedicineReviewPipeline.
  Prepared queue drafts enter MedicineReviewScreen without reinterpreting identity.
- The V2 resolver composes MedicineUnderstandingEngine with indexed canonical
  products, layout/date/GS1/regulatory/confusion checks. SearchWorker owns the
  isolate search index. Canonical and adaptive databases contain knowledge,
  not parallel authoritative inventories.
- OfflineRecognitionMemoryService learns aliases only after human save. Identity
  includes salt, strength and form; salt corrections require same-frame identity.
  Current knowledge comes from active stock, capped at 12,000 unique entries.
- LocalAiService owns the selected model and one exclusive lease; LocalAiRuntime
  owns transport epoch, native cancellation, stall/deadline and context fallback.
  runLocalScanTurn and CloudScanAiService use validateLocalScan: source quotes,
  ingredient pairs and deterministic date ownership constrain suggestions.
- MedicineReviewScreen owns source/match generations and final confirm. Editor
  owns manual fields and row revision. Persistence is authoritative before
  optional recognition feedback; provider output does not directly write stock.
- At the starting commit, cloud chat and cloud scan duplicated request/envelope adaptation.
  Both use OS secure storage, HTTPS without embedded credentials and no redirects.
  Explicit cloud scan excludes private inventory/adaptive hints from its payload.

## Concrete audit findings guiding implementation

1. Chat response timeouts measure gaps between events, allowing a steady trickle
   (including a giant unterminated SSE line) to retain a turn indefinitely.
   Scan already bounds its body deadline; both transports need bounded raw bytes.
2. Provider wire formats are duplicated across chat and scan, with every unknown
   provider treated as OpenAI-compatible. Capabilities and provider identity need
   explicit validation and shared adapters without changing medicine validators.
3. Adaptive retrieval takes the first 256 rows by support before considering
   collisions. A competing identity omitted by LIMIT can make an ambiguous alias
   appear unique. Historical support is effectively unbounded (up to one million).
4. Native video sampling computes low-resolution quality but currently emits every
   decoded bucket. Deduplication must preserve fine date/strength changes and
   never replace product evidence with a coarse visual-similarity guess.
5. Before V2 normalization, the video worker drops frames whose text/barcode are
   empty even when layout contains observed text. Live preview has the same early
   gate. V2 does reconstruct layout, but cannot recover a frame discarded earlier.
6. Core dates already support the requested numeric forms. Further tracing found
   that the existing OCR canonicalizer also splits named months glued to MFG/EXP.
   Preserve this functioning grammar; no speculative date rewrite is warranted.
7. Existing camera and local-runtime ownership are substantial; preserve them.
   Do not introduce overlapping recognizers, timers, runtime owners or inventory DBs.

## Research informing the changes

- Dart Future.timeout does not stop the source operation:
  https://api.dart.dev/dart-async/Future/timeout.html
- Stream.timeout measures time between events:
  https://api.dart.dev/dart-async/Stream/timeout.html
- SQLite ordered/multi-column index semantics:
  https://www.sqlite.org/queryplanner.html
- Provider contracts:
  https://platform.claude.com/docs/en/build-with-claude/streaming
  https://ai.google.dev/gemini-api/docs/text-generation
  https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create

The following sections distinguish implemented changes from preserved behavior and unverified device assumptions.

## Checkpoint: provider protocols and response bounds

- Shared adapters now implement Gemini generateContent, Chat Completions
  (OpenAI and configurable compatible endpoints), and Anthropic Messages.
  Chat/scan use the same wire mapping; existing evidence/AI-plan validators stay
  authoritative. Model IDs are user supplied; no name-specific model catalogue.
- Secure configuration v2 preserves old values and accepts legacy Compatible /
  OpenAI-compatible aliases. Unknown protocols fail before a request. Base /v1
  URLs expand predictably; custom full HTTPS endpoints remain exact.
- Streaming and provider JSON mode are explicit capabilities in settings.
  Anthropic remains prompt-structured text, with required max_tokens and typed
  text-block deltas. Tool/image input is not claimed or transmitted.
- Raw response bytes are capped before UTF-8/line splitting, with an absolute
  body deadline and cancellation checks. Provider bodies are not surfaced as
  errors; HTTP categories remain actionable. Auth/rate limits do not auto-retry.
- Removing a cloud key returns the actual saved configuration so the active
  Local Brain preference is not visually reset. Switching provider clears the
  old unsaved key/model so another vendor cannot receive an old credential.
- Added 12 focused provider/stream regression tests, not executed in this session.
  Source review preserves existing bounded retries, ownership and [skip ci].

## Checkpoint: evidence ownership and bounded adaptive retrieval

- Moved existing layout-only reconstruction to one pure domain helper, used by
  the detector, intake and review boundaries. Raw nonempty OCR remains unchanged;
  frame identity, geometry and quality survive. Oversized frame sets fail explicitly.
- Date geometry sorting used a pairwise row tolerance, which was nontransitive
  for three overlapping rows. Total spatial sorting now precedes row grouping;
  geometry-free detector lines retain their original order. The existing labelled
  compact/named-month parser and chronological validation are preserved.
- Vision service now rejects overlapping frame operations before its first await;
  Latin/Devanagari/barcode detectors still run concurrently within one frame.
- Adaptive alias counts and Top-256 retrieval use one read transaction. An alias
  contributes only when all its competing rows are present and structurally valid.
  Strength/form/barcode compatibility remains ahead of historical arbitration.
- New confirmations cap support at 32; reads clamp legacy counts and use logarithmic
  weight with existing recency decay. This prevents old repetition from growing
  without bound. Same human-confirmation receipts and capacity limits are retained.
- Learning failures emit stage/type-only debug diagnostics; no OCR or medicine
  identity is logged. Failure continues to fall back to original knowledge.
- Inventory startup reads metadata, medicines, sales and receipts in one SQLite
  transaction. No schema, migration, inventory representation or index changed.
- Added 9 regression cases for truncation/corruption, layout preservation and
  date sorting/grammar. These Dart tests have not been executed. A JavaScript
  reproduction demonstrated the old comparator cycle and the new total ordering.

## Checkpoint: immediate capture, video reuse and optional-model isolation

- Camera startup no longer waits on default-model initialization, a modal offer or
  download. The existing explicit Local Models panel still installs/activates the
  default or another model. Removed the now-unused capture-only setup dialog.
- Native video hashing is computed while writing the existing JPEG, with only
  digest-sized additional state and no second image copy or disk-read pass.
  Consecutive identical OCR inputs are suppressed for up to 3 seconds; the window
  tail and temporal anchors remain. Different encoded pixels always survive.
  Decode failures break the duplicate run. Fine text is never suppressed based on
  thumbnail similarity. Existing bounded quality-rescue sampling is preserved.
- A JavaScript reproduction retained 8 of 40 identical samples and all 40 distinct
  samples, including a one-frame change and its return. This is control-flow
  evidence, not an Android throughput/accuracy benchmark. Decoding and JPEG
  encoding still occur; the saving is in OCR invocations and retained files.
- Native video allocation failure now cleans the sampled directory and reports a
  recoverable error through the existing worker. Native decoder stalls/process
  OOM cannot be ruled out without real-device fault testing.
- Cloud configuration reads no longer initialize Local AI. Saved routing is shown
  before optional model preparation, and reopening settings reads a fresh secure
  envelope. Configuration generations reject older reads; a single editor owns
  each settings session. Re-reading after editing does not wait on model loading.
- Secure config decoding is bounded and sanitizes JSON source excerpts. The shared
  structured AI parser also removes malformed-response source snippets from
  exceptions while retaining the existing single-object recovery/validation.
- Added 4 privacy/configuration regression cases, not executed. No dependency or
  build configuration changed. The existing local runtime/lease/cancellation
  implementation remains the owner of on-device inference.

Additional primary references used:
https://developer.android.com/reference/java/security/DigestOutputStream
https://pub.dev/packages/camera
https://api.dart.dev/dart-async/StreamIterator/cancel.html

## Final adversarial review

The final review caught two further compatibility/performance details: legacy
adaptive support must be capped in SQL candidate ordering as well as final
weighting, and existing compatible gateway top-level text deltas must survive the
adapter extraction. Both were corrected. Typed thinking/reasoning/tool deltas
remain excluded. Removed obsolete endpoint forwarding from chat orchestration;
the adapter validates and owns the actual request URI.

### Final runtime and authoritative boundaries

| Stage | Runtime owner and boundary |
| --- | --- |
| Camera / images / video | ScannerScreen and MediaImportService acquire inputs; native video samples bounded windows. MedicineVisionService leases one frame across OCR and barcode detectors. |
| Evidence | The shared layout reconstruction runs before empty-frame gates. Original nonempty OCR, layout, timestamps, source and quality are retained. Field-specific normalization remains in medicine_ocr_text and domain parsers. |
| Retrieval / pharmacy understanding | CanonicalMedicineCatalogService and bounded adaptive aliases feed the existing V2 resolver in compute. Inventory SearchWorker retains its existing isolated index. |
| Optional AI | Explicit local route uses the existing selected-model lease; explicit cloud uses protocol adapters. Cloud scan context contains bounded OCR, without private inventory/adaptive history. Chat's explicit cloud inventory workflow retains its existing export consent boundary. |
| Structured validation / confidence | Local and cloud scan candidates use validateLocalScan, source quotations, paired ingredients and deterministic date ownership. The existing resolver conflict rules and ScanQuickAdd/AutoSave decisions remain the confidence/commit authority; no new averaged model confidence is introduced. |
| Review / final state | MedicineReviewScreen owns immutable prepared drafts and match/source generations. EditorScreen owns manual edits and the reviewed row revision. Existing review, one-tap confirm and conservative automation gates are retained. |
| Persistence | medicineFromConfirmedScan or EditorScreen constructs Medicine; PharmacyController.save enters InventoryMutation and SQLite CAS validation. Derived expiry/sold/warning screens read the same authoritative inventory. |
| Learning | Human-confirmed save precedes alias feedback. Automatic machine-save does not teach. Receipt identity, variant compatibility and bounded memory govern reuse; an unavailable memory DB returns original knowledge. |

### Database and performance decisions

No schema migration, new inventory table, dependency upgrade, FTS deployment or
WAL toggle was required for these fixes. The existing normalized_alias index
supports candidate filtering/group counting. Capped Top-K still requires ordering
the bounded matching rows; this was reasoned from the SQL and index definitions,
not measured with EXPLAIN. The counts query adds read work to avoid false identity
certainty when a candidate list truncates.

Inventory remains JSON-fact based and loads complete snapshots. Controller
integrity checks and snapshot copies may become a bottleneck at larger stock
sizes; this session does not claim a database-scale benchmark or replace those
invariants speculatively. Canonical/adaptive knowledge stays bounded. Native video
dedup reduces OCR work for exactly repeated frames, while preserving decoded
variations and package-transition anchors; camera-motion/noise near-duplicates
remain eligible until a safe device-calibrated policy exists.

### Verification actually performed

- Inspected the connected Flutter/domain/service/state/data architecture, native
  Android media and Local AI owners, dependency pins and workflow definitions.
- Reviewed every checkpoint diff and cumulative GitHub comparison against the
  starting SHA; checked deleted helper references and final relative Dart imports.
- A focused JavaScript check found no missing relative imports in 125 inspected
  Dart source/test files. This is a path check, not Dart parsing, analysis or compilation.
- Reproduced the prior date-sort cycle and video duplicate-admission control flow
  in JavaScript; these are reasoning experiments, not app/test-suite executions.
- Authored 26 regression cases across six new Dart test files. None was run here.
- Reviewed schema versions/index definitions, transaction scopes, CAS, feedback
  receipts, human-confirmation paths, native drain/generation guards, provider
  bodies/authentication/redirect policy and bounded transport/error paths.
- Checked modified content for merge markers and common credential/private-key
  patterns, and manually reviewed configuration/diagnostic changes. No actual
  credentials, binaries, generated files or workflow edits were added.
- Every checkpoint was a non-force child of the current remote main; the remote
  SHA was re-read after each push. No external main advancement occurred.
- Read GitHub Actions runs for all four implementation/audit checkpoints: only
  the repository's automatic GitHub Pages/Jekyll publishing ran. Application
  Flutter checks and release APK workflows did not run. No workflow was dispatched.

### Explicit remaining limits

1. No Dart/Flutter compiler, analyzer, test runner, SQLite engine or Android device
   was available in this session. New tests and Kotlin/Dart integration still
   need execution in an authorized development/device environment.
2. Camera permission/lifecycle/orientation, giant-image decoding, video codecs,
   native allocation failure and exact duplicate hashing were reviewed in source,
   not fault-injected on phones. Image orientation/resizing were not rewritten;
   device OCR behavior and large-photo memory use remain acceptance risks.
3. Local AI discovery, GGUF compatibility, memory planning, selection, exclusive
   runtime, cancellation and restart recovery were traced and preserved. No model
   weights were executed; arbitrary model/device compatibility is not claimed.
4. Provider support means the implemented Gemini, Chat Completions and Anthropic
   protocols with explicit configuration. There is one saved cloud connection;
   model discovery, arbitrary HTTP authentication/templates, image/tool APIs and
   automatic multi-provider failover were not added. No live paid API call was made.
5. Adaptive learning is compact confirmed-alias retrieval, not model-weight
   training. No speculative learned dates, quantities or automatic acceptance of
   rejected/unconfirmed predictions was added. Clinical/OCR accuracy and
   confidence calibration require a representative reviewed pack dataset.
6. Learning follows the inventory transaction in a separate optional store. A
   process crash between inventory commit and feedback can lose that learning
   event; inventory remains saved. There is no new cross-database outbox.
7. Native decoder calls cannot be forcibly terminated by a Dart timeout. Existing
   work barriers retain ownership until native work drains; real-device stall
   behavior and worst-case cancellation latency remain unmeasured.
8. No zero-bug, complete production-safety, migration execution, clinical
   correctness or measured speedup claim is made.

### Remote checkpoint history

- 4ab38346538ea081c5ad19298b35f5a56ae3231f — Repository architecture and audit.
- 867f27ed7b621cddf54e4c41314224d2ff0be2f6 — Shared provider adapters and bounded response transport.
- bd75468f82dbcf1da82217338ea36295e4ff6b7b — OCR boundary, date order, adaptive collision safety and coherent inventory load.
- af715be8bdd7b9143ce35fa82365993bd9990323 — Immediate scanner, duplicate video suppression and optional-model isolation.

The final review/report commit is a direct child of the last checkpoint above;
its exact verified main SHA is reported in the session completion message.
