package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProducerCaptureReliefTest {
    private val profile =
        CaptureProfile(
            displayWidthPx = 1080,
            displayHeightPx = 2400,
            captureWidthPx = 1080,
            captureHeightPx = 2400,
            fps = 45,
            maxVideoBitrateBps = 10_000_000,
            tier = CaptureTier.STANDARD,
            motionFps = 60
        )

    private fun outbound(
        fps: Int = 6,
        queueMs: Double = 4.0
    ) =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 500_000,
            frames = fps.toLong(),
            framesSecondary = fps.toLong(),
            packets = (fps * 3).toLong(),
            packetsLost = 0,
            frameWidth = 720,
            frameHeight = 1600,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            codecImplementation = "c2.qti.avc.encoder",
            streamId = "screen-1",
            availableOutgoingBitrateBps = 5_000_000.0,
            recent =
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = fps,
                    processingMs = 4.0,
                    jitterMs = null,
                    dropped = null,
                    freezes = null,
                    sendQueueMs = queueMs
                )
        )

    @Test
    fun provenMovingProducerCollapseCommitsSpatialReliefOnAndroidTwelvePlus() {
        val budget = MotionVideoBudget()

        assertTrue(
            budget.primeForMotion(
                profile = profile,
                nowMs = 0L,
                warmStartEvidence = null,
                targetFps = 30
            )
        )
        // The speculative 360 control rung does not resize the native
        // 1080-short-edge source until measured producer pressure proves it.
        assertEquals(
            1080,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )

        assertTrue(
            budget.observe(
                outbound = outbound(),
                receiver = null,
                sourceFps = 6.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                sourceMaxGapMs = 280.0,
                sourceMotionActive = true,
                canResizeProducerSurface = true
            )
        )

        // First proof commits the conservative 360 rung; it does not jump
        // straight to the emergency 240 rung in the same observation.
        assertEquals(
            360,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )
    }

    @Test
    fun legacyAndroidDoesNotSpendPixelsForProducerOnlyPressure() {
        val budget = MotionVideoBudget()
        budget.primeForMotion(
            profile = profile,
            nowMs = 0L,
            warmStartEvidence = null,
            targetFps = 30
        )

        assertFalse(
            budget.observe(
                outbound = outbound(),
                receiver = null,
                sourceFps = 6.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                sourceMaxGapMs = 280.0,
                sourceMotionActive = true,
                canResizeProducerSurface = false
            )
        )

        // Legacy Android cannot resize the producer surface for producer-only
        // pressure, so the native geometry must remain untouched.
        assertEquals(
            1080,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )
    }

    @Test
    fun staticInteractionCannotMasqueradeAsProducerStarvation() {
        val budget = MotionVideoBudget()
        budget.primeForMotion(
            profile = profile,
            nowMs = 0L,
            warmStartEvidence = null,
            targetFps = 30
        )

        assertFalse(
            budget.observe(
                outbound = outbound(fps = 1),
                receiver = null,
                sourceFps = 1.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                sourceMaxGapMs = 700.0,
                sourceMotionActive = false,
                interactionCaptureStarved = true,
                canResizeProducerSurface = true
            )
        )

        // A held/static interaction is not natural MediaProjection motion and
        // therefore must not turn the speculative budget into a source resize.
        assertEquals(
            1080,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )
    }

    @Test
    fun causalInteractionMissesCanBootstrapColdProducerRelief() {
        val budget = MotionVideoBudget()
        budget.primeForMotion(
            profile = profile,
            nowMs = 0L,
            warmStartEvidence = null,
            targetFps = 30
        )

        // A cold 2 fps producer never reaches PassiveMotionPriority's 8 fps
        // entry threshold. Repeated post-input capture misses supply the
        // independent causal proof, but one health window still cannot resize.
        assertFalse(
            budget.observe(
                outbound = outbound(fps = 2),
                receiver = null,
                sourceFps = 2.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                sourceMaxGapMs = 500.0,
                sourceMotionActive = false,
                interactionCaptureStarved = true,
                canResizeProducerSurface = true
            )
        )
        assertEquals(
            1080,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )

        // Two complete pressure windows commit one producer-side relief step.
        assertTrue(
            budget.observe(
                outbound = outbound(fps = 2),
                receiver = null,
                sourceFps = 2.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_500L,
                interactionActive = true,
                sourceMaxGapMs = 500.0,
                sourceMotionActive = false,
                interactionCaptureStarved = true,
                canResizeProducerSurface = true
            )
        )
        assertEquals(
            360,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )
    }

    @Test
    fun largeRawProducerGapCanTriggerReliefEvenWhenAverageFpsLooksUsable() {
        val budget = MotionVideoBudget()
        budget.primeForMotion(
            profile = profile,
            nowMs = 0L,
            warmStartEvidence = null,
            targetFps = 30
        )

        assertTrue(
            budget.observe(
                outbound = outbound(fps = 20),
                receiver = null,
                sourceFps = 20.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true,
                sourceMaxGapMs = 300.0,
                sourceMotionActive = true,
                canResizeProducerSurface = true
            )
        )

        assertEquals(
            360,
            minOf(
                budget.apply(profile, motionActive = true).captureWidthPx,
                budget.apply(profile, motionActive = true).captureHeightPx
            )
        )
    }
}
