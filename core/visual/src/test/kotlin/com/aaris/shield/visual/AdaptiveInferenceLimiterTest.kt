package com.aaris.shield.visual

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveInferenceLimiterTest {
    @Test
    fun slowsAdmissionWhenMeasuredInferenceIsExpensive() {
        val limiter = AdaptiveInferenceLimiter(
            minimumIntervalMillis = 80L,
            maximumIntervalMillis = 1_000L,
            latencyHeadroom = 2.0,
            smoothing = 1.0,
        )
        assertTrue(limiter.tryAcquire(0L))
        limiter.recordInference(300L)
        assertEquals(600L, limiter.currentIntervalMillis())
        assertFalse(limiter.tryAcquire(500_000_000L))
        assertTrue(limiter.tryAcquire(600_000_000L))
    }

    @Test
    fun adaptiveIntervalIsBounded() {
        val limiter = AdaptiveInferenceLimiter(maximumIntervalMillis = 500L)
        limiter.recordInference(10_000L)
        assertEquals(500L, limiter.currentIntervalMillis())
    }
}
