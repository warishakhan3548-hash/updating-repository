package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PresentationProvenRecoveryTest {
    private fun outbound(frames: Int, processingMs: Double, queueMs: Double = 0.0) =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/VP8",
            bytes = 100_000,
            frames = frames.toLong(),
            framesSecondary = frames.toLong(),
            packets = (frames * 3).toLong(),
            packetsLost = 0,
            frameWidth = 1080,
            frameHeight = 2400,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            recent = VideoHealthWindow(
                intervalMs = 1000,
                frames = frames,
                processingMs = processingMs,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = queueMs
            )
        )

    private fun receiver(
        frames: Int,
        processingMs: Double,
        presentedFrames: Int = 0,
        maxRenderGapMs: Int? = null
    ) = VideoHealthWindow(
        intervalMs = 1000,
        frames = frames,
        processingMs = processingMs,
        jitterMs = 20.0,
        dropped = 0,
        freezes = 0,
        presentationIntervalMs = if (presentedFrames > 0) 1000 else null,
        presentedFrames = presentedFrames,
        maxRenderGapMs = maxRenderGapMs
    )

    @Test
    fun verifiedControllerPresentationLetsTransientDownshiftRecoverWithoutLongStickyLag() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 60, processingMs = 25.0)

        assertFalse(governor.observe(sending60, overloadedReceiver, 60, 1_000))
        assertTrue(governor.observe(sending60, overloadedReceiver, 60, 2_000))
        assertEquals(30, governor.cap)

        val healthySender = outbound(frames = 30, processingMs = 5.0)
        val healthyDisplay = receiver(
            frames = 30,
            processingMs = 5.0,
            presentedFrames = 30,
            maxRenderGapMs = 35
        )

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    healthySender,
                    healthyDisplay,
                    30,
                    3_000L + index * 1_000L
                )
            )
        }
        assertTrue(governor.observe(healthySender, healthyDisplay, 30, 7_000))
        assertEquals(60, governor.cap)
    }
}
