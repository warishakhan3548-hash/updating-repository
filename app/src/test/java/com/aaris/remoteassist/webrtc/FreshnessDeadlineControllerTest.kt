package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class FreshnessDeadlineControllerTest {
    private fun sender(
        queueMs: Double?,
        encodeMs: Double? = 5.0,
        fps: Int = 60
    ) = VideoHealthWindow(
        intervalMs = 1_000,
        frames = fps,
        processingMs = encodeMs,
        jitterMs = null,
        dropped = null,
        freezes = null,
        sendQueueMs = queueMs
    )

    private fun receiver(
        playoutMs: Double?,
        decodeMs: Double? = 5.0,
        fps: Int = 60
    ) = VideoHealthWindow(
        intervalMs = 1_000,
        frames = fps,
        processingMs = decodeMs,
        jitterMs = playoutMs,
        dropped = 0,
        freezes = 0
    )

    @Test
    fun sixtyFpsTreatsThreeFramePeriodsAsDeadline() {
        val a = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = 12.0),
            receiver = receiver(playoutMs = 18.0)
        )

        assertTrue(a.complete)
        assertEquals(50.0, a.deadlineMs, 0.001)
        assertEquals(30.0, a.controllableDebtMs ?: -1.0, 0.001)
        assertEquals(FreshnessDeadlineController.State.CLEAN, a.state)
        assertFalse(a.pressure)
    }

    @Test
    fun sameAbsoluteDebtGetsMoreRoomAtThirtyFps() {
        val at60 = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = 25.0),
            receiver = receiver(playoutMs = 35.0)
        )
        val at30 = FreshnessDeadlineController.assess(
            targetFps = 30,
            sender = sender(queueMs = 25.0, fps = 30),
            receiver = receiver(playoutMs = 35.0, fps = 30)
        )

        assertTrue(at60.pressure)
        assertEquals(FreshnessDeadlineController.State.CLEAN, at30.state)
        assertFalse(at30.pressure)
    }

    @Test
    fun codecWithinFramePeriodDoesNotMasqueradeAsBacklog() {
        val a = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = 0.0, encodeMs = 5.0),
            receiver = receiver(playoutMs = 20.0, decodeMs = 25.0, fps = 30)
        )

        assertEquals(FreshnessDeadlineController.State.CLEAN, a.state)
        assertFalse(a.pressure)
    }

    @Test
    fun predictiveTargetDelayDoesNotMasqueradeAsActualBacklog() {
        val a =
            FreshnessDeadlineController.assess(
                targetFps = 60,
                sender = sender(queueMs = 15.0),
                receiver =
                    receiver(playoutMs = 10.0)
                        .copy(jitterTargetMs = 90.0)
            )

        assertTrue(a.complete)
        assertEquals(25.0, a.controllableDebtMs ?: -1.0, 0.001)
        assertEquals(FreshnessDeadlineController.State.CLEAN, a.state)
        assertFalse(a.pressure)
    }

    @Test
    fun largeControllableDebtBecomesUrgentBeforeSevere() {
        val a = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = 120.0),
            receiver = receiver(playoutMs = 20.0)
        )

        assertTrue(a.pressure)
        assertTrue(a.urgent)
        assertFalse(a.severe)
    }

    @Test
    fun combinedPacerAndPlayoutDebtCanBecomeSevere() {
        val a = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = 120.0),
            receiver = receiver(playoutMs = 110.0)
        )

        assertTrue(a.severe)
    }

    @Test
    fun missingResidenceEvidenceDoesNotInventADeadline() {
        val a = FreshnessDeadlineController.assess(
            targetFps = 60,
            sender = sender(queueMs = null),
            receiver = receiver(playoutMs = 80.0)
        )

        assertFalse(a.complete)
        assertEquals(FreshnessDeadlineController.State.UNKNOWN, a.state)
        assertFalse(a.pressure)
    }
}
