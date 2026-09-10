import 'dart:async';
import 'dart:isolate';

import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import 'llama_command.dart';
import 'llama_response.dart';
import 'llama_state.dart';
import 'native_runtime.dart';

final class InferenceIsolate {
  InferenceIsolate._({
    required Isolate isolate,
    required SendPort commandPort,
    required StreamSubscription<Object?> subscription,
  }) : _isolate = isolate,
       _commandPort = commandPort,
       _subscription = subscription;

  static const _startupTimeout = Duration(seconds: 20);
  static const _gracefulShutdownTimeout = Duration(seconds: 90);

  final Isolate _isolate;
  final SendPort _commandPort;
  final StreamSubscription<Object?> _subscription;
  final Map<int, StreamController<LlamaResponse>> _pending = {};
  final Completer<void> _workerStopped = Completer<void>();
  var _nextRequestId = 0;
  var _isClosed = false;
  Future<void>? _closeFuture;

  static Future<InferenceIsolate> spawn({
    required LlamaCppLibraryDescriptor library,
    required LlamaState initialState,
  }) async {
    final ready = Completer<SendPort>();
    final receivePort = ReceivePort();
    late final StreamSubscription<Object?> subscription;
    late final InferenceIsolate actor;

    subscription = receivePort.listen((message) {
      if (message is SendPort) {
        if (!ready.isCompleted) ready.complete(message);
        return;
      }

      if (message is _WorkerStoppedMessage) {
        if (!actor._workerStopped.isCompleted) actor._workerStopped.complete();
        return;
      }

      if (message is _ResponseEnvelope) {
        final controller = actor._pending[message.requestId];
        if (controller == null) {
          return;
        }
        if (message.response != null) {
          controller.add(message.response!);
        }
        if (message.isDone) {
          actor._pending.remove(message.requestId);
          unawaited(controller.close());
        }
      }
    });

    Isolate? isolate;
    try {
      isolate = await Isolate.spawn(
        _runInferenceWorker,
        _StartMessage(
          replyPort: receivePort.sendPort,
          library: library,
          initialState: initialState,
        ),
        debugName: 'lib_llama_cpp_inference',
      );

      final commandPort = await ready.future.timeout(
        _startupTimeout,
        onTimeout: () => throw TimeoutException(
          'Local inference worker did not become ready.',
          _startupTimeout,
        ),
      );
      actor = InferenceIsolate._(
        isolate: isolate,
        commandPort: commandPort,
        subscription: subscription,
      );
      return actor;
    } catch (_) {
      await subscription.cancel();
      receivePort.close();
      isolate?.kill(priority: Isolate.immediate);
      rethrow;
    }
  }

  Stream<LlamaResponse> dispatch(LlamaCommand command) {
    if (_isClosed) {
      return Stream<LlamaResponse>.value(
        const LlamaErrorResponse(message: 'Inference isolate is closed.'),
      );
    }

    final requestId = _nextRequestId++;
    late final StreamController<LlamaResponse> controller;
    controller = StreamController<LlamaResponse>(
      onCancel: () {
        // A cancelled consumer no longer needs response frames, but the worker
        // still owns native model/context memory. Ask it to stop at the next
        // cooperative generation boundary instead of killing the isolate around
        // live FFI allocations.
        if (_pending.remove(requestId) != null && !_isClosed) {
          _commandPort.send(_CancelEnvelope(requestId: requestId));
        }
      },
    );
    _pending[requestId] = controller;
    _commandPort.send(_CommandEnvelope(requestId: requestId, command: command));
    return controller.stream;
  }

  Future<void> close() => _closeFuture ??= _close();

  Future<void> _close() async {
    if (_isClosed) return;
    _isClosed = true;

    // Stop every outstanding command cooperatively first. The worker will drain
    // its active generator through native finally blocks, then free model/context
    // allocations and acknowledge shutdown. Only a truly wedged worker reaches
    // the bounded hard-kill fallback below.
    for (final requestId in _pending.keys.toList(growable: false)) {
      _commandPort.send(_CancelEnvelope(requestId: requestId));
    }
    _commandPort.send(const _ShutdownMessage());

    final controllers = _pending.values.toList(growable: false);
    _pending.clear();
    for (final controller in controllers) {
      await controller.close();
    }

    try {
      await _workerStopped.future.timeout(_gracefulShutdownTimeout);
    } on TimeoutException {
      _isolate.kill(priority: Isolate.immediate);
    } finally {
      await _subscription.cancel();
    }
  }
}

final class _StartMessage {
  const _StartMessage({
    required this.replyPort,
    required this.library,
    required this.initialState,
  });

  final SendPort replyPort;
  final LlamaCppLibraryDescriptor library;
  final LlamaState initialState;
}

final class _CommandEnvelope {
  const _CommandEnvelope({required this.requestId, required this.command});

  final int requestId;
  final LlamaCommand command;
}

final class _CancelEnvelope {
  const _CancelEnvelope({required this.requestId});

  final int requestId;
}

final class _ResponseEnvelope {
  const _ResponseEnvelope({
    required this.requestId,
    this.response,
    this.isDone = false,
  });

  final int requestId;
  final LlamaResponse? response;
  final bool isDone;
}

final class _ShutdownMessage {
  const _ShutdownMessage();
}

final class _WorkerStoppedMessage {
  const _WorkerStoppedMessage();
}

