# Universal cloud AI connections

The API editor now follows **Provider → API key → Connect & load models →
Choose model / Auto → Test & save**. The model name is a dropdown populated by
the provider. No model versions are bundled. Saved connections reopen with the
same model and API key; each provider has its own secure profile.

Built-in providers: Google Gemini, OpenAI, xAI/Grok, Groq, Anthropic/Claude,
Mistral, DeepSeek, OpenRouter, Together AI and Hugging Face. Meta/Llama is a model
family available through hosting providers such as Groq and Together; the user
chooses the company that issued their API key. Other OpenAI-compatible servers
use a one-time HTTPS base URL/full chat endpoint. Unusual gateways can specify a
same-origin Models URL under Advanced. Manual model IDs remain available there
when a provider does not support discovery or the key lacks listing permission.

Auto suggests a candidate from the fetched list and retains the selected model
while it is still listed. Refresh discovers future models without an APK change.
If the saved model disappears, Auto suggests a replacement; a manual selection
requires choosing another entry. A new choice becomes active only after
**Test & save**. Runtime requests keep the saved model and provider; there is no
silent cross-provider fallback, model switching, or key probing.

Catalog results are candidates, not proof of account access or quota. Explicit
capability metadata filters non-text models where available; unknown future
models remain testable. Embedding, image/audio-generation and other known
incompatible families are excluded. The app labels listing and test results
separately. The test sends a small synthetic request and no inventory; it may use
API credits. A successful reply confirms text inference access at that moment,
not guaranteed future quota, OCR accuracy, vision, JSON or streaming capability.
Current scanner refinement consumes OCR text, so it does not need a vision model.

## Integration and storage

- `AiProviderDefinition`: provider/protocol/endpoint registry, without keys/models.
- `AiConfiguration`: shared URI/auth validation and legacy secure-envelope reader.
- `AiDiscoveredModel`: normalization, text filtering, deduplication, stable choice.
- `AiModelDiscoveryService`: isolated cancellable HTTP listing/testing transport.
- `AiProviderAdapter`: shared Gemini, chat-completions and Anthropic Messages
  serialization/decoding for chat, scanner and connection testing.
- `AiConnectionStore`: serialized active/profile writes in platform secure storage.
- `CloudAiConnectionPanel`: key-first editor, dropdown, saved-provider restoration.

The active key `pharmacy.ai.configuration` stays compatible with scanner and local
routing readers. `pharmacy.ai.profile.<provider>` stores each provider's last
connection. The old active connection is archived when first switching providers.
Removing the active key also clears its profile copy. Existing version 1/2
configurations keep their streaming, JSON mode and response-timeout settings;
streaming and JSON controls remain under Advanced. Local Brain preference
changes read the current active record inside the write queue, avoiding stale
provider/key restoration. None of these records enter SQLite inventory exports.

Requests do not follow redirects or put keys in URLs. Custom discovery must use
the inference origin. Pagination accepts cursor tokens, never continuation URLs;
Gemini page tokens and Anthropic cursors are supported. Discovery has a 40-second
total deadline, a 4 MiB aggregate response cap, and bounded page/model counts.
Provider/key/endpoint edits invalidate outstanding requests and dropdown results.
HTTP/provider error bodies never appear in connection-editor error messages.

## Validation

Offline executable contracts:

```sh
dart tool/check_ai_connections.dart
dart tool/check_ai_model_discovery.dart
```

The second command needs the app's `http` dependency resolved. The checks cover
secure profile restoration/removal, queued writes, corrupted storage, model
filtering and selection, endpoint/auth handling, pagination/deduplication,
request cancellation, response/time bounds, redacted errors and adapter probes.
Validation in this change: 24 persistence/selection checks and 98 discovery/adapter
checks passed under Dart 3.13.2, with the official `http` 1.6.0 source. Dart
format parsing and `git diff --check` also passed. No real provider key is
included. Device UI, real account inference, full Flutter
analysis/tests and APK verification are separate gates.

## Official protocol references

- [OpenAI models](https://developers.openai.com/api/reference/resources/models/methods/list)
- [Gemini models](https://ai.google.dev/api/models)
- [Anthropic models](https://platform.claude.com/docs/en/api/models/list)
- [xAI models](https://docs.x.ai/developers/rest-api-reference/inference/models)
- [Groq models](https://console.groq.com/docs/models)
- [Mistral models](https://docs.mistral.ai/api/endpoint/models)
- [DeepSeek models](https://api-docs.deepseek.com/api/list-models)
- [OpenRouter user models](https://openrouter.ai/docs/api/api-reference/models/list-models-filtered-by-user-provider-preferences-privacy-settings-and-guardrails)
- [Together models](https://docs.together.ai/reference/models)
- [Hugging Face router models](https://huggingface.co/docs/inference-providers/main/hub-api)
