import 'dart:convert';

import 'package:aaris_pharmacy/domain/local_ai_protocol.dart';
import 'package:aaris_pharmacy/services/local_ai_runtime.dart';
import 'package:aaris_pharmacy/services/local_chat_turn.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

class _BudgetEngine implements LlamaEngine {
  int loads = 0, generations = 0;

  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) async* {
    await for (final command in commands) {
      if (command is LlamaLoadModelCommand) {
        loads++;
        yield LlamaStateChangedResponse(
          state: LlamaState(modelPath: command.modelPath, isModelLoaded: true),
        );
        yield const LlamaDoneResponse();
      } else if (command is LlamaGenerateMessagesCommand) {
        generations++;
        if (generations % 4 == 0) {
          yield const LlamaErrorResponse(
            message: 'Bad state: Local prompt needs 1800 input tokens plus 1000 reserved output tokens; context is 2048. Use a shorter request.',
          );
        } else {
          yield const LlamaTokenResponse(
            text: '{"reply":"Hello","actions":[]}',
            index: 0,
          );
        }
        yield const LlamaDoneResponse();
      } else if (command is LlamaDisposeCommand) {
        yield const LlamaStateChangedResponse(state: LlamaState.empty());
        yield const LlamaDoneResponse();
        return;
      }
    }
  }
}

void main() {
  test('local chat carries the minimal-add owner override into the model turn', () async {
    final context = LocalInventoryContext(
      records: const [],
      sales: const [],
      revision: 5,
      today: DateTime.utc(2026, 9, 20),
    );
    String? captured;
    final result = await runLocalChatTurn(
      context: context,
      instruction: 'Mujhe kuch nahi pata, bas add kar do',
      conversation:
          'Owner: Cefixime 200mg add kar do\n'
          'Assistant: Quantity aur form bata do.',
      conversationLimit: 2000,
      outputTokens: 256,
      inventoryRows: 2,
      checkCurrent: () {},
      generate: (payload, budget) async {
        captured = payload;
        return '{"reply":"Prepared","actions":[{"op":"add","fields":{"name":"Cefixime","strength":"200mg"}}]}';
      },
    );

    final modelInput = jsonDecode(captured!) as Map<String, dynamic>;
    expect(modelInput['aarisTurnPolicy'], contains('Do not ask again for optional fields'));
    expect(modelInput['aarisTurnPolicy'], contains('Omitted quantity means unknown'));
    final envelope = jsonDecode(result) as Map<String, dynamic>;
    final action = (envelope['actions'] as List).single as Map<String, dynamic>;
    final fields = action['fields'] as Map<String, dynamic>;
    expect(fields['name'], 'Cefixime');
    expect(fields['strength'], '200mg');
    expect(fields.containsKey('quantity'), isFalse);
  });

  test('eight sequential chats recover native context admission without unloading a healthy model', () async {
    final engine = _BudgetEngine();
    final runtime = LocalAiRuntime(engine: engine);
    var resets = 0;
    try {
      await runtime.load('/test/gemma.gguf', contextTokens: 2048);
      for (var turn = 0; turn < 8; turn++) {
        final context = LocalInventoryContext(
          records: const [],
          sales: const [],
          revision: 7,
          today: DateTime.utc(2026, 9, 12),
        );
        final answer = await runLocalChatTurn(
          context: context,
          instruction: 'Hello $turn',
          conversation: 'Owner: earlier chat',
          conversationLimit: 2000,
          outputTokens: 1000,
          inventoryRows: 2,
          checkCurrent: () {},
          onContextReset: () => resets++,
          generate: (payload, budget) => runtime.generate(
            context.instructions,
            payload,
            maxTokens: budget,
          ),
        );
        expect(answer, contains('Hello'));
        expect(runtime.busy, isFalse);
        expect(runtime.modelPath, '/test/gemma.gguf');
      }
      expect(resets, 2);
      expect(engine.loads, 1);
      expect(engine.generations, 10);
    } finally {
      await runtime.close();
    }
  });
}
