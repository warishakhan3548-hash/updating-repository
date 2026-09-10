import 'dart:async';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';

/// One long-lived local-AI lease with a restartable llama.cpp transport.
///
/// Calls remain exclusive: a timed-out/cancelled native command must finish
/// before another command can borrow the lease. Transport failure is different:
/// the failed inference stream is discarded, its callbacks are invalidated by
/// an epoch, and the next load can create a fresh inference isolate without
/// forcing the user to disable/re-enable the selected model.
class LocalAiRuntime {
  LocalAiRuntime({LlamaEngine engine = const LibLlamaCpp()}) : _engine = engine;

  final LlamaEngine _engine;
  StreamController<LlamaCommand>? _commands;
  StreamSubscription<LlamaResponse>? _subscription;
  Completer<String>? _pending;
  final _text = StringBuffer();
  Object? _commandError;
  void Function(String token)? _onToken;
  bool _loading = false;
  bool _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  Future<void> _transportCleanup = Future<void>.value();
  int? _contextTokens;
  int _transportEpoch = 0;
  String? modelPath;

  bool get busy => _pending != null;
  bool get available => !_closed && !_closing;
  int? get loadedContextTokens => _contextTokens;

  void _start() {
    if (_subscription != null) return;
    if (_closed || _closing) {
      throw StateError('Local runtime is unavailable or closing.');
    }

    final epoch = ++_transportEpoch;
    final commands = StreamController<LlamaCommand>();
    _commands = commands;
    late final StreamSubscription<LlamaResponse> subscription;
    subscription = _engine.transform(commands.stream).listen(
      (response) {
        if (_closed || epoch != _transportEpoch) return;
        if (response is LlamaErrorResponse) {
          // Keep the command lease until Done/onDone. A trailing completion from
          // this transport can therefore never complete a later command.
          _commandError ??= StateError(response.message);
        } else if (response is LlamaTokenResponse) {
          // Once native inference has failed, trailing tokens belong to the
          // failed command. Never flash them in the UI or retain them in the
          // response buffer while waiting for Done to close the lease.
          if (_commandError != null) return;
          if (_text.length + response.text.length > 32000) {
            _commandError ??= StateError(
              'Local response exceeds the safety limit.',
            );
          } else {
            _text.write(response.text);
            // Emit only tokens owned by this transport epoch. A consumer callback
            // is observational and can never be allowed to crash inference.
            try {
              _onToken?.call(response.text);
            } catch (_) {}
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
      onError: (Object error, StackTrace stack) {
        _invalidateTransport(
          epoch,
          commands,
          subscription,
          error,
          stack,
        );
      },
      onDone: () {
        if (_closed || epoch != _transportEpoch) return;
        _invalidateTransport(
          epoch,
          commands,
          subscription,
          _commandError ??
              StateError(
                'Local runtime transport closed unexpectedly. Retrying is safe.',
              ),
          StackTrace.current,
        );
      },
      cancelOnError: false,
    );
    _subscription = subscription;
  }

  void _invalidateTransport(
    int epoch,
    StreamController<LlamaCommand> commands,
    StreamSubscription<LlamaResponse> subscription,
    Object error,
    StackTrace stack,
  ) {
    if (_closed || epoch != _transportEpoch) return;

    // Invalidate callbacks from this stream before failing its borrower. The
    // same LocalAiRuntime object can then safely start a brand-new transport on
    // the next load, while stale Done/onDone events become harmless.
    ++_transportEpoch;
    if (identical(_commands, commands)) _commands = null;
    if (identical(_subscription, subscription)) _subscription = null;
    modelPath = null;
    _contextTokens = null;
    _fail(error, stack);
    _queueTransportCleanup(commands, subscription);
  }

  void _queueTransportCleanup(
    StreamController<LlamaCommand>? commands,
    StreamSubscription<LlamaResponse>? subscription,
  ) {
    final previous = _transportCleanup;
    _transportCleanup = () async {
      try {
        await previous;
      } catch (_) {}
      await _disposeTransport(commands, subscription);
    }();
  }

  Future<void> _disposeTransport(
    StreamController<LlamaCommand>? commands,
    StreamSubscription<LlamaResponse>? subscription,
  ) async {
    try {
      await subscription?.cancel();
    } catch (_) {}
    try {
      await commands?.close();
    } catch (_) {}
  }

  /// A failed native load can leave allocator/KV-cache state attached to the
  /// current transform even though its command completed. Before retrying a
  /// smaller context, retire that transport completely and invalidate every
  /// late callback. The model file itself is untouched.
  Future<void> _restartTransportAfterLoadFailure() async {
    if (busy) {
      throw StateError('Local runtime is still processing a failed model load.');
    }
    ++_transportEpoch;
    final commands = _commands;
    final subscription = _subscription;
    _commands = null;
    _subscription = null;
    modelPath = null;
    _contextTokens = null;
    _queueTransportCleanup(commands, subscription);
    await _transportCleanup;
  }

  void _complete() {
    final pending = _pending;
    _pending = null;
    _loading = false;
    _onToken = null;
    if (pending != null && !pending.isCompleted) {
      final error = _commandError;
      if (error != null) {
        pending.completeError(error);
      } else {
        pending.complete(_text.toString());
      }
    }
    _commandError = null;
  }

  void _fail(Object error, [StackTrace? stack]) {
    final pending = _pending;
    _pending = null;
    _loading = false;
    _commandError = null;
    _onToken = null;
    if (pending == null || pending.isCompleted) return;
    if (stack == null) {
      pending.completeError(error);
    } else {
      pending.completeError(error, stack);
    }
  }

  Future<String> _run(
    LlamaCommand command, {
    bool disposing = false,
    void Function(String token)? onToken,
  }) async {
    if (_closed || busy || (_closing && !disposing)) {
      throw StateError('Local runtime is unavailable or still processing.');
    }

    // Stream callbacks retire failed transforms asynchronously. Serialize that
    // teardown with the next command so a fresh llama.cpp actor can never race
    // a previous subscription/controller that is still closing.
    await _transportCleanup;
    if (_closed || busy || (_closing && !disposing)) {
      throw StateError('Local runtime is unavailable or still processing.');
    }

    final pending = Completer<String>();
    _pending = pending;
    _text.clear();
    _commandError = null;
    _onToken = onToken;
    _loading = command is LlamaLoadModelCommand;

    try {
      _start();
      final commands = _commands;
      if (commands == null) {
        throw StateError('Local runtime transport could not start.');
      }
      commands.add(command);
    } catch (error, stack) {
      _pending = null;
      _loading = false;
      _commandError = null;
      _onToken = null;
      pending.completeError(error, stack);
    }
    return pending.future;
  }

  List<int> _contextLoadPlan(int requested) {
    // Context is an adaptive quality knob, never a model-admission gate. Start
    // with the owner's/device planner choice and progressively reduce only the
    // KV-cache footprint when native allocation reports pressure. This lets
    // high-end phones actually use 6K/8K contexts while giving the same model a
    // path down to 2K on tighter devices instead of surfacing a false generic
    // connection failure after one retry.
    final candidates = <int>[
      requested,
      if (requested > 6144) 6144,
      if (requested > 4096) 4096,
      if (requested > 3072) 3072,
      if (requested > 2048) 2048,
    ];
    final seen = <int>{};
    return [
      for (final value in candidates)
        if (value >= 2048 && value <= requested && seen.add(value)) value,
    ];
  }

  bool _isResourceLoadFailure(Object error) {
    final value = error.toString().toLowerCase();
    // Retry only allocator/context/KV-cache pressure. Corrupt GGUF,
    // architecture, tokenizer and other compatibility failures remain fail-fast
    // so a bad model is never disguised as a low-memory phone. Native backends
    // use several allocator spellings across releases, so recognize the bounded
    // family rather than one library-version-specific message.
    return value.contains('out of memory') ||
        value.contains('not enough memory') ||
        value.contains('memory allocation') ||
        value.contains('cannot allocate') ||
        value.contains('failed to allocate') ||
        value.contains('alloc failed') ||
        value.contains('bad_alloc') ||
        value.contains('failed to reserve') ||
        value.contains('buffer allocation') ||
        value.contains('backend buffer') ||
        value.contains('kv cache') ||
        value.contains('kv_cache') ||
        value.contains('context size') ||
        value.contains('context buffer');
  }

  Future<void> load(String path, {int contextTokens = 4096}) async {
    if (_closed || _closing || busy) {
      throw StateError('Local runtime is busy or closing.');
    }
    if (contextTokens < 2048 || contextTokens > 8192) {
      throw ArgumentError('Unsupported context budget.');
    }
    if (modelPath == path && _contextTokens == contextTokens) return;

    modelPath = null;
    _contextTokens = null;
    final plan = _contextLoadPlan(contextTokens);
    Object? lastError;
    StackTrace? lastStack;

    for (var index = 0; index < plan.length; index++) {
      final budget = plan[index];
      try {
        await _run(
          LlamaLoadModelCommand(
            modelPath: path,
            contextSize: budget,
            gpuLayerCount: 0,
          ),
        );
        if (modelPath != path) {
          throw StateError('Native model did not become ready.');
        }
        _contextTokens = budget;
        return;
      } catch (error, stack) {
        modelPath = null;
        _contextTokens = null;
        lastError = error;
        lastStack = stack;
        final retryWithSmallerContext =
            index + 1 < plan.length && _isResourceLoadFailure(error);
        if (!retryWithSmallerContext) rethrow;
        await _restartTransportAfterLoadFailure();
      }
    }

    final error = lastError ?? StateError('Native model did not become ready.');
    Error.throwWithStackTrace(error, lastStack ?? StackTrace.current);
  }

  Future<String> generate(
    String system,
    String input, {
    int maxTokens = 1200,
    void Function(String token)? onToken,
  }) {
    if (maxTokens <= 0 || maxTokens > 2048) {
      throw ArgumentError('Invalid output token budget.');
    }
    if (modelPath == null) {
      throw StateError('Load a local model before generating.');
    }
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
      onToken: onToken,
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
      // Dispose through the healthy command stream so native weights are freed
      // before its inference isolate exits. A previously failed transport has
      // already closed its actor, so there is nothing left to dispose there.
      if (!_closed && _subscription != null) {
        try {
          await _run(const LlamaDisposeCommand(), disposing: true);
        } catch (_) {}
      } else {
        await _transportCleanup;
      }
    } finally {
      modelPath = null;
      _contextTokens = null;
      _onToken = null;
      _closed = true;
      ++_transportEpoch;
      final commands = _commands;
      final subscription = _subscription;
      _commands = null;
      _subscription = null;
      _queueTransportCleanup(commands, subscription);
      await _transportCleanup;
    }
  }
}
