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
    fun retainedUnsequencedPresentationDoesNotPromoteCadence() {
        val governor = VideoCadenceGovernor(maxFps = 60, initialCap = 30)
        val cleanSender = outbound(fps = 30, processingMs = 4.0, queueMs = 4.0)
        val retainedGlass = VideoHealthWindow(
            intervalMs = 1_000,
            frames = 30,
            processingMs = 4.0,
            jitterMs = 5.0,
            dropped = 0,
            freezes = 0,
            presentationIntervalMs = 1_000,
            presentedFrames = 30,
            maxRenderGapMs = 34,
            presentationAgeMs = 100,
            displayRefreshRateHz = 60.0,
            presentationSampleFresh = false
        )

        // A held but unsequenced EGL window is not a second promotion vote.
        assertFalse(governor.observe(
            cleanSender, retainedGlass, 30, 1_000L, producerFps = 60.0
        ))
        assertFalse(governor.observe(
            cleanSender, retainedGlass, 30, 2_000L, producerFps = 60.0
        ))
        assertEquals(30, governor.cap)
    }

    @Test
    fun clarityBandwidthReliefRequiresTwoStableWindows() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 60
            )

        assertFalse(
            governor.observeClarityBandwidthCeiling(
                ceilingFps = 35,
                requestedFps = 60,
                nowMs = 1_000L
            )
        )
        assertEquals(60, governor.cap)

        assertTrue(
            governor.observeClarityBandwidthCeiling(
                ceilingFps = 35,
                requestedFps = 60,
                nowMs = 2_000L
            )
        )
        // With no physical clock evidence yet, use the existing safe cadence
        // ladder and choose the nearest rung under the measured BWE ceiling.
        assertEquals(33, governor.cap)
        assertTrue(
            governor.debugSummary(2_000L)
                .contains("clarity-bwe-relief->33")
        )
    }

    @Test
    fun sixtyHzBwePredictionPrefersReadablePixelsBeforeThirtyFpsCliff() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 60
            )

        assertTrue(
            governor.prefersSpatialReliefForClarityBandwidth(
                ceilingFps = 52,
                requestedFps = 60,
                displayRefreshRateHz = 60.0,
                sourceRefreshRateHz = 60.0
            )
        )
        assertTrue(governor.mayReduceMotionResolution(60))

        // The cadence vote itself is suppressed, so repeated BWE-only samples
        // cannot silently turn a smooth 60 Hz source into 30 fps.
        repeat(3) { index ->
            assertFalse(
                governor.observeClarityBandwidthCeiling(
                    ceilingFps = 52,
                    requestedFps = 60,
                    nowMs = 1_000L + index * 1_000L,
                    displayRefreshRateHz = 60.0,
                    sourceRefreshRateHz = 60.0
                )
            )
        }
        assertEquals(60, governor.cap)
        assertTrue(
            governor.debugSummary(3_000L)
                .contains("clarity-bwe-spatial-first@60")
        )

        // A 120 Hz producer has an exact 40 fps rung, so temporal-first remains
        // valid there and the spatial lane does not preempt it.
        val oneTwentyHz =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 60
            )
        assertFalse(
            oneTwentyHz.prefersSpatialReliefForClarityBandwidth(
                ceilingFps = 52,
                requestedFps = 60,
                displayRefreshRateHz = 90.0,
                sourceRefreshRateHz = 120.0
            )
        )
        assertFalse(oneTwentyHz.mayReduceMotionResolution(60))
    }

    @Test
    fun transientBandwidthVoteCannotDownshiftCadenceLater() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 60
            )

        assertFalse(
            governor.observeClarityBandwidthCeiling(
                ceilingFps = 35,
                requestedFps = 60,
                nowMs = 1_000L
            )
        )
        assertFalse(
            governor.observeClarityBandwidthCeiling(
                ceilingFps = null,
                requestedFps = 60,
                nowMs = 1_500L
            )
        )
        assertFalse(
            governor.observeClarityBandwidthCeiling(
                ceilingFps = 35,
                requestedFps = 60,
                nowMs = 2_000L
            )
        )
        assertEquals(60, governor.cap)
    }

    @Test
    fun startupCadenceBeginsAtThirtyAndRecoversThroughFineCadenceSteps() {
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
                maxRenderGapMs = 34,
                presentationAgeMs = 100,
                displayRefreshRateHz = 60.0
            )

        assertFalse(
            governor.observe(
                healthySender,
                healthyReceiver,
                30,
                1_000L,
                producerFps = 60.0
            )
        )

        assertTrue(
            governor.observe(
                healthySender,
                healthyReceiver,
                30,
                2_000L,
                producerFps = 60.0
            )
        )
        assertEquals(36, governor.cap)
    }

    @Test
    fun remoteInteractionImmediatelyEscapesAStaleFifteenFpsCap() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)

        assertTrue(
            governor.ensureInteractionFloor(
                minimumFps = 24,
                nowMs = 1_000L
            )
        )
        assertEquals(24, governor.cap)
        assertFalse(
            governor.ensureInteractionFloor(
                minimumFps = 24,
                nowMs = 1_001L
            )
        )
    }

    @Test
    fun cleanActiveMotionRescuesRecentOverloadFromFifteenToTwentyFour() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)

        // Mark a very recent overload while already parked at the lowest rung.
        // A blind finger-down promotion must remain blocked.
        assertFalse(
            governor.observe(
                outbound = outbound(
                    fps = 5,
                    processingMs = 60.0,
                    queueMs = 300.0
                ),
                receiver = null,
                requestedFps = 15,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertFalse(governor.ensureInteractionFloor(24, 1_100L))
        assertEquals(15, governor.cap)

        val cleanForTwentyFour =
            outbound(
                fps = 15,
                processingMs = 30.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 14,
                packetLossRatio = 0.0,
                codecImplementation = "c2.mtk.avc.encoder"
            )

        // Two fresh active windows prove 24 fps is sustainable even though
        // the older overload cooldown has not expired yet.
        assertFalse(
            governor.tryProbeDuringInteraction(
                outbound = cleanForTwentyFour,
                receiver = null,
                producerFps = 60.0,
                interactionActive = true,
                nowMs = 1_500L
            )
        )
        assertTrue(
            governor.tryProbeDuringInteraction(
                outbound = cleanForTwentyFour,
                receiver = null,
                producerFps = 60.0,
                interactionActive = true,
                nowMs = 2_000L
            )
        )
        assertEquals(24, governor.cap)
        assertTrue(
            governor.debugSummary(2_000L)
                .contains("interaction-clean-rescue->24")
        )
    }

    @Test
    fun lowTierInteractionCannotPromotePastTwentyFps() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 15
            )
        val clean =
            outbound(
                fps = 15,
                processingMs = 20.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 14,
                packetLossRatio = 0.0,
                codecImplementation = "c2.mtk.avc.encoder"
            )

        assertFalse(
            governor.tryProbeDuringInteraction(
                outbound = clean,
                receiver = null,
                producerFps = 30.0,
                interactionActive = true,
                nowMs = 1_000L,
                maximumFps = 20
            )
        )
        assertTrue(
            governor.tryProbeDuringInteraction(
                outbound = clean,
                receiver = null,
                producerFps = 30.0,
                interactionActive = true,
                nowMs = 1_500L,
                maximumFps = 20
            )
        )
        assertEquals(20, governor.cap)

        repeat(4) { index ->
            assertFalse(
                governor.tryProbeDuringInteraction(
                    outbound = clean,
                    receiver = null,
                    producerFps = 30.0,
                    interactionActive = true,
                    nowMs = 2_000L + index * 500L,
                    maximumFps = 20
                )
            )
        }
        assertEquals(20, governor.cap)
    }

    @Test
    fun quietRecoveryAlsoHonorsLowTierTwentyFpsCeiling() {
        val governor =
            VideoCadenceGovernor(
                maxFps = 60,
                initialCap = 15
            )
        val quiet =
            outbound(
                fps = 1,
                processingMs = 4.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 20,
                packetLossRatio = 0.0,
                qualityLimitationReason = "none"
            )

        assertTrue(
            governor.tryProbeAfterQuiet(
                outbound = quiet,
                producerFps = 1.0,
                telemetryAtMs = 9_000L,
                nowMs = 10_000L,
                maximumFps = 20
            )
        )
        assertEquals(20, governor.cap)

        assertFalse(
            governor.tryProbeAfterQuiet(
                outbound = quiet,
                producerFps = 1.0,
                telemetryAtMs = 10_000L,
                nowMs = 20_000L,
                maximumFps = 20
            )
        )
        assertEquals(20, governor.cap)
    }

    @Test
    fun moderateResidualLossCanEscapeStickyFifteenWhenLocalPathIsClean() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        val recovered =
            outbound(
                fps = 15,
                processingMs = 27.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 120,
                packetLossRatio = 0.06,
                codecImplementation = "c2.mtk.avc.encoder"
            )

        assertFalse(
            governor.tryProbeDuringInteraction(
                outbound = recovered,
                receiver = null,
                producerFps = 30.0,
                interactionActive = true,
                nowMs = 1_000L
            )
        )
        assertTrue(
            governor.tryProbeDuringInteraction(
                outbound = recovered,
                receiver = null,
                producerFps = 30.0,
                interactionActive = true,
                nowMs = 1_500L
            )
        )
        assertEquals(24, governor.cap)
    }

    @Test
    fun severeResidualLossStillBlocksStickyFifteenRescue() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        val lossy =
            outbound(
                fps = 15,
                processingMs = 27.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 120,
                packetLossRatio = 0.10,
                codecImplementation = "c2.mtk.avc.encoder"
            )

        repeat(4) { index ->
            assertFalse(
                governor.tryProbeDuringInteraction(
                    outbound = lossy,
                    receiver = null,
                    producerFps = 30.0,
                    interactionActive = true,
                    nowMs = 1_000L + index * 500L
                )
            )
        }
        assertEquals(15, governor.cap)
    }

    @Test
    fun cleanInteractionRescueStillRejectsCodecThatCannotSustainTwentyFour() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        val tooSlow =
            outbound(
                fps = 15,
                processingMs = 39.0,
                queueMs = 0.0
            ).copy(
                roundTripTimeMs = 14,
                packetLossRatio = 0.0
            )

        repeat(4) { index ->
            assertFalse(
                governor.tryProbeDuringInteraction(
                    outbound = tooSlow,
                    receiver = null,
                    producerFps = 60.0,
                    interactionActive = true,
                    nowMs = 1_000L + index * 500L
                )
            )
        }
        assertEquals(15, governor.cap)
    }
    @Test
    fun cleanRecordedHardwarePathQuicklyProbesThirtyFpsDuringInteraction() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        assertTrue(governor.ensureInteractionFloor(24, 0L))

        // Mirrors the uploaded recording: source is ~45-50 fps, hardware H.264
        // work is ~20-23 ms/frame, RTT is tiny and sender queue is essentially
        // empty, yet the old governor stayed target=15fps.
        val clean = outbound(
            fps = 16,
            processingMs = 22.0,
            queueMs = 0.0
        ).copy(
            roundTripTimeMs = 14,
            packetLossRatio = 0.0,
            codecImplementation = "c2.mtk.avc.encoder"
        )

        assertFalse(
            governor.tryProbeDuringInteraction(
                outbound = clean,
                receiver = null,
                producerFps = 45.0,
                interactionActive = true,
                nowMs = 1_000L
            )
        )
        assertTrue(
            governor.tryProbeDuringInteraction(
                outbound = clean,
                receiver = null,
                producerFps = 50.0,
                interactionActive = true,
                nowMs = 2_000L
            )
        )
        assertEquals(30, governor.cap)
    }

    @Test
    fun interactiveThirtyFpsProbeRejectsQueueOrSlowCodecPressure() {
        val governor = VideoCadenceGovernor(maxFps = 30, initialCap = 15)
        assertTrue(governor.ensureInteractionFloor(24, 0L))

        val queued = outbound(
            fps = 16,
            processingMs = 22.0,
            queueMs = 120.0
        )
        repeat(4) { index ->
            assertFalse(
                governor.tryProbeDuringInteraction(
                    outbound = queued,
                    receiver = null,
                    producerFps = 50.0,
                    interactionActive = true,
                    nowMs = 1_000L + index * 1_000L
                )
            )
        }
        assertEquals(24, governor.cap)

        val slowCodec = outbound(
            fps = 16,
            processingMs = 31.0,
            queueMs = 0.0
        )
        repeat(3) { index ->
            assertFalse(
                governor.tryProbeDuringInteraction(
                    outbound = slowCodec,
                    receiver = null,
                    producerFps = 50.0,
                    interactionActive = true,
                    nowMs = 6_000L + index * 1_000L
                )
            )
        }
        assertEquals(24, governor.cap)
    }

    @Test
    fun proofOfGlassHeartbeatDistinguishesSparseCadenceFromDisplayStall() {
        val healthySender =
            outbound(
                fps = 30,
                processingMs = 5.0,
                queueMs = 5.0
            )

        val freshGlass =
            VideoHealthWindow(
                intervalMs = 1_000,
                frames = 30,
                processingMs = 5.0,
                jitterMs = 5.0,
                dropped = 0,
                freezes = 0,
                presentationAgeMs = 250
            )
        val freshGovernor = VideoCadenceGovernor(maxFps = 30, initialCap = 30)
        assertFalse(freshGovernor.observe(healthySender, freshGlass, 30, 1_000L))
        assertFalse(freshGovernor.observe(healthySender, freshGlass, 30, 2_000L))
        assertEquals(30, freshGovernor.cap)

        val staleGlass = freshGlass.copy(presentationAgeMs = 2_000)
        val stalledGovernor = VideoCadenceGovernor(maxFps = 30, initialCap = 30)
        assertFalse(stalledGovernor.observe(healthySender, staleGlass, 30, 1_000L))
        assertTrue(stalledGovernor.observe(healthySender, staleGlass, 30, 2_000L))
        assertEquals(24, stalledGovernor.cap)
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
