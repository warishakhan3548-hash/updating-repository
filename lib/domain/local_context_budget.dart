/// Token counts emitted by the native pre-evaluation budget check, not estimates
/// from character length. This is a recoverable prompt admission failure, not a
/// broken model or failed network connection.
class LocalContextBudgetFailure implements Exception {
  const LocalContextBudgetFailure({
    required this.inputTokens,
    required this.outputTokens,
    required this.contextTokens,
  });
  final int inputTokens, outputTokens, contextTokens;

  static LocalContextBudgetFailure? fromMessage(String message) {
    final match = RegExp(
      r'^(?:Bad state: )?Local prompt needs (\d+) input tokens plus (\d+) reserved output tokens; context is (\d+)\.',
    ).firstMatch(message);
    if (match == null) return null;
    return LocalContextBudgetFailure(
      inputTokens: int.parse(match[1]!),
      outputTokens: int.parse(match[2]!),
      contextTokens: int.parse(match[3]!),
    );
  }

  @override
  String toString() =>
      'Local chat needs $inputTokens input + $outputTokens output tokens in a $contextTokens-token context.';
}
