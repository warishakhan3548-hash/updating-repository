/// Check the actual tokenized prompt plus reserved output before evaluation.
/// Character counts cannot bound Hindi, JSON or an unknown model's tokenizer.
void validateContextBudget({
  required int promptTokens,
  required int contextTokens,
  int? outputTokens,
}) {
  if (promptTokens <= 0 ||
      contextTokens <= 0 ||
      promptTokens >= contextTokens ||
      (outputTokens != null &&
          (outputTokens <= 0 || outputTokens > contextTokens - promptTokens))) {
    throw StateError(
      'Local prompt needs $promptTokens input tokens plus '
      '${outputTokens ?? 0} reserved output tokens; context is $contextTokens. '
      'Use a shorter request or a smaller evidence group. No partial answer accepted.',
    );
  }
}
