import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'package:aaris_pharmacy/services/local_ai_runtime.dart';

class _ContextFallbackEngine implements LlamaEngine {
  final List<int> attemptedContexts = <int>[];

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    await for (final command in commands) {
      if (command is LlamaLoadModelCommand) {
        final context = command.contextSize ?? 0;
        attemptedContexts.add(context);
        if (context >= 4096) {
          // Mirrors NativeLlamaRuntime when llama_new_context_with_model returns
          // nullptr. The message does not necessarily contain generic OOM words.
          yield const LlamaErrorResponse(
            message: 'Failed to create llama.cpp context for: /test/large.gguf',
          );
        } else {
          yield LlamaStateChangedResponse(
            state: LlamaState(
              modelPath: command.modelPath,
              isModelLoaded: true,
            ),
          );
        }
        yield const LlamaDoneResponse();
        continue;
      }

      if (command is LlamaDisposeCommand) {
        yield const LlamaStateChangedResponse(state: LlamaState.empty());
        yield const LlamaDoneResponse();
        return;
      }

      yield const LlamaErrorResponse(message: 'Unexpected test command.');
      yield const LlamaDoneResponse();
    }
  }
}

void main() {
  test('native null-context load retries smaller context instead of false connection failure', () async {
    final engine = _ContextFallbackEngine();
    final runtime = LocalAiRuntime(engine: engine);

    await runtime.load('/test/large.gguf', contextTokens: 4096);

    expect(engine.attemptedContexts, <int>[4096, 3072]);
    expect(runtime.modelPath, '/test/large.gguf');
    expect(runtime.loadedContextTokens, 3072);

    await runtime.close();
  });
}
