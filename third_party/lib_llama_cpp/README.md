# Aaris in-process runtime core

Vendored from the MIT-licensed `lib_llama_cpp` 0.7.3 pub package, upstream
https://github.com/gsmlg-app/lib_llama_cpp. Original license is preserved in
`LICENSE`. Only its command/inference core is included; the OpenAI-compatible
client and server exports/dependency are deliberately omitted. Native platform
artifacts and FFI bindings stay pinned to upstream 0.7.3.

Local fixes, directly in the runtime (no package overrides or stacked adapters):

- Emit exactly one completion response per dispatched command, including normal
  generation and failure. Upstream emitted it only for dispose; a persistent
  command-stream consumer otherwise cannot know when a generation finishes.
- Clear native sequence/KV memory before each independent full prompt while
  retaining loaded weights. Otherwise consecutive scans/tool rounds accumulate
  stale tokens and can contaminate the next medicine or exhaust the context.

The application waits for command completion even after error/state events;
it cannot accidentally treat the previous command's completion as a new reply.
See `tool/check_local_ai_runtime.dart` for executable lifecycle regression checks.
Real-device native inference still requires the release checks in
`docs/LOCAL_AI_ROADMAP.md` at the repository root.
