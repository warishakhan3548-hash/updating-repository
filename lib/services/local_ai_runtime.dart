import 'dart:async';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';

/// One long-lived inference isolate. Calls are exclusive; a timed-out/cancelled
/// caller does not create a second native runtime while the first is draining.
/// Dispose is sent through the command stream so native weights are freed before
/// the worker is closed (killing an isolate alone can leak FFI allocations).
class LocalAiRuntime {
  final _commands = StreamController<LlamaCommand>();
  StreamSubscription<LlamaResponse>? _subscription;
  Completer<String>? _pending;
  final _text = StringBuffer();
  bool _loading = false, _closed = false;
  String? modelPath;

  bool get busy => _pending != null;

  void _start() {
    _subscription ??= const LibLlamaCpp()
        .transform(_commands.stream)
        .listen(
          (response) {
            if (response is LlamaErrorResponse) {
              _fail(StateError(response.message));
            } else if (response is LlamaTokenResponse) {
              if (_text.length < 32000) _text.write(response.text);
            } else if (response is LlamaStateChangedResponse && _loading) {
              _loading = false;
              modelPath = response.state.isModelLoaded
                  ? response.state.modelPath
                  : null;
              _complete();
            } else if (response is LlamaDoneResponse) {
              _complete();
            }
          },
          onError: (Object error) => _fail(error),
          onDone: () {
            _closed = true;
            modelPath = null;
            _fail(StateError('Local runtime closed. Reactivate the model.'));
          },
        );
  }

  void _complete() {
    final pending = _pending;
    _pending = null;
    if (pending != null && !pending.isCompleted)
      pending.complete(_text.toString());
  }

  void _fail(Object error) {
    final pending = _pending;
    _pending = null;
    _loading = false;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  Future<String> _run(LlamaCommand command) {
    if (_closed || busy)
      throw StateError('Local runtime is unavailable or still processing.');
    final pending = Completer<String>();
    _pending = pending;
    _text.clear();
    _start();
    _commands.add(command);
    return pending.future;
  }

  Future<void> load(String path) async {
    if (modelPath == path) return;
    _loading = true;
    await _run(
      LlamaLoadModelCommand(
        modelPath: path,
        contextSize: 8192,
        gpuLayerCount: 0,
      ),
    );
  }

  Future<String> generate(
    String system,
    String input, {
    int maxTokens = 1200,
  }) => _run(
    LlamaGenerateMessagesCommand(
      messages: [
        LlamaMessage(role: 'system', content: system),
        LlamaMessage(role: 'user', content: input),
      ],
      maxTokens: maxTokens,
      temperature: 0,
      topP: 1,
    ),
  );

  Future<void> close() async {
    if (_closed) return;
    final pending = _pending;
    if (pending != null) {
      try {
        await pending.future;
      } catch (_) {}
    }
    if (_closed) return;
    await _run(const LlamaDisposeCommand());
    modelPath = null;
    await _commands.close();
    await _subscription?.cancel();
    _closed = true;
  }
}
