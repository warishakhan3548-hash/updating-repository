package com.aaris.quran.learning

/**
 * Scheduler-neutral policy for rescuing personally weak, scarce vocabulary.
 *
 * This layer never invents Quran token/lexeme identity and never writes Evidence Plane data.
 * Callers may use it only after a trusted semantic unit already exists.
 */
enum class RescueAction {
    NONE,
    WAIT_FOR_SCHEDULER,
    USE_NATURAL_EXPOSURE,
    EXPLICIT_REVIEW,
}

data class RareWordRescueConfig(
    val naturalExposureWindowHours: Double = 24.0,
    val initialReexposureHours: Long = 24,
    val familiarContextReviewCount: Int = 2,
) {
    init {
        require(naturalExposureWindowHours.isFinite() && naturalExposureWindowHours > 0.0) {
            "naturalExposureWindowHours must be finite and > 0"
        }
        require(initialReexposureHours > 0) {
            "initialReexposureHours must be > 0"
        }
        require(familiarContextReviewCount >= 0) {
            "familiarContextReviewCount must be >= 0"
        }
    }
}

data class RescueCandidate(
    val semanticUnitId: String,
    val hasStruggleEvidence: Boolean,
    val schedulerDue: Boolean,
    val forgettingRisk: Double,
    val personalRelevance: Double,
    val hoursUntilNaturalExposure: Double? = null,
) {
    init {
        require(semanticUnitId.isNotBlank()) { "semanticUnitId must not be blank" }
        require(forgettingRisk.isFinite() && forgettingRisk in 0.0..1.0) {
            "forgettingRisk must be in [0, 1]"
        }
        require(personalRelevance.isFinite() && personalRelevance in 0.0..1.0) {
            "personalRelevance must be in [0, 1]"
        }
        require(
            hoursUntilNaturalExposure == null ||
                (hoursUntilNaturalExposure.isFinite() && hoursUntilNaturalExposure >= 0.0),
        ) {
            "hoursUntilNaturalExposure must be null or finite and >= 0"
        }
    }
}

data class RescuePlan(
    val semanticUnitId: String,
    val action: RescueAction,
    val learningNeed: Double,
    val forgettingRisk: Double,
    val exposureScarcity: Double,
    val personalRelevance: Double,
)

/**
 * Policy v1 deliberately consumes a scheduler's due/not-due projection instead of embedding
 * FSRS equations or parameter vectors into permanent product logic.
 */
object RareWordRescuePolicy {
    const val POLICY_VERSION = "rare-word-rescue-v1"
    private const val MILLIS_PER_HOUR = 3_600_000L

    fun plan(
        candidate: RescueCandidate,
        config: RareWordRescueConfig = RareWordRescueConfig(),
    ): RescuePlan {
        val scarcity = exposureScarcity(
            candidate.hoursUntilNaturalExposure,
            config.naturalExposureWindowHours,
        )
        val need = if (candidate.hasStruggleEvidence) {
            candidate.forgettingRisk * scarcity * candidate.personalRelevance
        } else {
            0.0
        }

        val action = when {
            !candidate.hasStruggleEvidence -> RescueAction.NONE
            !candidate.schedulerDue -> RescueAction.WAIT_FOR_SCHEDULER
            candidate.hoursUntilNaturalExposure != null &&
                candidate.hoursUntilNaturalExposure <= config.naturalExposureWindowHours ->
                RescueAction.USE_NATURAL_EXPOSURE
            else -> RescueAction.EXPLICIT_REVIEW
        }

        return RescuePlan(
            semanticUnitId = candidate.semanticUnitId,
            action = action,
            learningNeed = need,
            forgettingRisk = candidate.forgettingRisk,
            exposureScarcity = scarcity,
            personalRelevance = candidate.personalRelevance,
        )
    }

