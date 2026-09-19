# Local chat response investigation

The supplied screenshot shows an AI Controller chat timeout. Its selected-model
caption identifies `lm-kit/gemma-3-1b-instruct-gguf`; that is a 1B model, not
Gemma 3 270M. The exact installed APK revision, quantization and phone runtime
trace are not available. These changes fix demonstrated code defects; they do
not claim to reproduce or fully resolve that handset's inference failure.

## Execution and UI map

| Entry or stage | Owner | Connection and effect |
| --- | --- | --- |
| Intake OCR question in the screenshot | `MedicineIntakePanel.onAsk` in `lib/ui/ai_screen.dart` | Creates an explanation/stock question with OCR and calls `_ask`. This enters chat, not `LocalScanHandoff`. |
| Chat Send | `AiService.ask` | Chooses the enabled local route; cloud does not receive a local request. |
| Local model lease | `LocalAiService.ask` | Loads the selected GGUF, keeps cancellation ownership and calls `runLocalChatTurn`. |
| Chat prompt and read tools | `lib/services/local_chat_turn.dart`, `LocalInventoryContext` | Ordinary inventory questions retain bounded tools, original instructions and reviewed proposals. Standalone greetings now get only a short system prompt and their own text. |
| Native generation | `LocalAiRuntime` and vendored `lib_llama_cpp` | CPU inference (`gpuLayerCount: 0`) with fresh prompt context; a native deadline retires the actor and rejects late callbacks. |
| Answer/error | `AiScreen._friendlyAiError` and existing response validation | Local timeout details now survive presentation. Inventory writes still require the normal review gate. |

The separate medicine scan-review pipeline remains OCR -> deterministic draft
-> optional `LocalAiService.understand` -> quoted-evidence validation -> review.
Its local/cloud shared scan prompt is unchanged. No new model, runtime or download
has been added.

## Confirmed defects and changes

1. `Hi` previously received the full inventory system instructions and summary.
   Capping its output alone did not reduce the input processing work. Exact,
   standalone greetings and small talk now use 141 system-prompt characters
   instead of 2,729 in the controlled example. This is a character comparison,
   not a device speed benchmark. Output is capped at 96 tokens. The actual model
   supplies the answer; there is no canned greeting response.
2. A greeting does not replay earlier inventory instructions or data. This does
   not erase the visible conversation or other turns' history. Any tool call or
   nonempty action list returned on this lane is rejected in code. Requests such
   as `hi add paracetamol`, ordinary follow-ups and the screenshot's OCR question
   retain the complete inventory path.
3. A generation deadline could replace an already received native error while
   the failed command was still draining. A controlled reproduction failed on
   the original code and passed after preserving `_commandError` at this boundary.
   Context/allocation/parser failures can therefore retain their actual cause.
4. Local generation timeouts now distinguish no token progress, output without a
   readable reply, and a reply that started but did not finish. The UI no longer
   replaces these with one generic timeout message. Progress resets per command;
   errors contain no prompts, OCR, paths or hidden reasoning. These observations
   do not by themselves prove which native computation was slow or why.
5. A failed optional extraction generation previously escaped `activate()` and
   undid a successful model load. This could prevent even a short chat from
   reaching the model. Extraction timeouts/context/native generation errors now
   leave the load-tested model selected with the existing scan warning and no
   scan-verification authority. Subsequent chat can reload a retired runtime.
   Actual load/hash failures remain fatal; Stop/model changes still abort setup.
   The successful seven-probe suite, prompts and evidence checks are unchanged.

## Verification

- `tool/check_local_chat_response.dart`: 89 checks of compact handoffs, real model
  callback delivery, history isolation, mutation/tool rejection, unchanged stock
  reads, bounded empty-response recovery and timeout classification/reset.
- `tool/check_local_ai_error_drain.dart`: 12 checks including native-error versus
  deadline ordering, stale traffic, cancellation, transport retirement/reload.
- `tool/check_local_ai.dart`: 70 existing contract and medicine evidence checks.
- `tool/check_local_scan_probe.dart`: 25 checks of advisory extraction failures,
  the unchanged successful suite, malformed output and cancellation. The old
  optional-generation behavior reproduced a fatal timeout before the fix.
- Total: 196 focused Dart checks. Runtime lifecycle checks use a controlled native
  boundary, not a real GGUF. No Flutter test suite, analyzer or APK build ran.

## Remaining phone verification

Google AI Edge Gallery documents LiteRT, while this app uses GGUF through
llama.cpp. Gallery working on the same phone is useful evidence against a blanket
claim that the phone cannot run local AI. It does not establish equivalent
quantization, backend, prompt or response speed between the two applications.

With an APK containing this change, compare a fresh `Hi`, `How are you?`, and the
same OCR stock question. Record the exact model/quantization, cold versus warm
load, elapsed time and the now-specific error if generation still fails. The
matching GGUF and a physical 4 GB/2 GB device were unavailable here. No accuracy
gain, universal 2 GB support or handset performance improvement is certified.

References: [Google AI Edge Gallery](https://github.com/google-ai-edge/gallery),
[Gemma 3 model card](https://ai.google.dev/gemma/docs/core/model_card_3).

## Replay

`python3 tool/apply_local_chat_response_fix.py --repo /path/to/repository`

The complete embedded patch verifies before/after file hashes, refuses divergent
or symlink targets, and is idempotent. `--check` verifies without writing. It does
not commit, push, download a model or build an APK.

For the subsequent activation-probe fix from the first published chat-fix commit:
`python3 tool/apply_scan_probe_readiness_fix.py --repo /path/to/repository`.
