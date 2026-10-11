package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class BweDemandAwareClarityTest {
    private val profile =
        CaptureProfile(
            displayWidthPx = 720,
            displayHeightPx = 1600,
            captureWidthPx = 720,
            captureHeightPx = 1600,
            fps = 30,
            maxVideoBitrateBps = 10_000_000,
            tier = CaptureTier.STANDARD,
            motionFps = 60
        )

    private fun sender(
        fps: Int,
        bitrateBps: Long,
        availableOutgoingBitrateBps: Double
    ): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 0,
            frames = 0,
            framesSecondary = 0,
            packets = 0,
            packetsLost = 0,
            frameWidth = 720,
            frameHeight = 1600,
            qualityLimitationReason = "none",
            roundTripTimeMs = 80,
            packetLossRatio = 0.0,
            codecImplementation = "c2.qti.avc.encoder",
            recent =
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = fps,
                    processingMs = 5.0,
                    jitterMs = null,
                    dropped = null,
                    freezes = null,
                    bitrateBps = bitrateBps,
                    sendQueueMs = 5.0
                ),
            availableOutgoingBitrateBps = availableOutgoingBitrateBps
        )

    private fun receiver(fps: Int): VideoHealthWindow =
        VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = 5.0,
            jitterMs = 5.0,
            dropped = 0,
            freezes = 0,
            presentationIntervalMs = 1_000,
            presentedFrames = fps,
            maxRenderGapMs = 34
        )

    private fun nativeBudget(): MotionVideoBudget =
        MotionVideoBudget().apply {
            assertTrue(
                primeForMotion(
                    profile = profile,
                    nowMs = 0L,
                    warmStartEvidence =
                        sender(
                            fps = 1,
                            bitrateBps = 40_000,
                            availableOutgoingBitrateBps = 4_500_000.0
                        ),
                    targetFps = 30
                )
            )
            assertEquals(720, shortEdge)
        }

    @Test
    fun lowDemandMovingUiDoesNotSpendCadenceForNominalBweShortfall() {
        val budget = nativeBudget()
        val cheapMovingUi =
            sender(
                fps = 60,
                bitrateBps = 700_000,
                availableOutgoingBitrateBps = 4_200_000.0
            )

        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile,
                outbound = cheapMovingUi,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun lowDemandMovingUiDoesNotSpendPixelsForNominalBweShortfall() {
        val budget = nativeBudget()
        val cheapMovingUi =
            sender(
                fps = 30,
                bitrateBps = 300_000,
                availableOutgoingBitrateBps = 2_000_000.0
            )

        repeat(4) { index ->
            assertFalse(
                budget.observe(
                    outbound = cheapMovingUi,
                    receiver = receiver(30),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 4_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }

        assertEquals(720, budget.shortEdge)
    }

    @Test
    fun materialPathUtilizationStillPreemptsQueueGrowth() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        val saturated =
            sender(
                fps = 60,
                bitrateBps = 520_000,
                availableOutgoingBitrateBps = 700_000.0
            )

        assertFalse(
            budget.observe(
                outbound = saturated,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = saturated,
                receiver = receiver(60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)
    }
}
