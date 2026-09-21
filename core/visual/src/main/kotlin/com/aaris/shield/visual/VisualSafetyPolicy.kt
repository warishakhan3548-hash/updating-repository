package com.aaris.shield.visual

class VisualSafetyPolicy(
    val thresholds: VisualSafetyThresholds = VisualSafetyThresholds(),
) {
    fun evaluate(modelId: String, outcome: VisualClassifierOutcome): VisualSafetyResult = when (outcome) {
        is VisualClassifierOutcome.Failure -> VisualSafetyResult(
            state = VisualSafetyState.AMBIGUOUS,
            modelId = modelId,
            scores = null,
            inferenceMillis = null,
            failure = outcome.code,
        )

        is VisualClassifierOutcome.Success -> {
            val unsafe = outcome.scores.unsafeProbability
            val state = when {
                unsafe < thresholds.safeBelow -> VisualSafetyState.SAFE
                unsafe > thresholds.unsafeAbove -> VisualSafetyState.UNSAFE
                else -> VisualSafetyState.AMBIGUOUS
            }
            VisualSafetyResult(
                state = state,
                modelId = modelId,
                scores = outcome.scores,
                inferenceMillis = outcome.inferenceMillis,
                failure = null,
            )
        }
    }
}
