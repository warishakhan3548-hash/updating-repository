# Implementation status — 2026-09-10

## Offline AI upgrade — code-only handoff

- Existing AI Hub settings now contain public GGUF search, pinned/resumable
  download, private import, explicit activation and selected-local routing.
  No cloud fallback occurs while local is selected, even after a load failure.
- Shared OCR plus evidence-quoted local reasoning proposes brand/salt/strength
  fields and ordered ingredient pairs. Deterministic date/stock validators and
  explicit review remain authoritative; unknown values are not invented.
- AI Hub camera, rapid captures and ordinary video upload share durable local
  drafts. Video windows retain complementary views and resume from checkpoints.
  On-device Hindi/English microphone support requires a supported Android speech
  service; unsupported devices use typing, not automatic online recognition.
- Local chat reads paged inventory, expiry/archive details and deterministic
  sales. Add/edit/archive/sold/restock proposals use the existing reviewed,
  revision-checked transaction protocol, never direct model SQL.
- A source audit found two upstream runtime defects. The minimal MIT core is
  vendored with command completion and per-prompt KV-memory reset fixed directly;
  the unused server dependency has been removed. Platform binaries stay pinned.
- **167 executable checks passed**: domain 52, dates 25, medicine understanding
  24, local AI protocol 54, runtime lifecycle 12. Static analysis includes
  `lib`, `test`, `tool` and the vendored core and reports no issues.
- No APK, Android compilation, workflow dispatch or model-weight download was
  performed for this upgrade. Actual model/device execution remains a release
  gate. See [source map](CODEBASE_TREE.md) and [scope/release gates](LOCAL_AI_ROADMAP.md).

## Autonomous safety and quick-intake upgrade — 2026-09-10

- Aaris Brain can convert explicit add-medicine commands into a review-only editor draft containing only pharmacist-typed facts (quantity, dates, batch/barcode, price and location included). Ambiguous numbers remain text evidence rather than guessed stock or dosage facts.
- Pharmacist-reviewed FEFO sales, stock corrections/receipts, stock relocation, protected bulk removal and removed-stock restore now carry durable exactly-once request receipts. Duplicate callbacks/retries cannot repeat the physical stock or sale effect; a fresh review intentionally mints a fresh request.
- Exactly-once receipts are enforced again at the authoritative persistence boundary while malformed requests and genuinely stale new requests still fail closed. Undo reverses the stock effect without resurrecting the old request token.
- The single SQLite medicine database, explicit confirmations, audit/Undo, sale-ledger firewall, integrity firewall and local-first AI/OCR review boundaries remain authoritative.

## Completed in source

- Master local medicine database with atomic reactive updates and SQLite v3
  migrations for aggregate sales.
- Configurable expiry dashboard, scoped/global type-mic-scan search, progressive
  warning borders, exact-ID editor navigation, bounded n-gram memory and fuzzy
  confidence ranking.
- Manual add/edit/remove/restock, explicit SOLD, aggregate sale recording,
  FEFO batch guidance, expired-sale/MFG-date guards, durable removal reason/time,
  local-AI reviewed recovery of exact archived rows, soft-delete history, latest
  Undo and per-medicine version restore. Remove/SOLD/Restore AI lifecycle actions
  require explicit checkbox selection before the final atomic Apply.
- Reviewed photo/text imports and adaptive local video import with frame sampling,
  bounded decode, blur/duplicate rejection, multi-frame consensus, explicit
  list-row boundaries, drain-before-restart cancellation, no silent catalog
  lookup and temporary-file cleanup.
- Layout-aware pharmacy understanding with split composition/date scopes,
  conservative ingredient canonicalization, 12,000-record private local identity
  memory, barcode consensus, OCR-confusion repair and ambiguity-safe strength
  matching. Saved corrections improve future scans without cloud learning.
- Pharmacy-only external-AI TXT/prompt, configurable API route, strict JSON/diff
  review, stale/replay protection, cancellation and atomic selected apply.
- Tracking periods, medicine/stock/salt/form/value metrics, fast movement,
  velocity-aware reorder queue, editable Order Now and native Android PDF share.
- Versioned full backup/restore with strict validation, missing-record archiving,
  typed confirmation and Undo. Secure AI keys are excluded.
- Consistent pharmacy UI across Home, Database, AI, Calculator, Profile, scanner,
  editor, import and backup, with responsive warning cards and shared typography.
- Voice-search lifecycle repair: device locales, permission retry, serialized
  commands, final-word preservation, stale callback rejection and exit cleanup.
- Existing GitHub workflows run source checks and produce an Android release APK.
  The local bootstrap remains a separate check path.

## Earlier verification recorded (not re-run as part of this upgrade)

- Current code-only verification (2026-09-08): 52 pure domain checks, 25 date
  checks and 24 medicine-understanding checks passed; source formatting and
  whitespace validation are clean. No APK or CI workflow was run.
- Dart static analysis for `lib` and `test`: clean at source commit `e26e387`.
- Pure-Dart domain contract: 45 checks passed, 0 failed.
- Date-input contract: 24 checks passed, 0 failed.
- Full Flutter/SQLite/widget suite: 123 tests passed in GitHub Actions, including
  11 voice regressions and the narrow-phone/large-text layout check.
- Nine seeded UI screenshots inspected. APK built and uploaded successfully.
  See [research and verification record](DESIGN_RESEARCH_2026_09_07.md) for exact runs.
- Physical Android microphone/camera behavior still needs device acceptance.

## Deliberately outside the local core

- Firebase, cloud sync and external server sync are excluded by product contract.
  Local SQLite plus reviewed backup/restore remain authoritative.
- Image/projector LLMs, trained pharmacy-specialist weights and verified worldwide
  drug corpora remain outside this delivery. Local models receive OCR/layout
  evidence; they do not directly watch the raw video or replace the knowledge DB.
- Store signing and release hardening remain with the owner. The current generated
  release APK uses the repository's existing debug signing configuration.
