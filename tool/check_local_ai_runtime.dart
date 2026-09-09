import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import '../lib/services/local_ai_runtime.dart';
import '../third_party/lib_llama_cpp/lib/src/token_text_decoder.dart';

// Exercises real app lifecycle against a controlled command stream. Does not
// claim model accuracy, Android linkage or physical-device inference testing.
class ControlledEngine implements LlamaEngine {
  final loadState = Completer<void>(), releaseLoad = Completer<void>();
  final errorState = Completer<void>(), releaseError = Completer<void>();
  int disposals = 0, contextTokens = 0;

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    await for (final command in commands) {
      if (command is LlamaLoadModelCommand) {
        contextTokens = command.contextSize ?? 0;
        yield LlamaStateChangedResponse(
          state: LlamaState(modelPath: command.modelPath, isModelLoaded: true),
        );
        loadState.complete();
        await releaseLoad.future;
      } else if (command is LlamaGenerateMessagesCommand) {
        final request = command.messages.last.content;
        if (request == 'fail') {
          yield const LlamaErrorResponse(message: 'Expected test failure');
          errorState.complete();
          await releaseError.future;
        } else {
          yield LlamaTokenResponse(
            text: request == 'oversized' ? 'x' * 33000 : '{"reply":"$request"}',
            index: 0,
          );
        }
      } else if (command is LlamaDisposeCommand) {
        disposals++;
        yield const LlamaStateChangedResponse(state: LlamaState.empty());
        yield const LlamaDoneResponse();
        return;
      }
      yield const LlamaDoneResponse();
    }
  }
}

class MissingNativePlatform extends LibLlamaCppPlatform {
  @override
  Future<LlamaCppLibraryDescriptor> resolveLibrary({
    LlamaCppLibraryRequest request = const LlamaCppLibraryRequest(),
  }) async => const LlamaCppLibraryDescriptor(
    resolution: LlamaCppLibraryResolution.lookupName,
    lookupName: 'aaris_intentionally_missing_test_library.so',
    capabilities: {LlamaCppLibraryCapability.cpu},
  );
}

Future<void> main() async {
  var passed = 0;
  void check(bool value, String message) {
    if (!value) throw StateError(message);
    passed++;
  }

  Future<Object?> failure(Future<String> work) =>
      work.then<Object?>((_) => null, onError: (Object error) => error);
  final engine = ControlledEngine();
  final runtime = LocalAiRuntime(engine: engine);
  var loaded = false;
  final loading = runtime.load('/test/fake.gguf').then((_) => loaded = true);
  await engine.loadState.future;
  await Future<void>.delayed(Duration.zero);
  check(
    !loaded && runtime.busy,
    'State event must not complete a command before Done',
  );
  var rejected = false;
  try {
    runtime.generate('system', 'too early');
  } on StateError {
    rejected = true;
  }
  check(rejected, 'Never overlap model commands');
  engine.releaseLoad.complete();
  await loading;
  check(
    loaded && !runtime.busy && runtime.modelPath == '/test/fake.gguf',
    'Load completion',
  );
  check(
    await runtime.generate('system', 'first') == '{"reply":"first"}',
    'Generation completion',
  );
  final failed = failure(runtime.generate('system', 'fail'));
  await engine.errorState.future;
  await Future<void>.delayed(Duration.zero);
  check(runtime.busy, 'Error response retains command lease until Done');
  engine.releaseError.complete();
  check(
    await failed is StateError && !runtime.busy,
    'Failure drains and propagates',
  );
  check(
    await runtime.generate('system', 'second') == '{"reply":"second"}',
    'Prior error/completion cannot contaminate next reply',
  );
  check(
    await failure(runtime.generate('system', 'oversized')) is StateError,
    'Oversized output rejected, never silently truncated',
  );
  check(
    await runtime.generate('system', 'third') == '{"reply":"third"}',
    'Output buffer resets between requests',
  );
  check(engine.contextTokens == 4096, 'Phone default context is bounded');
  final close1 = runtime.close(), close2 = runtime.close();
  check(identical(close1, close2), 'Concurrent close calls share one disposal');
  await close1;
  check(
    engine.disposals == 1 && runtime.modelPath == null,
    'Idempotent graceful disposal',
  );

  // Run the actual patched worker without loading native code. Its startup
  // errors must still finish each dispatch, rather than hang the consumer.
  final events = await LibLlamaCpp(platform: MissingNativePlatform())
      .transform(
        Stream.fromIterable(const <LlamaCommand>[
          LlamaLoadModelCommand(modelPath: '/nonexistent.gguf'),
          LlamaGenerateMessagesCommand(
            messages: [LlamaMessage(role: 'user', content: 'test')],
            maxTokens: 5,
          ),
          LlamaDisposeCommand(),
        ]),
      )
      .toList()
      .timeout(const Duration(seconds: 10));
  check(
    events.whereType<LlamaDoneResponse>().length == 3,
    'One completion per real worker command, including failures',
  );
  check(
    events.whereType<LlamaErrorResponse>().length == 2,
    'Real worker reports both failed commands',
  );
  await LocalAiRuntime(
    engine: ControlledEngine(),
  ).close().timeout(const Duration(seconds: 1));
  check(true, 'Closing unused runtime does not wait for an absent listener');
  const multilingual = 'नमस्ते بھائی · 0.5 mg · ₹500 · 🧪';
  final encoded = utf8.encode(multilingual);
  for (var split = 1; split <= 5; split++) {
    final decoder = TokenTextDecoder(), output = StringBuffer();
    for (var offset = 0; offset < encoded.length; offset += split) {
      output.write(
        decoder.add(
          encoded.sublist(offset, (offset + split).clamp(0, encoded.length)),
        ),
      );
    }
    output.write(decoder.finish());
    check(
      output.toString() == multilingual,
      'UTF-8 preserves characters across $split-byte token pieces',
    );
  }
  var invalidRejected = false;
  try {
    TokenTextDecoder()
      ..add([0xe0])
      ..finish();
  } on FormatException {
    invalidRejected = true;
  }
  check(
    invalidRejected,
    'Incomplete UTF-8 is not replaced with corrupted medicine text',
  );
  final drainingEngine = ControlledEngine();
  final draining = LocalAiRuntime(engine: drainingEngine);
  final drainLoad = draining.load('/test/draining.gguf', contextTokens: 2048);
  await drainingEngine.loadState.future;
  drainingEngine.releaseLoad.complete();
  await drainLoad;
  final drainingError = failure(draining.generate('system', 'fail'));
  await drainingEngine.errorState.future;
  final closing = draining.close();
  var refused = false;
  try {
    draining.generate('system', 'late request');
  } on StateError {
    refused = true;
  }
  check(
    refused && drainingEngine.disposals == 0,
    'Shutdown rejects new work while the previous command drains',
  );
  drainingEngine.releaseError.complete();
  await drainingError;
  await closing;
  check(
    drainingEngine.disposals == 1 && drainingEngine.contextTokens == 2048,
    'Selected context forwarded; exactly one disposal after drain',
  );
  stdout.writeln(
    'Local AI runtime lifecycle: $passed passed (no model/device execution).',
  );
}
