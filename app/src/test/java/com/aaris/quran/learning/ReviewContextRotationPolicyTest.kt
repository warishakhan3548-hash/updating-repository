package com.aaris.quran.learning

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ReviewContextRotationPolicyTest {
    @Test
    fun rejectsUnverifiedOrWrongSemanticBindings() {
        val chosen = ReviewContextRotationPolicy.choose(
            semanticUnitId = "lx:target",
            candidates = listOf(
                candidate(
                    semanticUnitId = "lx:target",
                    contextRef = "qa:001:001",
                    verified = false,
                    familiar = true,
                ),
                candidate(
                    semanticUnitId = "lx:other",
                    contextRef = "qa:002:255",
                    verified = true,
                    familiar = true,
                ),
            ),
            successfulReviewCount = 0,
        )

        assertNull(chosen)
    }

    @Test
    fun earlyLearningPrefersFamiliarVerifiedQuranContext() {
        val chosen = ReviewContextRotationPolicy.choose(
            semanticUnitId = "lx:target",
            candidates = listOf(
                candidate(
                    contextRef = "qa:002:255",
                    verified = true,
                    familiar = false,
                    uses = 0,
                ),
                candidate(
                    contextRef = "qa:001:001",
                    verified = true,
                    familiar = true,
                    uses = 4,
                ),
            ),
            successfulReviewCount = 0,
        )

        assertEquals("qa:001:001", chosen?.context?.contextRef)
        assertTrue("familiar_phase" in chosen!!.reasonCodes)
    }

    @Test
    fun variationPhaseRotatesTowardLeastUsedContext() {
        val chosen = ReviewContextRotationPolicy.choose(
            semanticUnitId = "lx:target",
            candidates = listOf(
                candidate(
                    contextRef = "qa:001:001",
                    verified = true,
                    familiar = true,
                    uses = 5,
                    lastUsed = 500L,
                ),
                candidate(
                    contextRef = "qa:002:255",
                    verified = true,
                    familiar = false,
                    uses = 1,
                    lastUsed = 400L,
                ),
            ),
            successfulReviewCount = 3,
        )

        assertEquals("qa:002:255", chosen?.context?.contextRef)
        assertTrue("variation_phase" in chosen!!.reasonCodes)
    }

    @Test
    fun equalUseRotatesTowardLeastRecentContext() {
        val chosen = ReviewContextRotationPolicy.choose(
            semanticUnitId = "lx:target",
            candidates = listOf(
                candidate(
                    contextRef = "qa:010:001",
                    verified = true,
                    familiar = false,
                    uses = 2,
                    lastUsed = 900L,
                ),
                candidate(
                    contextRef = "qa:020:001",
                    verified = true,
                    familiar = false,
                    uses = 2,
                    lastUsed = 100L,
                ),
            ),
            successfulReviewCount = 4,
        )

        assertEquals("qa:020:001", chosen?.context?.contextRef)
    }

    @Test
    fun hadithContextRequiresExplicitOptIn() {
        val hadith = candidate(
            contextRef = "hr:verified",
            verified = true,
            familiar = false,
            uses = 0,
            source = ReviewContextSource.HADITH,
        )

        assertNull(
            ReviewContextRotationPolicy.choose(
                semanticUnitId = "lx:target",
                candidates = listOf(hadith),
                successfulReviewCount = 5,
                allowHadithContexts = false,
            ),
        )
        assertEquals(
            "hr:verified",
            ReviewContextRotationPolicy.choose(
                semanticUnitId = "lx:target",
                candidates = listOf(hadith),
                successfulReviewCount = 5,
                allowHadithContexts = true,
            )?.context?.contextRef,
        )
    }

    @Test
    fun deterministicTieBreakUsesStableContextReference() {
        val chosen = ReviewContextRotationPolicy.choose(
            semanticUnitId = "lx:target",
            candidates = listOf(
                candidate("qa:002:002", true, false, 0),
                candidate("qa:001:001", true, false, 0),
            ),
            successfulReviewCount = 5,
        )

        assertEquals("qa:001:001", chosen?.context?.contextRef)
    }

    private fun candidate(
        contextRef: String,
        verified: Boolean,
        familiar: Boolean,
        uses: Int = 0,
        lastUsed: Long? = null,
        semanticUnitId: String = "lx:target",
        source: ReviewContextSource = ReviewContextSource.QURAN,
    ) = ReviewContextCandidate(
        semanticUnitId = semanticUnitId,
        contextRef = contextRef,
        source = source,
        verifiedBinding = verified,
        familiar = familiar,
        priorReviewUses = uses,
        lastUsedAtEpochMillis = lastUsed,
    )
}
