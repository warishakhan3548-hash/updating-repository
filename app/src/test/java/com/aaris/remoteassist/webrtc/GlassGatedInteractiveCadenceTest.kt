package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * The host must not promote interactive 24 -> 30 FPS using encoder/pacer
 * headroom without the current receiver's new EGL presentation proof.
 * Keep the independently measured sub-24 FPS recovery path available.
 */
class GlassGatedInteractiveCadenceTest {
    private fun sender(
        fps: Int = 16,
        processingMs: Double = 22.0,
        queueMs: Double = 0.0
    ) = VideoHealthSnapshot(
        direction = "outbound",
        codec = "video/H264",
        bytes = 100_000,
        frames = fps.toLong(),
        framesSecondary = fps.toLong(),
        packets = (fps * 3).toLong(),
        packetsLost = 0,
        frameWidth = 360,
        frameHeight = 800,
        qualityLimitationReason = "none",
        roundTripTimeMs = 14,
        packetLossRatio = 0.0,
        codecImplementation = "c2.mtk.avc.encoder",
        recent = VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = processingMs,
            jitterMs = null,
            dropped = null,
            freezes = null,
            sendQueueMs = queueMs
        )
    )

    @Test
    fun senderHeadroomCannotPromoteWhenFreshGlassProofIsMissing() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        assertTrue(governor.ensureInteractionFloor(24, 0L))

        // Even many consecutive clean sender samples cannot stand in for
        // actual glass-delivery evidence from the receiving phone.
        for (time in listOf(1_000L, 2_000L, 3_000L)) {
            assertFalse(governor.tryProbeDuringInteraction(
                outbound = sender(),
                receiver = null,
                producerFps = 50.0,
                interactionActive = true,
                nowMs = time,
                allowHighCadencePromotion = false
            ))
            assertEquals(24, governor.cap)
        }

        // Once the host receives a newly confirmed clean presentation window,
        // preserved sender headroom can authorize the same fast promotion.
        assertTrue(governor.tryProbeDuringInteraction(
            outbound = sender(),
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 4_000L,
            allowHighCadencePromotion = true
        ))
        assertEquals(30, governor.cap)
    }

    @Test
    fun missingGlassProofDoesNotDisableSubTwentyFourFpsMotionRescue() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        val healthy = sender(fps = 15, processingMs = 30.0)

        assertFalse(governor.tryProbeDuringInteraction(
            outbound = healthy,
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 1_000L,
            allowHighCadencePromotion = false
        ))
        assertTrue(governor.tryProbeDuringInteraction(
            outbound = healthy,
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 2_000L,
            allowHighCadencePromotion = false
        ))
        assertEquals(24, governor.cap)
    }

    @Test
    fun staleProofCannotOverrideCurrentSenderPressure() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        assertTrue(governor.ensureInteractionFloor(24, 0L))

        repeat(2) { index ->
            assertFalse(governor.tryProbeDuringInteraction(
                outbound = sender(),
                receiver = null,
                producerFps = 50.0,
                interactionActive = true,
                nowMs = (index + 1) * 1_000L,
                allowHighCadencePromotion = false
            ))
        }

        assertFalse(governor.tryProbeDuringInteraction(
            outbound = sender(queueMs = 120.0),
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 3_000L,
            allowHighCadencePromotion = true
        ))
        assertFalse(governor.tryProbeDuringInteraction(
            outbound = sender(),
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 4_000L,
            allowHighCadencePromotion = true
        ))
        assertTrue(governor.tryProbeDuringInteraction(
            outbound = sender(),
            receiver = null,
            producerFps = 50.0,
            interactionActive = true,
            nowMs = 5_000L,
            allowHighCadencePromotion = true
        ))
        assertEquals(30, governor.cap)
    }
}
