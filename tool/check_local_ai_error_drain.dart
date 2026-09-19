// Controlled engine regression checks; does not load a GGUF or test Android FFI.
import 'dart:async';
import 'dart:io';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import '../lib/services/local_ai_runtime.dart';

class NoisyEngine implements LlamaEngine {
  NoisyEngine({this.failFirstLoad = false, this.cancelGate});
  final bool failFirstLoad;
  final Completer<void>? cancelGate;
  final failed = Completer<void>();
  final contexts = <int>[];
  int actors = 0;

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) {
    final actor = ++actors;
    late StreamController<LlamaResponse> output;
    StreamSubscription<LlamaCommand>? input;
    Timer? noise;
    void fail(String message) {
      output.add(LlamaErrorResponse(message: message));
      if (!failed.isCompleted) failed.complete();
      noise = Timer.periodic(const Duration(milliseconds: 5), (_) {
        output.add(const LlamaTokenResponse(text: 'stale', index: 1));
        output.add(LlamaErrorResponse(message: message));
        output.add(const LlamaStateChangedResponse(state: LlamaState.empty()));
      });
    }

    output = StreamController<LlamaResponse>(
      onListen: () {
        input = commands.listen((command) {
          if (command is LlamaLoadModelCommand) {
            contexts.add(command.contextSize!);
            if (failFirstLoad && actor == 1) {
              fail('Failed to create llama.cpp context');
            } else {
              output.add(
                LlamaStateChangedResponse(
                  state: LlamaState(
                    modelPath: command.modelPath,
                    isModelLoaded: true,
                  ),
                ),
              );
              output.add(const LlamaDoneResponse());
            }
          } else if (command is LlamaGenerateMessagesCommand) {
            if (command.messages.last.content == 'fail') {
              fail('Native decode failed');
            } else {
              output.add(
                const LlamaTokenResponse(text: 'fresh answer', index: 0),
              );
              output.add(const LlamaDoneResponse());
            }
          } else if (command is LlamaDisposeCommand) {
            output.add(const LlamaDoneResponse());
          }
        });
      },
      onCancel: () async {
        noise?.cancel();
        await input?.cancel();
        if (actor == 1 && cancelGate != null) await cancelGate!.future;
      },
    );
    return output.stream;
  }
}

Future<void> main() async {
  var passed = 0;
  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passed++;
  }

  Future<Object?> outcome(Future<Object?> work) =>
      work.then<Object?>((_) => null, onError: (Object error) => error);

  final engine = NoisyEngine();
  final runtime = LocalAiRuntime(
    engine: engine,
    // A generation deadline may expire before a failed command finishes its
    // drain window. It must preserve the native error, not relabel it timeout.
    generationWallClockLimit: const Duration(milliseconds: 25),
    terminalErrorDrainBudget: const Duration(milliseconds: 60),
  );
  await runtime.load('/test/model.gguf');
  final visible = <String>[];
  final failure = await outcome(
    runtime.generate('unchanged prompt', 'fail', onToken: visible.add),
  ).timeout(const Duration(seconds: 2));
  check(
    failure.toString().contains('Native decode failed'),
    'Preserve original native failure',
  );
  check(visible.isEmpty, 'No failed-command trailing tokens reach the user');
  check(
    !runtime.busy && runtime.modelPath == null,
    'Noisy failed actor is retired on time',
  );
  await runtime.load('/test/model.gguf');
  check(
    await runtime.generate('unchanged prompt', 'next') == 'fresh answer',
    'The next request uses a clean actor',
  );
  await runtime.close();

  final loadEngine = NoisyEngine(failFirstLoad: true);
  final loading = LocalAiRuntime(
    engine: loadEngine,
    terminalErrorDrainBudget: const Duration(milliseconds: 60),
  );
  await loading
      .load('/test/model.gguf', contextTokens: 8192)
      .timeout(const Duration(seconds: 2));
  check(
    loadEngine.contexts.join(',') == '8192,6144',
    'Error without Done preserves allocator failure and retries a smaller context',
  );
  check(
    loading.loadedContextTokens == 6144,
    'Adopt the context that actually loaded',
  );
  await loading.close();

  final gate = Completer<void>();
  final queuedEngine = NoisyEngine(cancelGate: gate);
  final queued = LocalAiRuntime(engine: queuedEngine);
  await queued.load('/test/model.gguf');
  final old = outcome(queued.generate('system', 'fail'));
  await queuedEngine.failed.future;
  check(queued.cancelCurrentRequest(), 'Stop owns the running command');
  await old;
  final waiting = outcome(queued.load('/test/next.gguf'));
  check(queued.busy, 'Queued teardown wait reserves the command lease');
  check(queued.cancelCurrentRequest(), 'Stop also owns the queued load');
  gate.complete();
  check(
    (await waiting).toString().contains('cancelled'),
    'Queued cancellation propagates',
  );
  check(
    queuedEngine.actors == 1,
    'A cancelled queued load never starts a new model',
  );
  await queued.load('/test/next.gguf');
  check(queuedEngine.actors == 2, 'A later explicit request can recover');
  await queued.close();
  stdout.writeln('Local AI error/cancellation: $passed passed.');
}
