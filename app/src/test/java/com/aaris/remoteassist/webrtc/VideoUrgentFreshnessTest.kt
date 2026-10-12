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

    private fun measuredHighCadence(): VideoCadenceGovernor =
        VideoCadenceGovernor(60).apply {
            assertFalse(observe(outbound(queueMs = 0.0), null, 60, 0L))
        }

    @Test
    fun clearlyStaleButNonSevereQueueGetsOneFastSoftStep() {
        val governor = VideoCadenceGovernor(60)

        assertTrue(governor.observe(outbound(queueMs = 120.0), receiver(), 60, 2_000))
        assertEquals(58, governor.cap)
    }

    @Test
    fun isolatedOrdinaryFullCadenceQueueBlipDoesNotDownshift() {
        val governor = VideoCadenceGovernor(60)

        assertFalse(governor.observe(outbound(queueMs = 45.0), receiver(), 60, 1_000))
        assertEquals(60, governor.cap)

        assertFalse(governor.observe(outbound(queueMs = 0.0), receiver(), 60, 1_500))
        assertEquals(60, governor.cap)
    }

    @Test
    fun sustainedOrdinaryFullCadenceQueueGetsFineRelief() {
        val governor = VideoCadenceGovernor(60)

        assertFalse(governor.observe(outbound(queueMs = 45.0), receiver(), 60, 1_000))
        assertTrue(governor.observe(outbound(queueMs = 45.0), receiver(), 60, 1_500))
        assertEquals(58, governor.cap)
    }

    @Test
    fun lowerCadenceOrdinaryQueueStillRequiresSustainedPressure() {
        val governor = VideoCadenceGovernor(30)

        assertFalse(governor.observe(outbound(queueMs = 80.0), receiver(), 30, 1_000))
        assertTrue(governor.observe(outbound(queueMs = 80.0), receiver(), 30, 2_000))
        assertEquals(24, governor.cap)
    }

    @Test
    fun oneModerateHalfSecondGlassHitchIsTolerated() {
        val governor = measuredHighCadence()

        assertFalse(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 500
            )
        )
        assertEquals(60, governor.cap)
    }

    @Test
    fun twoModerateGlassHitchesConfirmFineRelief() {
        val governor = measuredHighCadence()

        assertFalse(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 500
            )
        )
        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 1_000
            )
        )
        assertEquals(58, governor.cap)
    }

    @Test
    fun ordinaryFineCadenceVarianceDoesNotCascade() {
        val governor = measuredHighCadence()
        assertFalse(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 500
            )
        )
        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 22,
                maxGapMs = 80,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 1_000
            )
        )

        assertFalse(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 20,
                maxGapMs = 80,
                requestedFps = 58,
                freshnessActive = true,
                nowMs = 1_500
            )
        )
        assertEquals(58, governor.cap)
    }

    @Test
    fun severePersistentGlassStallCanTakeSecondBoundedStep() {
        val governor = measuredHighCadence()
        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 180,
                requestedFps = 60,
                freshnessActive = true,
                nowMs = 500
            )
        )
        assertEquals(58, governor.cap)

        assertTrue(
            governor.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 180,
                requestedFps = 58,
                freshnessActive = true,
                nowMs = 1_000
            )
        )
        assertEquals(55, governor.cap)
    }

    @Test
    fun presentationFastPathNeedsFreshnessAndRecentHighCadenceEvidence() {
        val inactive = measuredHighCadence()
        assertFalse(
            inactive.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 180,
                requestedFps = 60,
                freshnessActive = false,
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
                freshnessActive = true,
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
                freshnessActive = true,
                nowMs = 500
            )
        )
        assertEquals(30, lowCadence.cap)
    }

    @Test
    fun fastSoftStepCannotImmediatelyCascadeToThirty() {
        val governor = VideoCadenceGovernor(60)
        assertTrue(governor.observe(outbound(queueMs = 120.0), receiver(), 60, 2_000))

        assertFalse(governor.observe(outbound(queueMs = 120.0), receiver(), 58, 3_000))
        assertEquals(58, governor.cap)
    }
}
