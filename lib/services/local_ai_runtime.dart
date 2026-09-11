import 'dart:async';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';

/// One long-lived local-AI lease with a restartable llama.cpp transport.
///
/// Calls remain exclusive. Explicit user cancellation retires the current
/// inference actor immediately, fails only that borrower, and invalidates every
/// late callback through the transport epoch. The next command waits for teardown
/// and then starts a fresh actor, so Stop never has to wait for a long generation
/// to naturally exhaust its token budget.
class LocalAiRuntime {
  LocalAiRuntime({LlamaEngine engine = const LibLlamaCpp()}) : _engine = engine;

  static const _terminalErrorDrainBudget = Duration(seconds: 15);
  static const _maxVisibleResponseCharacters = 32000;
  static const _maxRawResponseCharacters = 128000;
  static const _maxContextTokens = 32768;

  final LlamaEngine _engine;
  StreamController<LlamaCommand>? _commands;
  StreamSubscription<LlamaResponse>? _subscription;
  Completer<String>? _pending;
  final _text = StringBuffer();
  final _reasoningFilter = _ReasoningEnvelopeFilter();
  Object? _commandError;
  void Function(String token)? _onToken;
  bool _loading = false;
  bool _closed = false;
  bool _closing = false;
  Future<void>? _closeFuture;
  Future<void> _transportCleanup = Future<void>.value();
  Timer? _stallTimer;
  Duration? _activeStallBudget;
  int? _contextTokens;
  int _transportEpoch = 0;
  int _rawResponseCharacters = 0;
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
          // Keep the command lease until Done/onDone so a trailing completion can
          // never complete a later command. Once native has already declared an
          // error, however, waiting the normal multi-minute generation stall
          // budget for a missing Done only creates a false "connection stuck"
          // state. Give the native actor a short bounded drain window, then retire
          // the transport through the same epoch-safe recovery path.
          _commandError ??= StateError(response.message);
          _armStallWatchdog(epoch, _terminalErrorDrainBudget);
        } else if (response is LlamaTokenResponse) {
          _touchStallWatchdog(epoch);
          // Once native inference has failed, trailing tokens belong to the
          // failed command. Never flash them in the UI or retain them in the
          // response buffer while waiting for Done to close the lease.
          if (_commandError != null) return;
          _rawResponseCharacters += response.text.length;
          if (_rawResponseCharacters > _maxRawResponseCharacters) {
            _commandError ??= StateError(
              'Local model emitted too much raw output before completing the answer.',
            );
            _armStallWatchdog(epoch, _terminalErrorDrainBudget);
          } else {
            // Reasoning-capable GGUF models can emit a private <think>,
            // <analysis> or <reasoning> envelope before their actual answer.
            // Strip that envelope incrementally, including tags split across
            // native token boundaries. Hidden reasoning has its own larger raw
            // guard, while the user-visible answer keeps the strict 32K bound.
            // This lets reasoning-heavy models finish without exposing or
            // counting their private envelope as visible response text.
            _emitVisible(_reasoningFilter.add(response.text));
            if (_commandError != null) {
              _armStallWatchdog(epoch, _terminalErrorDrainBudget);
            }
          }
        } else if (response is LlamaStateChangedResponse) {
          _touchStallWatchdog(epoch);
          if (_loading) {
            _loading = false;
            modelPath = response.state.isModelLoaded
                ? response.state.modelPath
                : null;
          }
        } else if (response is LlamaToolCallResponse) {
          _commandError ??= StateError(
            'Return the app JSON contract, not native function calls.',
          );
          _armStallWatchdog(epoch, _terminalErrorDrainBudget);
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

  void _emitVisible(String value) {
    if (value.isEmpty || _commandError != null) return;
    if (_text.length + value.length > _maxVisibleResponseCharacters) {
      _commandError ??= StateError(
        'Local visible response exceeds the safety limit.',
      );
      return;
    }
    _text.write(value);
    // Emit only tokens owned by this transport epoch. A consumer callback is
    // observational and can never be allowed to crash inference.
    try {
      _onToken?.call(value);
    } catch (_) {}
  }

  Duration _stallBudgetFor(LlamaCommand command) {
    if (command is LlamaLoadModelCommand) return const Duration(minutes: 8);
    if (command is LlamaGenerateMessagesCommand) {
      return const Duration(minutes: 4);
    }
    return const Duration(minutes: 2);
  }

  /// There is deliberately no total-generation deadline. Slow local models are
  /// allowed to keep working for as long as they keep producing native progress.
  /// Only a completely silent/stalled transport is retired. This avoids the old
  /// false timeout where a healthy long answer crossed a wall-clock deadline.
  void _armStallWatchdog(int epoch, Duration budget) {
    _stallTimer?.cancel();
    _activeStallBudget = budget;
    _stallTimer = Timer(budget, () {
      if (_closed || epoch != _transportEpoch || _pending == null) return;
      final commands = _commands;
      final subscription = _subscription;
      if (commands == null || subscription == null) return;
      _invalidateTransport(
        epoch,
        commands,
        subscription,
        StateError(
          'Local runtime transport stopped making progress. The stalled transport was retired safely and can be retried.',
        ),
        StackTrace.current,
      );
    });
  }

  void _touchStallWatchdog(int epoch) {
    final budget = _activeStallBudget;
    if (budget == null ||
        _pending == null ||
        _closed ||
        epoch != _transportEpoch) {
      return;
    }
    _armStallWatchdog(epoch, budget);
  }

  void _clearStallWatchdog() {
    _stallTimer?.cancel();
    _stallTimer = null;
    _activeStallBudget = null;
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
    _clearStallWatchdog();
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
    _clearStallWatchdog();
    final pending = _pending;
    _loading = false;

    // Flush only a harmless undecided prefix (for example a short literal '<').
    // Ending while a private reasoning block is still open is treated as an
    // incomplete generation, never as a successful empty/partial pharmacy reply.
    final tail = _reasoningFilter.finish();
    if (_reasoningFilter.unterminated) {
      _commandError ??= StateError(
        'Local model ended inside a private reasoning block. Retrying is safe.',
      );
    } else {
      _emitVisible(tail);
    }

    _pending = null;
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
    _clearStallWatchdog();
    final pending = _pending;
    _pending = null;
    _loading = false;
    _commandError = null;
    _onToken = null;
    _rawResponseCharacters = 0;
    _reasoningFilter.reset();
    if (pending == null || pending.isCompleted) return;
    if (stack == null) {
      pending.completeError(error);
    } else {
      pending.completeError(error, stack);
    }
  }

  /// Cancels only the command currently holding this runtime lease.
  ///
  /// `LibLlamaCpp.transform` owns an inference isolate. Cancelling its stream
  /// subscription closes that actor and kills the isolate, so a long local
  /// generation is actually stopped instead of merely hiding its UI tokens.
  /// The epoch is invalidated before teardown, making any late native callbacks
  /// harmless. The selected model file is untouched and will be reloaded on the
  /// next request.
  bool cancelCurrentRequest() {
    if (_closed || _closing || _pending == null) return false;
    final commands = _commands;
    final subscription = _subscription;
    if (commands == null || subscription == null) {
      _fail(StateError('Local AI request cancelled.'), StackTrace.current);
      return true;
    }
    _invalidateTransport(
      _transportEpoch,
      commands,
      subscription,
      StateError('Local AI request cancelled.'),
      StackTrace.current,
    );
    return true;
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
    _reasoningFilter.reset();
    _rawResponseCharacters = 0;
    _commandError = null;
    _onToken = onToken;
    _loading = command is LlamaLoadModelCommand;

    try {
      _start();
      final commands = _commands;
      final subscription = _subscription;
      if (commands == null || subscription == null) {
        throw StateError('Local runtime transport could not start.');
      }
      _armStallWatchdog(_transportEpoch, _stallBudgetFor(command));
      commands.add(command);
    } catch (error, stack) {
      _clearStallWatchdog();
      _pending = null;
      _loading = false;
      _commandError = null;
      _onToken = null;
      _rawResponseCharacters = 0;
      _reasoningFilter.reset();
      pending.completeError(error, stack);
    }
    return pending.future;
  }

  List<int> _contextLoadPlan(int requested) {
    // Context is an adaptive quality knob, never a model-admission gate. Start
    // with the owner's/device planner choice and progressively reduce only the
    // KV-cache footprint when native allocation reports pressure. Flagship and
    // future high-memory devices can attempt 24K/32K, while every tier retains a
    // deterministic fallback ladder all the way to 2K instead of surfacing a
    // false connection failure after one oversized native allocation.
    final candidates = <int>[
      requested,
      if (requested > 24576) 24576,
      if (requested > 16384) 16384,
      if (requested > 12288) 12288,
      if (requested > 8192) 8192,
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
    // family rather than one library-version-specific message. llama.cpp can
    // also report a null context creation without allocator wording; retrying a
    // smaller n_ctx is bounded and persistent incompatibility still fails at 2K.
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
        value.contains('context buffer') ||
        value.contains('failed to create llama.cpp context');
  }

  Future<void> load(String path, {int contextTokens = 4096}) async {
    if (_closed || _closing || busy) {
      throw StateError('Local runtime is busy or closing.');
    }
    if (contextTokens < 2048 || contextTokens > _maxContextTokens) {
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
      _clearStallWatchdog();
      modelPath = null;
      _contextTokens = null;
      _onToken = null;
      _rawResponseCharacters = 0;
      _reasoningFilter.reset();
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

enum _ReasoningEnvelopeState { undecided, hidden, visible }

/// Streaming sanitizer for local models that expose a leading private reasoning
/// envelope as ordinary text tokens. Only a leading known envelope is removed;
/// later literal markup in the user's visible answer is left untouched.
class _ReasoningEnvelopeFilter {
  static const _envelopes = <String, String>{
    '<think>': '</think>',
    '<analysis>': '</analysis>',
    '<reasoning>': '</reasoning>',
  };

  _ReasoningEnvelopeState _state = _ReasoningEnvelopeState.undecided;
  String _pending = '';
  String? _closingTag;
  bool unterminated = false;

  void reset() {
    _state = _ReasoningEnvelopeState.undecided;
    _pending = '';
    _closingTag = null;
    unterminated = false;
  }

  String add(String chunk) {
    if (chunk.isEmpty) return '';
    if (_state == _ReasoningEnvelopeState.visible) return chunk;
    if (_state == _ReasoningEnvelopeState.hidden) {
      return _consumeHidden(chunk);
    }

    _pending += chunk;
    final candidate = _pending.trimLeft();
    if (candidate.isEmpty) return '';
    final lower = candidate.toLowerCase();

    for (final entry in _envelopes.entries) {
      if (!lower.startsWith(entry.key)) continue;
      _state = _ReasoningEnvelopeState.hidden;
      _closingTag = entry.value;
      _pending = candidate.substring(entry.key.length);
      return _consumeHidden('');
    }

    // Opening tags can be split across arbitrarily small native token chunks.
    // Keep only the tiny undecided prefix until it can be proven ordinary text.
    if (_envelopes.keys.any((tag) => tag.startsWith(lower))) return '';

    _state = _ReasoningEnvelopeState.visible;
    final visible = _pending;
    _pending = '';
    return visible;
  }

  String _consumeHidden(String chunk) {
    _pending += chunk;
    final closing = _closingTag!;
    final index = _pending.toLowerCase().indexOf(closing);
    if (index >= 0) {
      final remainder = _pending.substring(index + closing.length);
      _pending = '';
      _closingTag = null;
      _state = _ReasoningEnvelopeState.undecided;
      // A few reasoning models emit more than one private envelope. Re-enter the
      // undecided state so consecutive leading envelopes are removed as well.
      return remainder.isEmpty ? '' : add(remainder);
    }

    // Hidden reasoning itself is intentionally discarded. Preserve only enough
    // suffix to recognize a closing tag split across the next token boundary.
    final keep = closing.length - 1;
    if (_pending.length > keep) {
      _pending = _pending.substring(_pending.length - keep);
    }
    return '';
  }

  String finish() {
    if (_state == _ReasoningEnvelopeState.hidden) {
      unterminated = true;
      _pending = '';
      return '';
    }
    if (_state == _ReasoningEnvelopeState.undecided) {
      _state = _ReasoningEnvelopeState.visible;
      final visible = _pending;
      _pending = '';
      return visible;
    }
    return '';
  }
}
