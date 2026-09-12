import 'dart:convert';
import 'dart:math';

import '../domain/local_ai_protocol.dart';
import '../domain/local_context_budget.dart';

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
  var history = conversation;
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
    var budget = outputTokens;
    var adjustedOutput = false;
    String raw;
    while (true) {
      checkCurrent();
      onRound?.call(round);
      final input = jsonEncode({
        'ownerRequest': instruction,
        'recentConversation': history,
        if (results.isNotEmpty) ...{
          'toolResults': results,
          'remainingReadCalls': 4 - round,
          'next':
              'Answer or request one more page. Never invent omitted facts.',
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
      try {
        raw = await generate(input, budget);
        checkCurrent();
        break;
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
    }
    final answer = localChatObject(raw);
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
