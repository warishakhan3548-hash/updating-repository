# UI, local AI recovery and scan accuracy — 15 September 2026

Base: `1187a8e78fc644f543430572610cd344b881c5d2`.
Both `warishakhan3548-hash/updating-repository` and
`Aaris-khan/pharmacy-app-ultimate` pointed to this commit when work began.
This change targets `Aaris-khan/pharmacy-app-ultimate`.

## Architecture and impact map

| User event | Execution and state path | Surgical target and downstream effect |
| --- | --- | --- |
| Launch | `main.dart` → SQLite initialization → `PharmacyApp` → retained five-tab shell | Preserve the single controller and inventory database. |
| Tap a tab or open a page | `_ShellState` → `MaterialPageRoute` → themed `Scaffold` | Route surfaces now paint the existing canvas color; tab changes release the old keyboard focus while keeping drafts and scroll state. |
| Receive a chat answer | `AiScreen` → `AiService` → chosen local or cloud route → preview → final response | Batch token preview work every 32 ms, coalesce post-frame scrolling, respect user scrolling and remove synthetic re-typing of complete answers. |
| Use Local AI | `LocalAiService` exclusive lease → `LocalAiRuntime` → native llama.cpp actor | Reserve queued commands before awaiting teardown; cancellation prevents a later unwanted model load. Error drain deadlines cannot be extended by failed-command traffic. |
| Scan/photo/video | On-device OCR/barcode evidence → review/intake pipeline → `MedicineUnderstandingEngine` / semantic resolver → optional AI | Share dose grammar and preserve medically significant identity punctuation. No new model, catalogue, database or network dependency. |
| Refine a scan with AI | Bounded source evidence → local/cloud answer → `validateLocalScan` | Quotes must align with complete source tokens. Ingredient concentrations must match their complete printed amounts. |
| Confirm/add | `medicine_scan_commit.dart` → controller revision validation → SQLite transaction → live inventory projections | Reject extra text, incomplete combinations, invalid/zero dose values and unresolved evidence. Preserve the existing manual review route. |

## Findings and changes

1. The shared theme made all Scaffold surfaces transparent while one ambient
   painter lived behind the entire Navigator. The previous route could therefore
   appear through the entering route until Flutter stopped painting it. Each
   route now paints its own opaque surface. The now-obscured ambient painter and
   unused blur API/call sites were removed. The only nonzero blur was underneath
   an opaque navigation-panel face and could not contribute visible pixels.
   Card gradients, borders and shadows remain in their original implementation.
   This is a source-level explanation for the reported flash; device frame
   profiling has not been performed.
2. Chat rebuilt and reparsed the entire accumulated response for each token and
   scheduled two scroll callbacks per update. A complete non-streamed answer
   was also artificially re-typed. Preview updates are now bounded, final replies
   appear immediately, and scrolling older messages is respected. Pending
   preview work is discarded on stream reset, completion, cancellation and exit.
3. Native errors previously started a 15-second drain timer, but late tokens,
   state changes and repeated errors kept resetting it. The first terminal error
   now fixes that deadline and remains the propagated failure, including memory
   allocation details needed for smaller-context recovery. Commands waiting for
   old-actor teardown now own a cancellable lease before that await.
4. Raw substring quotes could certify DOLO inside DOLOMET/PREDOLO or truncate a
   hyphenated product. Source-token checks now reject these shortened identities,
   including attempts to hide the short value inside a longer quote. Exact later
   occurrences remain usable.
5. Independent dose regexes disagreed about microgram spellings, concentration
   denominators and percentage bases. The final add gate accepted any matching
   substring rather than a complete strength. A shared lexical rule now retains
   complete supported units and requires complete, positive, finite values for
   quick add. An ambiguous raw grouped comma stays for review; the existing OCR
   normalizer can still explicitly turn a supported grouped `1,000 mg` into
   `1000 mg`. It must never silently become `1.000 mg`.
6. General search normalization removed `%`, `/` and `+` from catalogue strength
   identity and some conflict comparisons. The new strength key retains those
   distinctions and canonicalizes microgram spelling without converting doses.

## Prompt and data preservation

The following files are byte-for-byte identical to the base:

- `lib/domain/ai_protocol.dart` (the current conversational cloud prompt)
- `lib/domain/local_scan_handoff.dart` (scan prompt and payload contract)
- `lib/services/cloud_scan_ai_service.dart`
- `lib/services/ai_provider_adapter.dart`

The multiline Local AI instruction strings in `local_ai_protocol.dart` are also
unchanged. This patch changes evidence validation, not prompt wording or the
normal conversational response policy. No inventory schema, persisted record,
API key, model weight, cloud-sync path or release workflow is modified.

## Verification performed

| Executable check | Passed |
| --- | ---: |
| New scan accuracy regressions | 54 |
| New controlled local error/cancellation regressions | 12 |
| Existing inventory/domain contract | 52 |
| Existing medicine-understanding contract | 24 |
| Existing Local AI protocol contract | 70 |
| Existing date-input contract | 25 |
| Existing cloud conversation/provider request contract | 119 |
| Existing AI connection persistence/selection contract | 24 |
| Existing offline capture/context contract | 52 |
| **Total** | **432** |

The same 54 accuracy fixtures produced **24 passes and 30 failures on the base
commit**, and **54 passes / 0 failures after the change**. These are curated
regression fixtures, not a measured real-world recognition percentage or a
comparison with other products.

Pure Dart checks used the available Dart 3.13.2 SDK. The local runtime check ran
unmodified application runtime code with an injected controlled engine, the
vendored command/response/state definitions, and temporary platform descriptor
stubs. It covers lifecycle behavior, not native linkage or model quality.
Provider checks used offline requests/responses and storage fixtures. No live
provider call or credential was used. Syntax was parsed with Dart's formatter;
`git diff --check` passed. The replay script was checked for dry run, application,
idempotence and refusal to overwrite a modified target.

An additional tab-focus/query-preservation widget regression was added to
`test/app_test.dart` for the normal Flutter suite. It was not executed here.
No `flutter analyze`, `flutter test`, APK build, CI dispatch, model download or
physical Android QA was performed. Phone verification still needs to cover
push/pop flashes, keyboard/tab changes, long chat scrolling, and real Local AI
load/send/Stop/retry with the owner's installed models and device memory.

## Reapplying the complete change

`tool/apply_ui_ai_accuracy_upgrade.py` embeds the complete patch for this change
(excluding itself). Run it with `--repo PATH --check` to inspect compatibility,
then with `--repo PATH` to apply. It verifies every affected file before writing,
refuses changed or mixed versions, and is idempotent after a successful apply.
It does not reset files, commit, push, build or start workflows.

## Primary framework references

- [Scaffold backgroundColor](https://api.flutter.dev/flutter/material/Scaffold/backgroundColor.html)
- [MaterialPageRoute and opaque route behavior](https://api.flutter.dev/flutter/material/MaterialPageRoute-class.html)
- [BackdropFilter painting, overlap and cost](https://api.flutter.dev/flutter/widgets/BackdropFilter-class.html)
