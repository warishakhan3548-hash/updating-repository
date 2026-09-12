import 'dart:async';
import 'dart:convert';

import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/services/local_ai_runtime.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

class _RunawayProgressEngine implements LlamaEngine {
  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    await for (final command in commands) {
      if (command is LlamaLoadModelCommand) {
        yield LlamaStateChangedResponse(
          state: LlamaState(modelPath: command.modelPath, isModelLoaded: true),
        );
        yield const LlamaDoneResponse();
        continue;
      }

      if (command is LlamaGenerateMessagesCommand) {
        // Keep making healthy-looking progress for much longer than the test
        // wall-clock limit. The progress watchdog must not mask the absolute
        // generation deadline.
        for (var i = 0; i < 200; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
          yield LlamaTokenResponse(text: 'x', index: i);
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
  group('weak local model chat recovery', () {
    test(
      'normalizes one safe reply alias without granting action authority',
      () {
        final context = LocalInventoryContext(
          records: const [],
          sales: const [],
          revision: 9,
          today: DateTime(2026, 9, 11),
        );

        final result = jsonDecode(
          context.finish(localChatObject('{"response":"Hello bhai"}')),
        ) as Map<String, dynamic>;

        expect(result['reply'], 'Hello bhai');
        expect(result['actions'], isEmpty);
        expect(result['baseRevision'], 9);
      },
    );

    test('fills a missing empty actions list for an ordinary reply', () {
      expect(localChatObject('{"reply":"Namaste"}'), <String, dynamic>{
        'reply': 'Namaste',
        'actions': <Object?>[],
      });
    });

    test('never downgrades mutation-shaped drift into a harmless reply', () {
      final context = LocalInventoryContext(
        records: const [],
        sales: const [],
        revision: 1,
        today: DateTime(2026, 9, 11),
      );

      expect(
        () => context.finish(
          localChatObject(
            '{"message":"Done","actions":[{"op":"add","fields":{"name":"X"}}]}',
          ),
        ),
        throwsFormatException,
      );
    });
  });

  test(
    'continuous token progress still hits the absolute generation guard',
    () async {
      final runtime = LocalAiRuntime(
        engine: _RunawayProgressEngine(),
        generationWallClockLimit: const Duration(milliseconds: 45),
      );

      await runtime.load('/test/runaway.gguf', contextTokens: 2048);

      await expectLater(
        runtime.generate('system', 'hello', maxTokens: 512),
        throwsA(isA<TimeoutException>()),
      );
      expect(runtime.busy, isFalse);
      expect(runtime.modelPath, isNull);

      await runtime.close();
    },
  );
}
