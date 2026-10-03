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
    fun ordinaryQueueStillRequiresSustainedPressure() {
        val governor = VideoCadenceGovernor(60)

        assertFalse(governor.observe(outbound(queueMs = 70.0), receiver(), 60, 1_000))
        assertTrue(governor.observe(outbound(queueMs = 70.0), receiver(), 60, 2_000))
        assertEquals(45, governor.cap)
    }

    @Test
    fun fastSoftStepCannotImmediatelyCascadeToThirty() {
        val governor = VideoCadenceGovernor(60)
        assertTrue(governor.observe(outbound(queueMs = 120.0), receiver(), 60, 2_000))

        assertFalse(governor.observe(outbound(queueMs = 120.0), receiver(), 45, 3_000))
        assertEquals(45, governor.cap)
    }
}
