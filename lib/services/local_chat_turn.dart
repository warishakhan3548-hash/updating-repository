import 'dart:convert';
import 'dart:math';

import '../domain/local_ai_protocol.dart';
import '../domain/local_context_budget.dart';

/// Only standalone social messages use the lightweight, read-only lane. A
/// greeting followed by a medicine, question or command keeps the full contract.
bool isLocalSocialMessage(String instruction) {
  final normalized = instruction
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[.!?।؟]+$'), '')
      .trim();
  return const <String>{
    'hi',
    'hii',
    'hello',
    'hey',
    'hi bhai',
    'hello bhai',
    'good morning',
    'good evening',
    'namaste',
    'how are you',
    'how are you doing',
    'hi how are you',
    'hello how are you',
    'kaise ho',
    'kaise ho bhai',
    'kya haal hai',
    'नमस्ते',
    'नमस्कार',
    'हैलो',
    'हेलो',
    'हाय',
    'हैलो भाई',
    'हेलो भाई',
    'हाय भाई',
    'कैसे हो',
    'कैसे हो भाई',
    'आप कैसे हैं',
    'क्या हाल है',
  }.contains(normalized);
}

String localChatSystemPrompt(
  LocalInventoryContext context,
  String instruction,
) => isLocalSocialMessage(instruction)
    ? "You are Aaris. Answer this greeting or small talk in one short sentence in the user's language. Plain text only. Do not claim inventory work."
    : context.instructions;

/// One bounded read-only chat turn. The native runtime owns the inference lease
/// and clears KV memory for every full prompt; this layer owns which conversation
/// facts are sent back to it. No model/transport restart or inventory write here.
Future<String> runLocalChatTurn({
  required LocalInventoryContext context,
  required String instruction,
  required String conversation,
  required int conversationLimit,
  required int outputTokens,
  required int inventoryRows,
  required Future<String> Function(String payload, int outputTokens) generate,
  required void Function() checkCurrent,
  void Function()? onContextReset,
  void Function()? onStreamReset,
  void Function(int round)? onRound,
}) async {
  final socialOnly = isLocalSocialMessage(instruction);
  // Do not send past inventory instructions/data merely to answer "Hi". This
  // omits history for this one turn; it does not erase the owner's conversation.
  var history = socialOnly ? '' : conversation;
  final results = <Map<String, Object?>>[];
  var generationCount = 0;

  void forgetHistory() {
    if (history.isEmpty) return;
    history = '';
    // Observers cannot abort ownership/cleanup of this admitted local turn.
    try {
      onContextReset?.call();
    } catch (_) {}
  }

  checkCurrent();
  // The character ceiling is a coarse guard only. Never cut a message/UTF-16
  // string halfway and present the fragment as complete conversation history.
  if (history.length > conversationLimit) forgetHistory();

  for (var round = 0; round <= 4; round++) {
    var budget = socialOnly ? min(outputTokens, 96) : outputTokens;
    var adjustedOutput = false;
    var responseRepairUsed = false;
    late Map<String, dynamic> answer;

    while (true) {
      checkCurrent();
      onRound?.call(round);
      final input = socialOnly
          ? instruction.trim()
          : jsonEncode({
              'ownerRequest': instruction,
              'recentConversation': history,
              if (results.isNotEmpty) ...{
                'toolResults': results,
                'remainingReadCalls': 4 - round,
                'next': 'Answer or request one more page. Never invent omitted facts.',
              },
            });
      if (input.length > 15000) {
        if (history.isNotEmpty) {
          forgetHistory();
          continue;
        }
        throw StateError('Tool result too large; ask a narrower question.');
      }
      if (generationCount++ > 0) {
        try {
          onStreamReset?.call();
        } catch (_) {}
      }

      String raw;
      try {
        raw = await generate(input, budget);
        checkCurrent();
      } on LocalContextBudgetFailure catch (error) {
        checkCurrent();
        if (history.isNotEmpty) {
          // Keep this owner request and verified tools intact. All old chat is
          // dropped once; the UI also advances its boundary for future sends.
          forgetHistory();
          continue;
        }
        // Some phones load a smaller context than the advertised model maximum.
        // Use exact native counts to reserve a viable answer, never trim safety
        // instructions, the current question or authoritative tool facts.
        final available = error.contextTokens - error.inputTokens - 32;
        if (!adjustedOutput &&
            available >= min(outputTokens, 256) &&
            available < budget) {
          budget = available;
          adjustedOutput = true;
          continue;
        }
        throw FormatException(
          'This request or its inventory results exceed the loaded ${error.contextTokens}-token local context even in a fresh chat. Ask a shorter/narrower question. The model is still available; no inventory changes were made.',
        );
      }

      // A native generation that reaches Done with no visible assistant bytes is
      // not a valid JSON/chat answer. Tiny quantized models can occasionally emit
      // EOS immediately, especially after Android memory pressure or a cold model
      // reload. Never pass that empty string into jsonDecode(). Retry this exact
      // read-only round once; if old chat exists, drop only that expendable history
      // first so the current owner request and verified inventory facts stay intact.
      if (raw.trim().isEmpty) {
        if (!responseRepairUsed) {
          responseRepairUsed = true;
          if (history.isNotEmpty) forgetHistory();
          continue;
        }
        throw StateError(
          'Local model finished twice without returning an answer. The model is still installed; try the request again or use a different quantization.',
        );
      }

      try {
        answer = localChatObject(raw);
        break;
      } on FormatException {
        // A truncated/invalid structured answer is also safe to regenerate once:
        // this layer is read-only and no inventory mutation has been applied.
        // Do not repair braces or guess JSON fields; let the model regenerate a
        // complete answer under the same authoritative validators.
        if (!responseRepairUsed) {
          responseRepairUsed = true;
          if (history.isNotEmpty) forgetHistory();
          continue;
        }
        throw const FormatException(
          'Local model returned incomplete structured output twice. No inventory changes were made.',
        );
      }
    }

    // A small prompt is never a new authority to read or change inventory. Even
    // an unexpected well-formed model tool/action response is rejected here.
    if (socialOnly &&
        (answer.containsKey('tool') ||
            answer['actions'] is! List ||
            (answer['actions'] as List).isNotEmpty)) {
      throw const FormatException(
        'A greeting cannot read or change stock. No inventory changes were made.',
      );
    }
    if (!answer.containsKey('tool')) return context.finish(answer);
    if (round == 4) {
      throw StateError(
        'Local AI reached the read-tool limit. Ask a narrower question.',
      );
    }
    final facts = context.read(answer, rowLimit: inventoryRows);
    results.add({'call': answer, 'result': facts});
    if (results.length > 2) results.removeAt(0);
  }
  throw StateError('No local answer.');
}
