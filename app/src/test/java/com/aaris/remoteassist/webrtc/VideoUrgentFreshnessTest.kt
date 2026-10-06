package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class VideoUrgentFreshnessTest {
    private fun outbound(queueMs: Double): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 1_000_000,
            frames = 60,
            framesSecondary = 60,
            packets = 180,
            packetsLost = 0,
            frameWidth = 1080,
            frameHeight = 2400,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            recent = VideoHealthWindow(
                intervalMs = 1_000,
                frames = 60,
                processingMs = 5.0,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = queueMs
            )
        )

    private fun receiver(jitterMs: Double = 20.0): VideoHealthWindow =
        VideoHealthWindow(
            intervalMs = 1_000,
            frames = 60,
            processingMs = 5.0,
            jitterMs = jitterMs,
            dropped = 0,
            freezes = 0
        )

    @Test
    fun clearlyStaleButNonSevereQueueGetsOneFastSoftStep() {
        val governor = VideoCadenceGovernor(60)

        assertTrue(governor.observe(outbound(queueMs = 120.0), receiver(), 60, 2_000))
        assertEquals(45, governor.cap)
    }

    @Test
    fun ordinaryFullCadenceQueueGetsOneFreshnessStep() {
        val governor = VideoCadenceGovernor(60)

        assertTrue(governor.observe(outbound(queueMs = 70.0), receiver(), 60, 2_000))
        assertEquals(45, governor.cap)
    }

    @Test
    fun lowerCadenceOrdinaryQueueStillRequiresSustainedPressure() {
        val governor = VideoCadenceGovernor(30)

        assertFalse(governor.observe(outbound(queueMs = 80.0), receiver(), 30, 1_000))
        assertTrue(governor.observe(outbound(queueMs = 80.0), receiver(), 30, 2_000))
        assertEquals(24, governor.cap)
    }

    @Test
    fun halfSecondGlassHitchRelievesSixtyBeforeNextStatsWindow() {
        val governor = VideoCadenceGovernor(60)

        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                interactionActive = true,
                nowMs = 500
            )
        )
        assertEquals(45, governor.cap)
    }

    @Test
    fun ordinaryFortyFiveCadenceVarianceDoesNotCascade() {
        val governor = VideoCadenceGovernor(60)
        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                interactionActive = true,
                nowMs = 500
            )
        )

        assertFalse(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 20,
                maxGapMs = 80,
                requestedFps = 45,
                interactionActive = true,
                nowMs = 1_000
            )
        )
        assertEquals(45, governor.cap)
    }

    @Test
    fun severePersistentGlassStallCanTakeSecondBoundedStep() {
        val governor = VideoCadenceGovernor(60)
        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                interactionActive = true,
                nowMs = 500
            )
        )

        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 180,
                requestedFps = 45,
                interactionActive = true,
                nowMs = 1_000
            )
        )
        assertEquals(30, governor.cap)
    }

    @Test
    fun presentationFastPathNeedsActiveRecentHighCadenceEvidence() {
        val inactive = VideoCadenceGovernor(60)
        assertFalse(
            inactive.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 180,
                requestedFps = 60,
                interactionActive = false,
                nowMs = 500
            )
        )
        assertEquals(60, inactive.cap)

        val stale = VideoCadenceGovernor(60)
        assertFalse(
            stale.observeFastPresentation(
                intervalMs = 3_000,
                renderedFrames = 30,
                maxGapMs = 180,
                requestedFps = 60,
                interactionActive = true,
                nowMs = 3_000
            )
        )
        assertEquals(60, stale.cap)

        val lowCadence = VideoCadenceGovernor(30)
        assertFalse(
            lowCadence.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 5,
                maxGapMs = 180,
                requestedFps = 30,
                interactionActive = true,
                nowMs = 500
            )
        )
        assertEquals(30, lowCadence.cap)
    }

    @Test
    fun fastSoftStepCannotImmediatelyCascadeToThirty() {
        val governor = VideoCadenceGovernor(60)
        assertTrue(governor.observe(outbound(queueMs = 120.0), receiver(), 60, 2_000))

        assertFalse(governor.observe(outbound(queueMs = 120.0), receiver(), 45, 3_000))
        assertEquals(45, governor.cap)
    }
}
