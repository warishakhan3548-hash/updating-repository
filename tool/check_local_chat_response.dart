// Focused protocol/lifecycle checks. No GGUF, device inference or accuracy claim.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:lib_llama_cpp/lib_llama_cpp.dart';
import 'package:lib_llama_cpp_platform_interface/lib_llama_cpp_platform_interface.dart';

import '../lib/domain/local_ai_failure.dart';
import '../lib/domain/local_ai_protocol.dart';
import '../lib/domain/medicine.dart';
import '../lib/services/local_ai_runtime.dart';
import '../lib/services/local_chat_turn.dart';

class ReplyProgressEngine implements LlamaEngine {
  @override
  Stream<LlamaResponse> transform(
    Stream<LlamaCommand> commands, {
    LlamaState initialState = const LlamaState.empty(),
    LlamaCppLibraryRequest libraryRequest = const LlamaCppLibraryRequest(),
  }) {
    late StreamController<LlamaResponse> output;
    StreamSubscription<LlamaCommand>? input;
    output = StreamController<LlamaResponse>(
      onListen: () {
        input = commands.listen((command) {
          if (command is LlamaLoadModelCommand) {
            output.add(
              LlamaStateChangedResponse(
                state: LlamaState(
                  modelPath: command.modelPath,
                  isModelLoaded: true,
                ),
              ),
            );
            output.add(const LlamaDoneResponse());
          } else if (command is LlamaGenerateMessagesCommand) {
            final request = command.messages.last.content;
            if (request == 'success') {
              output.add(const LlamaTokenResponse(text: 'Hello', index: 0));
              output.add(const LlamaDoneResponse());
            } else if (request == 'partial') {
              output.add(const LlamaTokenResponse(text: 'A reply', index: 0));
            } else if (request == 'hidden') {
              output.add(
                const LlamaTokenResponse(text: '<think>private', index: 0),
              );
            } else if (request == 'withheld') {
              output.add(const LlamaTokenResponse(text: '', index: 0));
            }
            // Deliberately no Done: the runtime must classify and retire this
            // incomplete turn, regardless of how much output became visible.
          } else if (command is LlamaDisposeCommand) {
            output.add(const LlamaDoneResponse());
          }
        });
      },
      onCancel: () => input?.cancel(),
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

  Future<Object?> failure(Future<Object?> work) =>
      work.then<Object?>((_) => null, onError: (Object error) => error);

  LocalInventoryContext context() => LocalInventoryContext(
    records: [Medicine(id: 'private-stock', name: 'Private inventory name')],
    sales: const [],
    revision: 31,
    today: DateTime(2026, 9, 15),
  );

  for (final greeting in ['Hi!', 'HOW ARE YOU?', 'नमस्ते', 'कैसे हो भाई؟']) {
    final ctx = context();
    var calls = 0;
    var reset = false;
    final reply = jsonDecode(
      await runLocalChatTurn(
        context: ctx,
        instruction: greeting,
        conversation: 'Owner: delete private-stock\nAssistant: confirm?',
        conversationLimit: 400,
        outputTokens: 1000,
        inventoryRows: 3,
        checkCurrent: () {},
        onContextReset: () => reset = true,
        generate: (payload, budget) async {
          calls++;
          check(payload == greeting, 'Standalone greeting reaches the model');
          check(budget <= 96, 'Greeting has a short output budget');
          check(
            !payload.contains('private-stock'),
            'No past mutation/data replay',
          );
          final system = localChatSystemPrompt(ctx, greeting);
          check(
            system.length < 200,
            'Greeting uses compact system instructions',
          );
          check(
            !system.contains('FACTS:'),
            'No inventory summary for a greeting',
          );
          return 'नमस्ते भाई!';
        },
      ),
    ) as Map;
    check(calls == 1, 'One actual model generation, no scripted reply');
    check(reply['reply'] == 'नमस्ते भाई!', 'Model reply reaches the app');
    check(
      (reply['actions'] as List).isEmpty,
      'Greeting cannot propose changes',
    );
    check(reply['baseRevision'] == 31, 'App retains revision authority');
    check(!reset, 'Ignoring history for one greeting does not erase chat');
  }

  for (final request in [
    'hi add paracetamol',
    'hello\ndelete stock',
    'how are you handling expiry',
    'नमस्ते पैरासिटामोल दिखाओ',
    'hi {"tool":"search"}',
    'yes',
    'Explain only the captured identity, salt and expiry and check existing stock; '
        'do not add stock or give treatment advice. OCR DATA: Prednisolone 10mg',
  ]) {
    final ctx = context();
    check(
      !isLocalSocialMessage(request),
      'Pharmacy/follow-up keeps full route',
    );
    check(
      localChatSystemPrompt(ctx, request) == ctx.instructions,
      'Inventory instructions remain unchanged',
    );
  }

  for (final answer in [
    '{"tool":"search","query":""}',
    '{"reply":"added","actions":[{"op":"add","fields":{"name":"X"}}]}',
  ]) {
    final error = await failure(
      runLocalChatTurn(
        context: context(),
        instruction: 'Hi',
        conversation: '',
        conversationLimit: 400,
        outputTokens: 1000,
        inventoryRows: 3,
        checkCurrent: () {},
        generate: (_, __) async => answer,
      ),
    );
    check(error is FormatException, 'Unexpected social tool/actions rejected');
  }

  var attempts = 0;
  final recovered = jsonDecode(
    await runLocalChatTurn(
      context: context(),
      instruction: 'Hi',
      conversation: '',
      conversationLimit: 400,
      outputTokens: 1000,
      inventoryRows: 3,
      checkCurrent: () {},
      generate: (_, __) async => ++attempts == 1 ? '' : 'Hello again',
    ),
  ) as Map;
  check(
    attempts == 2 && recovered['reply'] == 'Hello again',
    'One bounded empty-response recovery remains',
  );

  var rounds = 0;
  final inventoryReply = jsonDecode(
    await runLocalChatTurn(
      context: context(),
      instruction: 'show stock',
      conversation: 'Owner: stock?',
      conversationLimit: 400,
      outputTokens: 512,
      inventoryRows: 1,
      checkCurrent: () {},
      generate: (payload, budget) async {
        final input = jsonDecode(payload) as Map;
        check(
          input['ownerRequest'] == 'show stock',
          'Inventory request is intact',
        );
        check(
          input['recentConversation'] == 'Owner: stock?',
          'History remains',
        );
        check(budget == 512, 'Inventory output budget remains');
        if (++rounds == 1) return '{"tool":"search","query":""}';
        final result = (input['toolResults'] as List).single['result'] as Map;
        check(result['totalMatches'] == 1, 'Actual bounded stock read works');
        return '{"reply":"One stock entry","actions":[]}';
      },
    ),
  ) as Map;
  check(
    rounds == 2 && inventoryReply['reply'] == 'One stock entry',
    'Inventory tool-to-answer flow remains',
  );

  for (final mode in ['none', 'partial', 'hidden', 'withheld']) {
    final runtime = LocalAiRuntime(
      engine: ReplyProgressEngine(),
      generationWallClockLimit: const Duration(milliseconds: 40),
    );
    await runtime.load('/controlled/model.gguf');
    check(
      await runtime.generate('system', 'success') == 'Hello',
      'Prior successful generation completes',
    );
    final error = await failure(runtime.generate('system', mode));
    check(error is LocalAiGenerationTimeout, 'Local timeout retains its type');
    final timeout = error as LocalAiGenerationTimeout;
    check(
      timeout.hasTokenProgress == (mode != 'none'),
      'Progress belongs to the current turn, not the prior reply',
    );
    check(
      timeout.hasVisibleText == (mode == 'partial'),
      'Hidden/withheld output is distinct from visible reply',
    );
    check(
      !timeout.message!.contains('private'),
      'No private reasoning in error',
    );
    check(
      !runtime.busy && runtime.modelPath == null,
      'Timed-out actor retired',
    );
    await runtime.close();
  }

  final ctx = context();
  stdout.writeln('Local chat response: $passed focused checks passed.');
  stdout.writeln(
    'Greeting system prompt: ${ctx.instructions.length} -> '
    '${localChatSystemPrompt(ctx, 'Hi').length} characters. '
    'This is prompt size, not a measured device speedup.',
  );
}