    /**
     * Sorts policy decisions without changing their actions. Rarity/scarcity alone cannot make
     * an item eligible because [plan] hard-gates intervention on observed personal struggle.
     */
    fun rank(
        candidates: Iterable<RescueCandidate>,
        config: RareWordRescueConfig = RareWordRescueConfig(),
    ): List<RescuePlan> =
        candidates
            .map { plan(it, config) }
            .filter { it.action != RescueAction.NONE }
            .sortedWith(
                compareByDescending<RescuePlan> { it.learningNeed }
                    .thenBy { it.semanticUnitId },
            )

    /**
     * A predicted encounter immediately ahead means low scarcity; no known encounter inside
     * the horizon approaches maximum scarcity. This is a transparent product heuristic, not
     * a memory-model claim.
     */
    fun exposureScarcity(
        hoursUntilNaturalExposure: Double?,
        horizonHours: Double = 24.0,
    ): Double {
        require(horizonHours.isFinite() && horizonHours > 0.0) {
            "horizonHours must be finite and > 0"
        }
        if (hoursUntilNaturalExposure == null) return 1.0
        require(hoursUntilNaturalExposure.isFinite() && hoursUntilNaturalExposure >= 0.0) {
            "hoursUntilNaturalExposure must be finite and >= 0"
        }
        return (hoursUntilNaturalExposure / horizonHours).coerceIn(0.0, 1.0)
    }

    /**
     * Default bootstrap target for the first trusted struggle event. The timestamp is merely
     * a policy target; an eventual scheduler adapter remains free to choose the actual review.
     */
    fun initialReexposureAtEpochMillis(
        firstStruggleAtEpochMillis: Long,
        config: RareWordRescueConfig = RareWordRescueConfig(),
    ): Long =
        Math.addExact(
            firstStruggleAtEpochMillis,
            Math.multiplyExact(config.initialReexposureHours, MILLIS_PER_HOUR),
        )
}

enum class ReviewContextSource {
    QURAN,
    HADITH,
}

data class ReviewContextCandidate(
    val contextRef: String,
    val source: ReviewContextSource,
    val isVerified: Boolean,
    val isFamiliar: Boolean,
    val priorUseCount: Int,
    val lastUsedAtEpochMillis: Long? = null,
    val pedagogicalRank: Int = 0,
) {
    init {
        require(contextRef.isNotBlank()) { "contextRef must not be blank" }
        require(priorUseCount >= 0) { "priorUseCount must be >= 0" }
        require(pedagogicalRank >= 0) { "pedagogicalRank must be >= 0" }
    }
}

/**
 * Deterministic context selection: familiar verified Quran first for early learning, then
 * rotate toward least-used/least-recent verified contexts as mastery grows.
 *
 * Hadith contexts are opt-in and remain ineligible until the caller proves that the relevant
 * Hadith record is trusted for this purpose.
 */
object ContextRotationPolicy {
    fun choose(
        candidates: Iterable<ReviewContextCandidate>,
        successfulReviewCount: Int,
        allowHadithContexts: Boolean = false,
        config: RareWordRescueConfig = RareWordRescueConfig(),
    ): ReviewContextCandidate? {
        require(successfulReviewCount >= 0) { "successfulReviewCount must be >= 0" }

        val eligible = candidates.filter {
            it.isVerified &&
                (it.source == ReviewContextSource.QURAN || allowHadithContexts)
        }
        if (eligible.isEmpty()) return null

        val earlyLearning = successfulReviewCount < config.familiarContextReviewCount
        val comparator = if (earlyLearning) {
            compareByDescending<ReviewContextCandidate> { it.isFamiliar }
                .thenBy { it.source != ReviewContextSource.QURAN }
                .thenBy { it.pedagogicalRank }
                .thenBy { it.priorUseCount }
                .thenBy { it.lastUsedAtEpochMillis ?: Long.MIN_VALUE }
                .thenBy { it.contextRef }
        } else {
            compareBy<ReviewContextCandidate> { it.priorUseCount }
                .thenBy { it.lastUsedAtEpochMillis ?: Long.MIN_VALUE }
                .thenBy { it.pedagogicalRank }
                .thenBy { it.source != ReviewContextSource.QURAN }
                .thenBy { it.contextRef }
        }

        return eligible.minWithOrNull(comparator)
    }
}
