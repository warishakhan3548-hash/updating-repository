package com.aaris.quran.learning

import kotlin.math.max
import kotlin.math.min

/**
 * Deterministic Learning Plane policy for deciding whether a personally difficult,
 * infrequently re-encountered semantic unit should interrupt reading with an explicit review.
 *
 * This policy deliberately does not:
 * - create semantic identities;
 * - implement FSRS equations;
 * - count passive visibility as recall success;
 * - mutate Evidence Plane content.
 */
enum class RescueAction {
    NOT_ENROLLED,
    HOLD,
    NATURAL_EXPOSURE,
    EXPLICIT_REVIEW,
}

data class RareWordRescueConfig(
    val version: String = "rare-word-rescue-v1",
    val quickPeekEnrollmentThreshold: Int = 2,
)

data class LearningSignals(
    val semanticUnitId: String,
    val isEnrolled: Boolean = false,
    val schedulerReviewDue: Boolean = false,
    val schedulerAllowsNaturalSubstitution: Boolean = false,
    val retrievability: Double? = null,
    val predictedNaturalExposuresSoon: Int = 0,
    val explicitUnknownSinceSuccess: Int = 0,
    val quickMeaningOpensSinceSuccess: Int = 0,
    val reviewAgainSinceSuccess: Int = 0,
    val reviewHardSinceSuccess: Int = 0,
)

data class RescueDecision(
    val semanticUnitId: String,
    val policyVersion: String,
    val action: RescueAction,
    val enrolled: Boolean,
    val forgettingRisk: Double?,
    val exposureScarcity: Double,
    val personalRelevance: Double,
    val priorityScore: Double?,
    val reasonCodes: List<String>,
)

object RareWordRescuePolicy {
    fun decide(
        signals: LearningSignals,
        config: RareWordRescueConfig = RareWordRescueConfig(),
    ): RescueDecision {
        validate(signals, config)

        val currentStruggle =
            signals.explicitUnknownSinceSuccess > 0 ||
                signals.reviewAgainSinceSuccess > 0 ||
                signals.reviewHardSinceSuccess > 0 ||
                signals.quickMeaningOpensSinceSuccess >= config.quickPeekEnrollmentThreshold

        val personalRelevance = when {
            signals.explicitUnknownSinceSuccess > 0 -> 1.0
            signals.reviewAgainSinceSuccess > 0 -> 1.0
            signals.reviewHardSinceSuccess > 0 -> 0.85
            signals.quickMeaningOpensSinceSuccess >= config.quickPeekEnrollmentThreshold -> 0.70
            signals.isEnrolled || signals.schedulerReviewDue -> 0.50
            else -> 0.0
        }

        val enrolled = signals.isEnrolled || currentStruggle || signals.schedulerReviewDue
        val forgettingRisk = signals.retrievability?.let { 1.0 - it }
        val exposureScarcity = 1.0 / (1.0 + signals.predictedNaturalExposuresSoon.toDouble())
        val priorityScore =
            forgettingRisk?.let { risk ->
                clamp01(risk * exposureScarcity * personalRelevance)
            }

        val reasons = linkedSetOf<String>()
        if (currentStruggle) reasons += "current_struggle"
        if (signals.schedulerReviewDue) {
            reasons += "scheduler_review_due"
            reasons += if (signals.schedulerAllowsNaturalSubstitution) {
                "scheduler_allows_natural_substitution"
            } else {
                "scheduler_requires_explicit_review"
            }
        }
        if (signals.retrievability == null) reasons += "retrievability_unknown"
        if (signals.predictedNaturalExposuresSoon > 0) {
            reasons += "natural_exposure_available"
        } else {
            reasons += "exposure_scarce"
        }

        val action = when {
            !enrolled -> {
                reasons += "no_struggle_evidence"
                RescueAction.NOT_ENROLLED
            }

            !currentStruggle && !signals.schedulerReviewDue -> {
                reasons += "no_current_review_need"
                RescueAction.HOLD
            }

            canUseNaturalExposure(signals, currentStruggle) -> {
                reasons += "defer_interruptive_review"
                RescueAction.NATURAL_EXPOSURE
            }

            else -> {
                reasons += "review_not_safely_substitutable"
                RescueAction.EXPLICIT_REVIEW
            }
        }

        return RescueDecision(
            semanticUnitId = signals.semanticUnitId,
            policyVersion = config.version,
            action = action,
            enrolled = enrolled,
            forgettingRisk = forgettingRisk,
            exposureScarcity = exposureScarcity,
            personalRelevance = personalRelevance,
            priorityScore = priorityScore,
            reasonCodes = reasons.toList(),
        )
    }

    private fun canUseNaturalExposure(
        signals: LearningSignals,
        currentStruggle: Boolean,
    ): Boolean {
        if (signals.predictedNaturalExposuresSoon <= 0) return false

        // A due review is scheduler-owned. The learning policy must not invent a universal
        // retrievability floor because desired retention and scheduling policy are adapter
        // concerns. Missing authorization therefore fails closed to explicit review.
        if (signals.schedulerReviewDue) {
            return signals.schedulerAllowsNaturalSubstitution
        }

        // A newly observed struggle that is not yet scheduler-due may use an imminent natural
        // encounter as the next opportunity without fabricating successful recall evidence.
        return currentStruggle
    }

    private fun validate(
        signals: LearningSignals,
        config: RareWordRescueConfig,
    ) {
        require(signals.semanticUnitId.isNotBlank()) {
            "semanticUnitId must be a non-blank app-owned canonical ID"
        }
        require(config.version.isNotBlank()) { "policy version must not be blank" }
        require(config.quickPeekEnrollmentThreshold >= 2) {
            "quickPeekEnrollmentThreshold must be at least 2"
        }

        signals.retrievability?.let {
            require(it in 0.0..1.0) { "retrievability must be within 0..1" }
        }

        val counts = listOf(
            signals.predictedNaturalExposuresSoon,
            signals.explicitUnknownSinceSuccess,
            signals.quickMeaningOpensSinceSuccess,
            signals.reviewAgainSinceSuccess,
            signals.reviewHardSinceSuccess,
        )
        require(counts.all { it >= 0 }) { "learning signal counts must be non-negative" }
    }

    private fun clamp01(value: Double): Double = min(1.0, max(0.0, value))
}
