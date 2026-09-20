package com.aaris.quran.learning

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class RareWordRescuePolicyTest {
    @Test
    fun rarityWithoutPersonalStruggleNeverSchedulesIntervention() {
        val plan = RareWordRescuePolicy.plan(
            RescueCandidate(
                semanticUnitId = "lx:rare",
                hasStruggleEvidence = false,
                schedulerDue = true,
                forgettingRisk = 1.0,
                personalRelevance = 1.0,
                hoursUntilNaturalExposure = null,
            ),
        )

        assertEquals(RescueAction.NONE, plan.action)
        assertEquals(0.0, plan.learningNeed, 0.0)
    }

    @Test
    fun dueWeakItemUsesUpcomingReadingInsteadOfDuplicateFlashcard() {
        val plan = RareWordRescuePolicy.plan(
            RescueCandidate(
                semanticUnitId = "lx:weak",
                hasStruggleEvidence = true,
                schedulerDue = true,
                forgettingRisk = 0.8,
                personalRelevance = 0.9,
                hoursUntilNaturalExposure = 6.0,
            ),
        )

        assertEquals(RescueAction.USE_NATURAL_EXPOSURE, plan.action)
        assertEquals(0.25, plan.exposureScarcity, 1e-9)
        assertEquals(0.18, plan.learningNeed, 1e-9)
    }

    @Test
    fun dueWeakItemUsesExplicitReviewWhenNaturalExposureIsNotSoon() {
        val plan = RareWordRescuePolicy.plan(
            RescueCandidate(
                semanticUnitId = "lx:weak",
                hasStruggleEvidence = true,
                schedulerDue = true,
                forgettingRisk = 0.8,
                personalRelevance = 0.5,
                hoursUntilNaturalExposure = 72.0,
            ),
        )

        assertEquals(RescueAction.EXPLICIT_REVIEW, plan.action)
        assertEquals(1.0, plan.exposureScarcity, 0.0)
        assertEquals(0.4, plan.learningNeed, 1e-9)
    }

    @Test
    fun schedulerStillOwnsDueDecision() {
        val plan = RareWordRescuePolicy.plan(
            RescueCandidate(
                semanticUnitId = "lx:not-due",
                hasStruggleEvidence = true,
                schedulerDue = false,
                forgettingRisk = 0.95,
                personalRelevance = 1.0,
                hoursUntilNaturalExposure = null,
            ),
        )

        assertEquals(RescueAction.WAIT_FOR_SCHEDULER, plan.action)
    }

    @Test
    fun rankUsesNeedFormulaAndStableTieBreak() {
        val ranked = RareWordRescuePolicy.rank(
            listOf(
                RescueCandidate("lx:b", true, true, 0.5, 1.0, null),
                RescueCandidate("lx:a", true, true, 0.5, 1.0, null),
                RescueCandidate("lx:high", true, true, 0.9, 1.0, null),
            ),
        )

        assertEquals(listOf("lx:high", "lx:a", "lx:b"), ranked.map { it.semanticUnitId })
    }

    @Test
    fun exposureScarcityIsBoundedAndTransparent() {
        assertEquals(0.0, RareWordRescuePolicy.exposureScarcity(0.0), 0.0)
        assertEquals(0.5, RareWordRescuePolicy.exposureScarcity(12.0), 1e-9)
        assertEquals(1.0, RareWordRescuePolicy.exposureScarcity(24.0), 0.0)
        assertEquals(1.0, RareWordRescuePolicy.exposureScarcity(240.0), 0.0)
        assertEquals(1.0, RareWordRescuePolicy.exposureScarcity(null), 0.0)
    }

    @Test
    fun firstStruggleDefaultsToTwentyFourHourReexposureTarget() {
        val start = 1_700_000_000_000L
        assertEquals(
            start + 24L * 60L * 60L * 1000L,
            RareWordRescuePolicy.initialReexposureAtEpochMillis(start),
        )
    }

    @Test
    fun earlyContextPrefersFamiliarVerifiedQuran() {
        val chosen = ContextRotationPolicy.choose(
            candidates = listOf(
                ReviewContextCandidate(
                    "qa:002:255",
                    ReviewContextSource.QURAN,
                    isVerified = true,
                    isFamiliar = false,
                    priorUseCount = 0,
                ),
                ReviewContextCandidate(
                    "qa:001:001",
                    ReviewContextSource.QURAN,
                    isVerified = true,
                    isFamiliar = true,
                    priorUseCount = 3,
                ),
            ),
            successfulReviewCount = 0,
        )

        assertEquals("qa:001:001", chosen?.contextRef)
    }

    @Test
    fun laterContextRotatesTowardLeastUsedVerifiedContext() {
        val chosen = ContextRotationPolicy.choose(
            candidates = listOf(
                ReviewContextCandidate(
                    "qa:001:001",
                    ReviewContextSource.QURAN,
                    isVerified = true,
                    isFamiliar = true,
                    priorUseCount = 4,
                    lastUsedAtEpochMillis = 400L,
                ),
                ReviewContextCandidate(
                    "qa:002:255",
                    ReviewContextSource.QURAN,
                    isVerified = true,
                    isFamiliar = false,
                    priorUseCount = 1,
                    lastUsedAtEpochMillis = 200L,
                ),
            ),
            successfulReviewCount = 3,
        )

        assertEquals("qa:002:255", chosen?.contextRef)
    }

    @Test
    fun unverifiedContextsAreNeverSelected() {
        val chosen = ContextRotationPolicy.choose(
            candidates = listOf(
                ReviewContextCandidate(
                    "qa:bad",
                    ReviewContextSource.QURAN,
                    isVerified = false,
                    isFamiliar = true,
                    priorUseCount = 0,
                ),
            ),
            successfulReviewCount = 0,
        )

        assertNull(chosen)
    }

    @Test
    fun hadithContextRequiresExplicitOptInAndVerification() {
        val hadith = ReviewContextCandidate(
            "hr:verified",
            ReviewContextSource.HADITH,
            isVerified = true,
            isFamiliar = false,
            priorUseCount = 0,
        )

        assertNull(
            ContextRotationPolicy.choose(
                candidates = listOf(hadith),
                successfulReviewCount = 4,
                allowHadithContexts = false,
            ),
        )
        assertEquals(
            "hr:verified",
            ContextRotationPolicy.choose(
                candidates = listOf(hadith),
                successfulReviewCount = 4,
                allowHadithContexts = true,
            )?.contextRef,
        )
    }

    @Test
    fun contextSelectionIsDeterministicForEqualCandidates() {
        val chosen = ContextRotationPolicy.choose(
            candidates = listOf(
                ReviewContextCandidate(
                    "qa:002:002",
                    ReviewContextSource.QURAN,
                    true,
                    false,
                    0,
                ),
                ReviewContextCandidate(
                    "qa:001:001",
                    ReviewContextSource.QURAN,
                    true,
                    false,
                    0,
                ),
            ),
            successfulReviewCount = 5,
        )

        assertEquals("qa:001:001", chosen?.contextRef)
        assertTrue(chosen!!.isVerified)
    }
}