void _runInferenceWorker(_StartMessage start) {
  var state = start.initialState;
  NativeLlamaRuntime? runtime;
  String? startupError;
  try {
    runtime = NativeLlamaRuntime(library: start.library);
  } on NativeLlamaException catch (error) {
    startupError = error.message;
  } on Object catch (error) {
    startupError = 'Failed to initialize llama.cpp runtime: $error';
  }

  final receivePort = ReceivePort();
  start.replyPort.send(receivePort.sendPort);
  final cancelled = <int>{};
  final queued = <int>{};
  var shuttingDown = false;
  var shutdownAcknowledged = false;
  Future<void> serial = Future<void>.value();

  void send(int requestId, LlamaResponse response) {
    start.replyPort.send(
      _ResponseEnvelope(requestId: requestId, response: response),
    );
  }

  void done(int requestId) {
    // Public command-stream consumers need a terminal event for every command,
    // not just dispose. Send after all state/text/error responses have drained.
    send(requestId, const LlamaDoneResponse());
    start.replyPort.send(_ResponseEnvelope(requestId: requestId, isDone: true));
  }

  Future<void> runCommand(_CommandEnvelope message) async {
    final requestId = message.requestId;
    try {
      if (cancelled.contains(requestId)) return;
      final command = message.command;
      switch (command) {
        case LlamaLoadModelCommand():
          if (startupError != null || runtime == null) {
            send(requestId, LlamaErrorResponse(message: startupError!));
          } else {
            try {
              state = runtime.loadModel(command);
              if (!cancelled.contains(requestId)) {
                send(requestId, LlamaStateChangedResponse(state: state));
              }
            } on NativeLlamaException catch (error) {
              if (!cancelled.contains(requestId)) {
                send(requestId, LlamaErrorResponse(message: error.message));
              }
            } on Object catch (error) {
              if (!cancelled.contains(requestId)) {
                send(
                  requestId,
                  LlamaErrorResponse(message: 'Failed to load model: $error'),
                );
              }
            }
          }
        case LlamaGenerateCommand():
          if (!state.isModelLoaded || runtime == null) {
            send(
              requestId,
              const LlamaErrorResponse(
                message: 'Cannot generate before a model is loaded.',
              ),
            );
          } else {
            try {
              for (final response in runtime.generate(
                command,
                shouldAbort: () => cancelled.contains(requestId),
              )) {
                if (!cancelled.contains(requestId)) send(requestId, response);
                // Give ReceivePort cancellation/shutdown messages a chance to
                // run between sampled output frames. Native generation checks
                // the shared flag before its next decode step.
                await Future<void>.delayed(Duration.zero);
              }
            } on NativeLlamaException catch (error) {
              if (!cancelled.contains(requestId)) {
                send(requestId, LlamaErrorResponse(message: error.message));
              }
            } on Object catch (error) {
              if (!cancelled.contains(requestId)) {
                send(
                  requestId,
                  LlamaErrorResponse(message: 'Generation failed: $error'),
                );
              }
            }
          }
        case LlamaGenerateMessagesCommand():
          if (!state.isModelLoaded || runtime == null) {
            send(
              requestId,
              const LlamaErrorResponse(
                message: 'Cannot generate before a model is loaded.',
              ),
            );
          } else {
            try {
              for (final response in runtime.generateMessages(
                command,
                shouldAbort: () => cancelled.contains(requestId),
              )) {
                if (!cancelled.contains(requestId)) send(requestId, response);
                await Future<void>.delayed(Duration.zero);
              }
            } on NativeLlamaException catch (error) {
              if (!cancelled.contains(requestId)) {
                send(requestId, LlamaErrorResponse(message: error.message));
              }
            } on Object catch (error) {
              if (!cancelled.contains(requestId)) {
                send(
                  requestId,
                  LlamaErrorResponse(message: 'Generation failed: $error'),
                );
              }
            }
          }
        case LlamaDisposeCommand():
          runtime?.disposeModel();
          state = const LlamaState.empty();
          if (!cancelled.contains(requestId)) {
            send(requestId, LlamaStateChangedResponse(state: state));
          }
      }
    } finally {
      cancelled.remove(requestId);
      queued.remove(requestId);
      done(requestId);
    }
  }

  void acknowledgeShutdownWhenDrained() {
    if (shutdownAcknowledged) return;
    shutdownAcknowledged = true;
    final drain = serial;
    unawaited(
      drain.whenComplete(() {
        try {
          runtime?.close();
        } finally {
          start.replyPort.send(const _WorkerStoppedMessage());
          receivePort.close();
        }
      }),
    );
  }

  receivePort.listen((message) {
    if (message is _CancelEnvelope) {
      cancelled.add(message.requestId);
      return;
    }

    if (message is _ShutdownMessage) {
      if (shuttingDown) return;
      shuttingDown = true;
      // Include queued-but-not-started work as well as the active command. Each
      // serial handler will short-circuit or observe cancellation at its next
      // cooperative boundary before shutdown frees the native runtime.
      cancelled.addAll(queued);
      acknowledgeShutdownWhenDrained();
      return;
    }

    if (message is! _CommandEnvelope) return;
    if (shuttingDown) {
      done(message.requestId);
      return;
    }

    queued.add(message.requestId);
    serial = serial.then((_) => runCommand(message));
  });
}

void unawaited(Future<void> future) {}