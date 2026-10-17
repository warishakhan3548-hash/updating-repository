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

    @Test
    fun sampledTouchCadencesStayNearSixtyHzWithoutCatchUpBursts() {
        for (inputHz in listOf(60, 90, 120, 144)) {
            val pacer = GestureStreamPacer()
            val sent = mutableListOf<Long>()
            for (index in 0 until inputHz * 10) {
                val eventTime = 1_000L + (index * 1_000L + inputHz / 2) / inputHz
                if (pacer.shouldAttempt(eventTime)) {
                    sent += eventTime
                    pacer.onSent(eventTime)
                    assertFalse("Repeated event at $inputHz Hz", pacer.shouldAttempt(eventTime))
                }
            }

            assertTrue("Too few samples at $inputHz Hz: ${sent.size}", sent.size >= 590)
            assertTrue("Exceeded nominal cadence at $inputHz Hz: ${sent.size}", sent.size <= 626)
            val maximumGapMs = 16L + (1_000L + inputHz - 1) / inputHz
            for ((previous, current) in sent.zipWithNext()) {
                assertTrue("Unbounded sample gap at $inputHz Hz", current - previous in 1L..maximumGapMs)
            }
        }
    }

    @Test
    fun lateSamplePreservesTheNextDeadlineInsteadOfRestartingItsPhase() {
        val pacer = GestureStreamPacer()
        pacer.onSent(1_000L)

        assertTrue(pacer.shouldAttempt(1_022L))
        pacer.onSent(1_022L)

        assertFalse(pacer.shouldAttempt(1_031L))
        assertTrue(pacer.shouldAttempt(1_032L))
    }

    @Test
    fun backpressureReanchorsCooldownAfterALateSampleThenRecovers() {
        val pacer = GestureStreamPacer()
        pacer.onSent(1_000L)
        assertTrue(pacer.shouldAttempt(1_022L))
        pacer.onBackpressure(1_022L)

        assertEquals(32L, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(1_053L))
        assertTrue(pacer.shouldAttempt(1_054L))
        pacer.onBackpressure(1_054L)
        assertEquals(48L, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(1_101L))
        assertTrue(pacer.shouldAttempt(1_102L))

        var eventTime = 1_102L
        for (expectedInterval in listOf(44L, 40L, 36L, 32L, 28L, 24L, 20L, 16L)) {
            pacer.onSent(eventTime)
            assertEquals(expectedInterval, pacer.currentIntervalMs())
            assertFalse(pacer.shouldAttempt(eventTime + expectedInterval - 1))
            eventTime += expectedInterval
            assertTrue(pacer.shouldAttempt(eventTime))
        }
    }

    @Test
    fun stalledStreamDiscardsMissedDeadlinesBeforeResuming() {
        val pacer = GestureStreamPacer()
        pacer.onSent(1_000L)

        assertTrue(pacer.shouldAttempt(5_000L))
        pacer.onSent(5_000L)
        for (eventTime in 5_000L..5_015L) {
            assertFalse(pacer.shouldAttempt(eventTime))
        }
        assertTrue(pacer.shouldAttempt(5_016L))
        pacer.onSent(5_016L)
        assertFalse(pacer.shouldAttempt(5_016L))
        assertFalse(pacer.shouldAttempt(5_031L))
        assertTrue(pacer.shouldAttempt(5_032L))
    }

    @Test
    fun backwardsClockRebasesWithoutBypassingBackpressure() {
        val pacer = GestureStreamPacer()
        pacer.onSent(1_000L)
        pacer.onBackpressure(1_022L)

        assertFalse(pacer.shouldAttempt(100L))
        assertFalse(pacer.shouldAttempt(131L))
        assertTrue(pacer.shouldAttempt(132L))
        pacer.onSent(132L)
        assertEquals(28L, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(132L))
        assertFalse(pacer.shouldAttempt(159L))
        assertTrue(pacer.shouldAttempt(160L))
    }

    @Test
    fun newAuthoritativeStartCanRebaseTheEventClock() {
        val pacer = GestureStreamPacer()
        pacer.onSent(1_000L)
        pacer.onSent(100L)

        assertFalse(pacer.shouldAttempt(115L))
        assertTrue(pacer.shouldAttempt(116L))
    }

    @Test
    fun unrepresentableDeadlineCannotWrapOrReadmitTheSameTimestamp() {
        val pacer = GestureStreamPacer()
        pacer.onSent(Long.MAX_VALUE - 8L)

        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE - 1L))
        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE))
        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE))

        pacer.reset()
        assertTrue(pacer.shouldAttempt(Long.MAX_VALUE))
        pacer.onSent(Long.MAX_VALUE)
        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE))

        assertFalse(pacer.shouldAttempt(100L))
        assertFalse(pacer.shouldAttempt(115L))
        assertTrue(pacer.shouldAttempt(116L))
    }

    @Test
    fun pressureAndRecoveryStepsRemainBoundedAtExtremeValues() {
        val pacer = GestureStreamPacer(
            minIntervalMs = 1L,
            maxIntervalMs = Long.MAX_VALUE,
            pressureStepMs = Long.MAX_VALUE,
            recoveryStepMs = Long.MAX_VALUE
        )
        pacer.onBackpressure(0L)
        assertEquals(Long.MAX_VALUE, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE - 1L))
        assertTrue(pacer.shouldAttempt(Long.MAX_VALUE))

        pacer.onSent(Long.MAX_VALUE)
        assertEquals(1L, pacer.currentIntervalMs())
        assertFalse(pacer.shouldAttempt(Long.MAX_VALUE))
    }

    @Test
    fun deadlinesAlsoRemainOrderedAtTheMinimumTimestamp() {
        val pacer = GestureStreamPacer()
        pacer.onSent(Long.MIN_VALUE)

        assertFalse(pacer.shouldAttempt(Long.MIN_VALUE + 15L))
        assertTrue(pacer.shouldAttempt(Long.MIN_VALUE + 16L))
        pacer.onBackpressure(Long.MIN_VALUE + 16L)
        assertFalse(pacer.shouldAttempt(Long.MIN_VALUE + 47L))
        assertTrue(pacer.shouldAttempt(Long.MIN_VALUE + 48L))
    }
}
