package com.aaris.remoteassist.ui

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class GestureStreamPacerTest {
    @Test
    fun healthyPathRunsAtLowLatencyFloor() {
        val pacer = GestureStreamPacer()

        assertTrue(pacer.shouldAttempt(1_000L))
        pacer.onSent(1_000L)

        assertFalse(pacer.shouldAttempt(1_015L))
        assertTrue(pacer.shouldAttempt(1_016L))
        assertEquals(16L, pacer.currentIntervalMs())
    }

    @Test
    fun backpressureAddsStrongCooldownInsteadOfBusyRetrying() {
        val pacer = GestureStreamPacer()

        pacer.onBackpressure(1_000L)

        assertEquals(32L, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(1_031L))
        assertTrue(pacer.shouldAttempt(1_032L))
    }

    @Test
    fun repeatedPressureCapsAndHealthySendsRecoverGradually() {
        val pacer = GestureStreamPacer()

        pacer.onBackpressure(1_000L)
        pacer.onBackpressure(1_100L)
        assertEquals(48L, pacer.currentIntervalMs())

        pacer.onBackpressure(1_200L)
        assertEquals(48L, pacer.currentIntervalMs())

        pacer.onSent(1_500L)
        assertEquals(44L, pacer.currentIntervalMs())
        pacer.onSent(1_600L)
        assertEquals(40L, pacer.currentIntervalMs())
    }

    @Test
    fun resetRestoresImmediateSixtyHzClassAttempt() {
        val pacer = GestureStreamPacer()

        pacer.onBackpressure(5_000L)
        pacer.reset()

        assertEquals(16L, pacer.currentIntervalMs())
        assertTrue(pacer.shouldAttempt(5_001L))
    }
}
