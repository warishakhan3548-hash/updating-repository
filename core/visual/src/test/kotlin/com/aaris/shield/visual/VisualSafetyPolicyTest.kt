package com.aaris.shield.visual

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class VisualSafetyPolicyTest {
    private val policy = VisualSafetyPolicy()

    @Test
    fun conservativeDefaultThresholdsKeepMiddleBandAmbiguous() {
        assertEquals(VisualSafetyState.SAFE, stateFor(0.19f))
        assertEquals(VisualSafetyState.AMBIGUOUS, stateFor(0.20f))
        assertEquals(VisualSafetyState.AMBIGUOUS, stateFor(0.50f))
        assertEquals(VisualSafetyState.AMBIGUOUS, stateFor(0.80f))
        assertEquals(VisualSafetyState.UNSAFE, stateFor(0.81f))
    }

    @Test
    fun modelFailureNeverBecomesSafe() {
        val result = policy.evaluate(
            modelId = "test",
            outcome = VisualClassifierOutcome.Failure(VisualFailureCode.MODEL_UNAVAILABLE),
        )
        assertEquals(VisualSafetyState.AMBIGUOUS, result.state)
        assertEquals(VisualFailureCode.MODEL_UNAVAILABLE, result.failure)
        assertNull(result.scores)
    }

    private fun stateFor(unsafe: Float): VisualSafetyState = policy.evaluate(
        modelId = "test",
        outcome = VisualClassifierOutcome.Success(
            scores = VisualModelScores(1f - unsafe, unsafe),
            inferenceMillis = 10L,
        ),
    ).state
}
