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
    fun verifiedPresentationRecoversFrom45FpsWithoutStickyLag() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 30, processingMs = 25.0)

        assertFalse(governor.observe(sending60, overloadedReceiver, 60, 1_000))
        assertTrue(governor.observe(sending60, overloadedReceiver, 60, 2_000))
        assertEquals(45, governor.cap)

        val healthySender = outbound(frames = 45, processingMs = 5.0)
        val healthyDisplay = receiver(
            frames = 45,
            processingMs = 5.0,
            presentedFrames = 45,
            maxRenderGapMs = 30
        )

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    healthySender,
                    healthyDisplay,
                    45,
                    3_000L + index * 1_000L
                )
            )
        }
        assertTrue(governor.observe(healthySender, healthyDisplay, 45, 7_000))
        assertEquals(60, governor.cap)
    }

    @Test
    fun missingPresentationProofKeepsConservativeRecoveryInterval() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 30, processingMs = 25.0)
        governor.observe(sending60, overloadedReceiver, 60, 1_000)
        governor.observe(sending60, overloadedReceiver, 60, 2_000)
        assertEquals(45, governor.cap)

        val healthySender = outbound(frames = 45, processingMs = 5.0)
        val decoderOnly = receiver(frames = 45, processingMs = 5.0)
        repeat(8) { index ->
            assertFalse(governor.observe(healthySender, decoderOnly, 45, 3_000L + index * 1_000L))
        }
        assertEquals(45, governor.cap)
    }
}
