package com.aaris.quran.learning

/**
 * Deterministic selection of a review context for an already-trusted semantic unit.
 *
 * The caller owns occurrence discovery and verification. This policy only chooses among
 * candidates whose semantic-unit/context binding has already been verified.
 */
enum class ReviewContextSource {
    QURAN,
    HADITH,
}

data class ReviewContextRotationConfig(
    val version: String = "context-rotation-v1",
    val familiarPhaseSuccessfulReviews: Int = 2,
) {
    init {
        require(version.isNotBlank()) { "policy version must not be blank" }
        require(familiarPhaseSuccessfulReviews >= 0) {
            "familiarPhaseSuccessfulReviews must be >= 0"
        }
    }
}

data class ReviewContextCandidate(
    val semanticUnitId: String,
    val contextRef: String,
    val source: ReviewContextSource,
    val verifiedBinding: Boolean,
    val familiar: Boolean,
    val priorReviewUses: Int,
    val lastUsedAtEpochMillis: Long? = null,
    val pedagogicalRank: Int = 0,
) {
    init {
        require(semanticUnitId.isNotBlank()) { "semanticUnitId must not be blank" }
        require(contextRef.isNotBlank()) { "contextRef must not be blank" }
        require(priorReviewUses >= 0) { "priorReviewUses must be >= 0" }
        require(pedagogicalRank >= 0) { "pedagogicalRank must be >= 0" }
    }
}

data class ReviewContextSelection(
    val semanticUnitId: String,
    val policyVersion: String,
    val context: ReviewContextCandidate,
    val reasonCodes: List<String>,
)

/**
 * Early learning stays with familiar verified Quran context when available. After the
 * configurable familiar phase, selection rotates toward least-used/least-recent verified
 * contexts instead of repeatedly training against one sentence.
 *
 * Hadith contexts are excluded by default and require explicit opt-in by a caller that has
 * already established a trusted Hadith record and semantic binding.
 */
object ReviewContextRotationPolicy {
    fun choose(
        semanticUnitId: String,
        candidates: Iterable<ReviewContextCandidate>,
        successfulReviewCount: Int,
        allowHadithContexts: Boolean = false,
        config: ReviewContextRotationConfig = ReviewContextRotationConfig(),
    ): ReviewContextSelection? {
        require(semanticUnitId.isNotBlank()) { "semanticUnitId must not be blank" }
        require(successfulReviewCount >= 0) { "successfulReviewCount must be >= 0" }

        val eligible = candidates.filter {
            it.semanticUnitId == semanticUnitId &&
                it.verifiedBinding &&
                (it.source == ReviewContextSource.QURAN || allowHadithContexts)
        }
        if (eligible.isEmpty()) return null

        val early = successfulReviewCount < config.familiarPhaseSuccessfulReviews
        val chosen = if (early) {
            eligible.minWithOrNull(
                compareBy<ReviewContextCandidate> { if (it.familiar) 0 else 1 }
                    .thenBy { if (it.source == ReviewContextSource.QURAN) 0 else 1 }
                    .thenBy { it.pedagogicalRank }
                    .thenBy { it.priorReviewUses }
                    .thenBy { it.lastUsedAtEpochMillis ?: Long.MIN_VALUE }
                    .thenBy { it.contextRef },
            )
        } else {
            eligible.minWithOrNull(
                compareBy<ReviewContextCandidate> { it.priorReviewUses }
                    .thenBy { it.lastUsedAtEpochMillis ?: Long.MIN_VALUE }
                    .thenBy { it.pedagogicalRank }
                    .thenBy { if (it.source == ReviewContextSource.QURAN) 0 else 1 }
                    .thenBy { it.contextRef },
            )
        } ?: return null

        val reasons = buildList {
            add(if (early) "familiar_phase" else "variation_phase")
            if (chosen.familiar) add("familiar_context")
            if (!early) add("least_used_then_oldest")
            add(
                if (chosen.source == ReviewContextSource.QURAN) {
                    "quran_context"
                } else {
                    "verified_hadith_context"
                },
            )
        }

        return ReviewContextSelection(
            semanticUnitId = semanticUnitId,
            policyVersion = config.version,
            context = chosen,
            reasonCodes = reasons,
        )
    }
}
