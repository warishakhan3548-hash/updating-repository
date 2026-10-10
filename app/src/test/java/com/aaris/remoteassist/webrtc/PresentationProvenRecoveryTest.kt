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
        maxRenderGapMs = maxRenderGapMs,
        presentationAgeMs = 100,
        displayRefreshRateHz = 60.0
    )

    @Test
    fun verifiedPresentationRecoversFineCadenceBackToSixty() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 30, processingMs = 25.0)

        assertFalse(governor.observe(sending60, overloadedReceiver, 60, 1_000))
        assertTrue(governor.observe(sending60, overloadedReceiver, 60, 2_000))
        val pacedRelief =
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 60.0,
                ceilingFps = 60
            )!!
        assertEquals(pacedRelief, governor.cap)

        val healthySender = outbound(frames = 60, processingMs = 5.0)
        val healthyDisplay = receiver(
            frames = 60,
            processingMs = 5.0,
            presentedFrames = 60,
            maxRenderGapMs = 20
        )

        // After one display-paced relief step, recovery waits through the
        // bounded cooldown, then requires fresh sender/decode/EGL proof before
        // earning the 60-fps trial and validating it with new glass windows.
        repeat(9) { index ->
            governor.observe(
                healthySender,
                healthyDisplay,
                governor.cap,
                3_000L + index * 1_000L,
                producerFps = 60.0
            )
        }
        assertEquals(60, governor.cap)
        assertFalse(governor.probingHighCadence)
    }

    @Test
    fun missingPresentationProofKeepsConservativeRecoveryInterval() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 30, processingMs = 25.0)
        governor.observe(sending60, overloadedReceiver, 60, 1_000)
        governor.observe(sending60, overloadedReceiver, 60, 2_000)
        val pacedRelief =
            DisplayCadencePolicy.nextLower(
                currentFps = 60,
                refreshRateHz = 60.0,
                ceilingFps = 60
            )!!
        assertEquals(pacedRelief, governor.cap)

        val healthySender =
            outbound(frames = pacedRelief, processingMs = 5.0)
        val decoderOnly =
            receiver(frames = pacedRelief, processingMs = 5.0)
        repeat(8) { index ->
            assertFalse(
                governor.observe(
                    healthySender,
                    decoderOnly,
                    governor.cap,
                    3_000L + index * 1_000L,
                    producerFps = 60.0
                )
            )
        }
        assertEquals(pacedRelief, governor.cap)
    }
}
