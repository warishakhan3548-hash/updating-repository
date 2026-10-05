package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureQualityGovernor
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class AdaptiveScreenSmoothnessTest {
    private fun outbound(
        fps: Int,
        processingMs: Double,
        queueMs: Double
    ): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/VP8",
            bytes = 100_000,
            frames = fps.toLong(),
            framesSecondary = fps.toLong(),
            packets = (fps * 3).toLong(),
            packetsLost = 0,
            frameWidth = 1080,
            frameHeight = 2400,
            qualityLimitationReason = "none",
            roundTripTimeMs = 100,
            packetLossRatio = 0.0,
            recent =
                VideoHealthWindow(
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
    fun startupCadenceBeginsAtThirtyButCanRecoverOneRungAtATime() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 30
            )

        assertEquals(30, governor.cap)

        val healthySender =
            outbound(
                fps = 30,
                processingMs = 4.0,
                queueMs = 4.0
            )
        val healthyReceiver =
            VideoHealthWindow(
                intervalMs = 1_000,
                frames = 30,
                processingMs = 4.0,
                jitterMs = 5.0,
                dropped = 0,
                freezes = 0,
                presentationIntervalMs = 1_000,
                presentedFrames = 30,
                maxRenderGapMs = 34
            )

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    healthySender,
                    healthyReceiver,
                    30,
                    1_000L + index * 1_000L
                )
            )
        }

        assertTrue(
            governor.observe(
                healthySender,
                healthyReceiver,
                30,
                5_000L
            )
        )
        assertEquals(45, governor.cap)
    }

    @Test
    fun threeFpsEncodeCollapseTriggersCadenceReliefInsteadOfLookingStatic() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 30
            )

        assertTrue(
            governor.observe(
                outbound(
                    fps = 3,
                    processingMs = 90.0,
                    queueMs = 20.0
                ),
                receiver = null,
                requestedFps = 30,
                nowMs = 2_000L
            )
        )
        assertEquals(24, governor.cap)
    }

    @Test
    fun sixFpsQueuedCollapseAlsoTriggersCadenceRelief() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 30
            )

        assertTrue(
            governor.observe(
                outbound(
                    fps = 6,
                    processingMs = 20.0,
                    queueMs = 120.0
                ),
                receiver = null,
                requestedFps = 30,
                nowMs = 2_000L
            )
        )
        assertEquals(24, governor.cap)
    }

    @Test
    fun resolutionNeedsSustainedLocalPipelinePressure() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 100,
                packetLossRatio = 0.0,
                encodeTimeMs = 80.0,
                sendQueueMs = 150.0,
                deliveredFps = 5.0,
                requestedFps = 24
            )
        )

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 100,
                packetLossRatio = 0.0,
                encodeTimeMs = 80.0,
                sendQueueMs = 150.0,
                deliveredFps = 5.0,
                requestedFps = 24
            )
        )
    }

    @Test
    fun oneLocalPressureSpikeDoesNotPoisonLaterHealthySamples() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 100,
                packetLossRatio = 0.0,
                encodeTimeMs = 80.0,
                sendQueueMs = 150.0,
                deliveredFps = 5.0,
                requestedFps = 24
            )
        )
        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 100,
                packetLossRatio = 0.0,
                encodeTimeMs = 5.0,
                sendQueueMs = 5.0,
                deliveredFps = 24.0,
                requestedFps = 24
            )
        )

        assertEquals(CaptureTier.STANDARD, governor.currentTier())
    }

    @Test
    fun passiveMotionStaysFreshnessFirstThroughLowFpsCollapseThenExpires() {
        val motion =
            PassiveMotionPriority(
                enterFps = 8.0,
                holdFps = 2.5,
                tailMs = 3_000L
            )

        assertTrue(
            motion.observe(
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = 30,
                    processingMs = 5.0,
                    jitterMs = null,
                    dropped = null,
                    freezes = null
                ),
                1_000L
            )
        )
        assertTrue(motion.isActive(1_000L))

        // A struggling moving video can fall to 3 fps. Keep freshness priority
        // instead of reverting to clarity-first while the pipeline is overloaded.
        assertFalse(
            motion.observe(
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = 3,
                    processingMs = 90.0,
                    jitterMs = null,
                    dropped = null,
                    freezes = null
                ),
                2_000L
            )
        )
        assertTrue(motion.isActive(4_900L))
        assertFalse(motion.isActive(5_001L))
    }
}
