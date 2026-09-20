package com.aaris.quran.learning

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class RareWordRescuePolicyTest {
    @Test
    fun singleQuickMeaningOpenDoesNotEnroll() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:1",
                quickMeaningOpensSinceSuccess = 1,
            ),
        )

        assertEquals(RescueAction.NOT_ENROLLED, decision.action)
        assertFalse(decision.enrolled)
        assertEquals(0.0, decision.personalRelevance, 0.0)
        assertNull(decision.priorityScore)
        assertTrue("no_struggle_evidence" in decision.reasonCodes)
    }

    @Test
    fun repeatedQuickMeaningOpensWithoutNaturalExposureUseExplicitReview() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:2",
                quickMeaningOpensSinceSuccess = 2,
            ),
        )

        assertEquals(RescueAction.EXPLICIT_REVIEW, decision.action)
        assertTrue(decision.enrolled)
        assertEquals(0.70, decision.personalRelevance, 0.0)
        assertTrue("exposure_scarce" in decision.reasonCodes)
    }

    @Test
    fun firstExplicitUnknownCanWaitForImminentNaturalExposureWhenNoSchedulerReviewIsDue() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:3",
                explicitUnknownSinceSuccess = 1,
                predictedNaturalExposuresSoon = 1,
            ),
        )

        assertEquals(RescueAction.NATURAL_EXPOSURE, decision.action)
        assertTrue(decision.enrolled)
        assertNull(decision.forgettingRisk)
        assertNull(decision.priorityScore)
        assertTrue("defer_interruptive_review" in decision.reasonCodes)
    }

    @Test
    fun schedulerDueWithoutDeferralAuthorizationFailsClosedToExplicitReview() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:4",
                schedulerReviewDue = true,
                predictedNaturalExposuresSoon = 1,
            ),
        )

        assertEquals(RescueAction.EXPLICIT_REVIEW, decision.action)
        assertTrue("review_not_safely_substitutable" in decision.reasonCodes)
    }

    @Test
    fun schedulerAuthorizedDueReviewCanUseNaturalExposure() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:5",
                isEnrolled = true,
                schedulerReviewDue = true,
                schedulerAllowsNaturalSubstitution = true,
                retrievability = 0.75,
                predictedNaturalExposuresSoon = 2,
            ),
        )

        assertEquals(RescueAction.NATURAL_EXPOSURE, decision.action)
        assertEquals(0.25, decision.forgettingRisk!!, 1e-9)
        assertEquals(1.0 / 3.0, decision.exposureScarcity, 1e-9)
        assertEquals(0.50, decision.personalRelevance, 0.0)
        assertEquals(1.0 / 24.0, decision.priorityScore!!, 1e-9)
    }

    @Test
    fun schedulerDenialOverridesHighOptionalRetrievabilityProjection() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:6",
                isEnrolled = true,
                schedulerReviewDue = true,
                schedulerAllowsNaturalSubstitution = false,
                retrievability = 0.99,
                predictedNaturalExposuresSoon = 3,
            ),
        )

        assertEquals(RescueAction.EXPLICIT_REVIEW, decision.action)
        assertTrue("natural_exposure_available" in decision.reasonCodes)
        assertTrue("scheduler_requires_explicit_review" in decision.reasonCodes)
        assertTrue("review_not_safely_substitutable" in decision.reasonCodes)
    }

    @Test
    fun schedulerAuthorizationDoesNotRequireRetrievabilityToBeExposed() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:6b",
                isEnrolled = true,
                schedulerReviewDue = true,
                schedulerAllowsNaturalSubstitution = true,
                retrievability = null,
                predictedNaturalExposuresSoon = 1,
            ),
        )

        assertEquals(RescueAction.NATURAL_EXPOSURE, decision.action)
        assertNull(decision.forgettingRisk)
        assertTrue("scheduler_allows_natural_substitution" in decision.reasonCodes)
    }

    @Test
    fun enrolledUnitNotDueAndNotCurrentlyStrugglingHolds() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:7",
                isEnrolled = true,
                retrievability = 0.90,
                predictedNaturalExposuresSoon = 1,
            ),
        )

        assertEquals(RescueAction.HOLD, decision.action)
        assertTrue(decision.enrolled)
        assertTrue("no_current_review_need" in decision.reasonCodes)
    }

    @Test
    fun priorityScoreCombinesRiskScarcityAndPersonalRelevanceOnlyWhenRiskIsKnown() {
        val decision = RareWordRescuePolicy.decide(
            LearningSignals(
                semanticUnitId = "lx:test:8",
                isEnrolled = true,
                schedulerReviewDue = true,
                retrievability = 0.20,
                predictedNaturalExposuresSoon = 0,
                explicitUnknownSinceSuccess = 1,
            ),
        )

        assertEquals(0.80, decision.forgettingRisk!!, 1e-9)
        assertEquals(1.0, decision.exposureScarcity, 0.0)
        assertEquals(1.0, decision.personalRelevance, 0.0)
        assertEquals(0.80, decision.priorityScore!!, 1e-9)
    }

    @Test
    fun invalidInputsFailBeforeDecision() {
        assertIllegalArgument {
            RareWordRescuePolicy.decide(LearningSignals(semanticUnitId = " "))
        }
        assertIllegalArgument {
            RareWordRescuePolicy.decide(
                LearningSignals(semanticUnitId = "lx:test", retrievability = 1.01),
            )
        }
        assertIllegalArgument {
            RareWordRescuePolicy.decide(
                LearningSignals(
                    semanticUnitId = "lx:test",
                    predictedNaturalExposuresSoon = -1,
                ),
            )
        }
        assertIllegalArgument {
            RareWordRescuePolicy.decide(
                LearningSignals(semanticUnitId = "lx:test"),
                RareWordRescueConfig(quickPeekEnrollmentThreshold = 1),
            )
        }
    }

    private fun assertIllegalArgument(block: () -> Unit) {
        try {
            block()
            fail("expected IllegalArgumentException")
        } catch (_: IllegalArgumentException) {
            // expected
        }
    }
}
