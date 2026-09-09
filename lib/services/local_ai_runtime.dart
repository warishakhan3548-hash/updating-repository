import 'dart:async';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';

/// One long-lived inference isolate. Calls are exclusive; a timed-out/cancelled
/// caller does not create a second native runtime while the first is draining.
/// Dispose is sent through the command stream so native weights are freed before
/// the worker is closed (killing an isolate alone can leak FFI allocations).
class LocalAiRuntime {
  LocalAiRuntime({LlamaEngine engine = const LibLlamaCpp()}) : _engine = engine;
  final LlamaEngine _engine;
  final _commands = StreamController<LlamaCommand>();
  StreamSubscription<LlamaResponse>? _subscription;
  Completer<String>? _pending;
  final _text = StringBuffer();
  Object? _commandError;
  bool _loading = false, _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  int? _contextTokens;
  String? modelPath;

  bool get busy => _pending != null;

  void _start() {
    _subscription ??= _engine
        .transform(_commands.stream)
        .listen(
          (response) {
            if (_closed) return;
            if (response is LlamaErrorResponse) {
              // Do not release the lease before this command's Done event;
              // otherwise its trailing completion could finish the next call.
              _commandError ??= StateError(response.message);
            } else if (response is LlamaTokenResponse) {
              if (_text.length + response.text.length > 32000) {
                _commandError ??= StateError(
                  'Local response exceeds the safety limit.',
                );
              } else {
                _text.write(response.text);
              }
            } else if (response is LlamaStateChangedResponse && _loading) {
              _loading = false;
              modelPath = response.state.isModelLoaded
                  ? response.state.modelPath
                  : null;
            } else if (response is LlamaToolCallResponse) {
              _commandError ??= StateError(
                'Return the app JSON contract, not native function calls.',
              );
            } else if (response is LlamaDoneResponse) {
              _complete();
            }
          },
          onError: (Object error) {
            // A transport error has no command ID or trustworthy trailing Done.
            // Poison this runtime; never lend the lease to a later request.
            _closed = true;
            modelPath = null;
            _fail(error);
          },
          onDone: () {
            _closed = true;
            modelPath = null;
            _fail(
              _commandError ??
                  StateError('Local runtime closed. Reactivate the model.'),
            );
          },
        );
  }

  void _complete() {
    final pending = _pending;
    _pending = null;
    _loading = false;
    if (pending != null && !pending.isCompleted) {
      final error = _commandError;
      if (error != null)
        pending.completeError(error);
      else
        pending.complete(_text.toString());
    }
    _commandError = null;
  }

  void _fail(Object error) {
    final pending = _pending;
    _pending = null;
    _loading = false;
    if (pending != null && !pending.isCompleted) pending.completeError(error);
  }

  Future<String> _run(LlamaCommand command, {bool disposing = false}) {
    if (_closed || busy || (_closing && !disposing))
      throw StateError('Local runtime is unavailable or still processing.');
    final pending = Completer<String>();
    _pending = pending;
    _text.clear();
    _commandError = null;
    _loading = command is LlamaLoadModelCommand;
    _start();
    _commands.add(command);
    return pending.future;
  }

  Future<void> load(String path, {int contextTokens = 4096}) async {
    if (_closed || _closing || busy)
      throw StateError('Local runtime is busy or closing.');
    if (contextTokens < 2048 || contextTokens > 8192)
      throw ArgumentError('Unsupported context budget.');
    if (modelPath == path && _contextTokens == contextTokens) return;
    modelPath = null;
    _contextTokens = null;
    try {
      await _run(
        LlamaLoadModelCommand(
          modelPath: path,
          contextSize: contextTokens,
          gpuLayerCount: 0,
        ),
      );
      if (modelPath != path)
        throw StateError('Native model did not become ready.');
      _contextTokens = contextTokens;
    } catch (_) {
      modelPath = null;
      rethrow;
    }
  }

  Future<String> generate(String system, String input, {int maxTokens = 1200}) {
    if (maxTokens <= 0 || maxTokens > 2048)
      throw ArgumentError('Invalid output token budget.');
    if (modelPath == null)
      throw StateError('Load a local model before generating.');
    return _run(
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
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    _closing = true;
    final pending = _pending;
    if (pending != null) {
      try {
        await pending.future;
      } catch (_) {}
    }
    try {
      if (!_closed && _subscription != null)
        await _run(const LlamaDisposeCommand(), disposing: true);
    } finally {
      modelPath = null;
      _contextTokens = null;
      _closed = true;
      // Closing a never-listened single-subscription controller does not finish
      // until a listener appears. It owns no engine in that case.
      if (_subscription == null) {
        unawaited(_commands.close());
      } else {
        unawaited(_commands.close());
        await _subscription?.cancel();
      }
    }
  }
}
