package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.*
import org.junit.Test

class MotionVideoBudgetTest {
    private val profile = CaptureProfile(720, 1600, 720, 1600, 30, 3_000_000, CaptureTier.STANDARD, 60)
    private fun sender(fps: Int = 30, encode: Double = 5.0, queue: Double = 5.0, implementation: String = "OMX.qcom") =
        VideoHealthSnapshot("outbound", "video/VP8", 0, 0, 0, 0, 0, 720, 1600, "none", 100, 0.0,
            codecImplementation = implementation,
            recent = VideoHealthWindow(1000, fps, encode, null, null, null, sendQueueMs = queue))
    private fun receiver(fps: Int = 30, decode: Double = 5.0, presented: Int = fps) =
        VideoHealthWindow(1000, fps, decode, 5.0, 0, 0, presentationIntervalMs = 1000,
            presentedFrames = presented, maxRenderGapMs = 34)

    @Test fun newMotionWarmStartsAtThreeSixtyBeforeTelemetryArrives() {
        val budget = MotionVideoBudget()

        assertTrue(budget.primeForMotion(profile, 1_000L))
        assertEquals(360, budget.shortEdge)
        assertEquals(360, budget.apply(profile, true).captureWidthPx)
        assertEquals(800, budget.apply(profile, true).captureHeightPx)
        assertEquals(30, budget.cadenceFloor(profile, true, 1_000L))
        assertEquals(900_000, budget.bitrateCeiling(profile, true))

        // Repeated motion pulses refresh the hold but never keep knocking a
        // stream down after its first warm-start decision.
        assertFalse(budget.primeForMotion(profile, 1_500L))
        assertEquals(360, budget.shortEdge)
    }

    @Test fun recordedSoftwareCollapseReducesPixelsBeforeThirtyFps() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(60, 30)
        val collapse = sender(6, 53.0, 585.0, "libvpx")
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 1000))
        assertEquals(540, budget.shortEdge)
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
        assertFalse(cadence.observe(collapse, null, 30, 1000, budget.cadenceFloor(profile, true, 1000)))
        assertEquals(30, cadence.cap)
        budget.observe(collapse, null, 30.0, true, 30, 4000)
        assertEquals(360, budget.shortEdge)
        assertEquals(800, budget.apply(profile, true).captureHeightPx)
        assertFalse(cadence.observe(collapse, null, 30, 4000, budget.cadenceFloor(profile, true, 4000)))
        // Try the emergency codec budget before giving up motion cadence.
        budget.observe(collapse, null, 30.0, true, 30, 7000)
        assertEquals(240, budget.shortEdge)
        assertFalse(cadence.observe(collapse, null, 30, 7000, budget.cadenceFloor(profile, true, 7000)))
        // At the actual minimum, freshness still has a safety exit.
        assertTrue(cadence.observe(collapse, null, 30, 10000, budget.cadenceFloor(profile, true, 10000)))
        assertTrue(cadence.cap < 30)
    }

    @Test fun recordedTwelveFpsLibvpxAtThirtyOneMsGetsAnotherPixelStepWithLowNetworkDelay() {
        val budget = MotionVideoBudget()
        val recorded = sender(12, 31.0, 16.0, "libvpx").copy(roundTripTimeMs = 11)
        for (time in 1_000L..8_000L step 1_000L) {
            budget.observe(recorded, null, 24.0, true, 30, time)
        }
        assertEquals(240, budget.shortEdge)
        val small = budget.apply(profile, true)
        assertEquals(240, small.captureWidthPx)
        assertEquals(532, small.captureHeightPx)
        assertEquals(720, small.displayWidthPx)
        assertEquals(1600, small.displayHeightPx)
        // Resolution recovers only one rung after sustained delivered 30 FPS.
        repeat(12) { budget.observe(sender(), receiver(), 30.0, true, 30, 20_000L + it * 1_000) }
        assertEquals(360, budget.shortEdge)
    }

    @Test fun networkDelayAloneCannotUseTheEmergencyCodecResolution() {
        val budget = MotionVideoBudget()
        repeat(20) { budget.observe(sender(queue = 160.0), receiver(), 30.0, true, 30, 1_000L + it * 1_000) }
        assertEquals(360, budget.shortEdge)
    }

    @Test fun recordedBandwidthQueueSpendsPixelsBeforeCadence() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(30, 30)
        val recorded = sender(
            fps = 5,
            encode = 20.0,
            queue = 353.0,
            implementation = "OMX.qcom.video.encoder.avc"
        ).copy(
            qualityLimitationReason = "bandwidth",
            roundTripTimeMs = 197
        )

        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        // This mirrors the uploaded trace: source motion is ~14 fps while the
        // sender falls to ~5 fps and packet send residence is hundreds of ms.
        assertTrue(budget.observe(recorded, null, 14.0, true, 30, 1_000L))
        assertEquals(240, budget.shortEdge)
        assertEquals(500_000, budget.bitrateCeiling(profile, true))
        assertFalse(
            cadence.observe(
                recorded,
                null,
                30,
                1_000L,
                budget.cadenceFloor(profile, true, 1_000L),
                producerFps = 14.0
            )
        )
        assertEquals(30, cadence.cap)

        val worse = recorded.copy(
            recent = recorded.recent!!.copy(frames = 2, sendQueueMs = 1_669.0)
        )
        assertTrue(budget.observe(worse, null, 31.0, true, 30, 2_000L))
        assertEquals(180, budget.shortEdge)
        assertEquals(350_000, budget.bitrateCeiling(profile, true))
        assertFalse(
            cadence.observe(
                worse,
                null,
                30,
                2_000L,
                budget.cadenceFloor(profile, true, 2_000L),
                producerFps = 31.0
            )
        )
        assertEquals(30, cadence.cap)

        // Once the smallest pixel rung has had time to drain the old queue,
        // cadence remains the final safety valve if the link is still bad.
        assertTrue(
            cadence.observe(
                worse,
                null,
                30,
                5_100L,
                budget.cadenceFloor(profile, true, 5_100L),
                producerFps = 31.0
            )
        )
        assertTrue(cadence.cap < 30)
    }

    @Test fun bandwidthLabelWithoutMovingSourceCannotOverBlur() {
        val budget = MotionVideoBudget()
        val limited = sender(2, 5.0, 500.0).copy(
            qualityLimitationReason = "bandwidth"
        )

        repeat(8) { index ->
            budget.observe(
                limited,
                null,
                sourceFps = 1.0,
                motionActive = true,
                targetFps = 30,
                nowMs = (index + 1) * 1_000L
            )
        }

        assertEquals(360, budget.shortEdge)
    }

    @Test fun isolatedSpikeDoesNotBlurButSustainedMotionPressureDoes() {
        val budget = MotionVideoBudget()
        budget.observe(sender(20, 35.0), null, 30.0, true, 30, 1000)
        budget.observe(sender(), receiver(), 30.0, true, 30, 2000)
        assertEquals(720, budget.shortEdge)
        budget.observe(sender(20, 35.0), null, 30.0, true, 30, 3000)
        budget.observe(sender(20, 35.0), null, 30.0, true, 30, 4000)
        assertEquals(540, budget.shortEdge)
    }

    @Test fun sourceActivityDetectsMotionEvenWhenEncoderStartsAtTwoFps() {
        val motion = PassiveMotionPriority()
        assertTrue(motion.observe(sender(2).recent, 1000, sourceFps = 30.0))
        assertTrue(motion.isActive(1000))
        motion.observe(sender(2).recent, 2000, sourceFps = 0.0)
        motion.observe(sender(2).recent, 5001, sourceFps = 0.0)
        assertFalse(motion.isActive(5001))
    }

    @Test fun bandwidthLabelNeedsMovingSourceAndUnderDelivery() {
        val budget = MotionVideoBudget()
        val limited = sender(5).copy(qualityLimitationReason = "bandwidth")
        repeat(5) { budget.observe(limited, null, 0.0, true, 30, (it + 1) * 1000L) }
        assertEquals(720, budget.shortEdge)
        budget.observe(limited, null, 30.0, true, 30, 6000)
        budget.observe(limited, null, 30.0, true, 30, 7000)
        assertEquals(540, budget.shortEdge)
    }

    @Test fun healthyTransportAtFifteenFpsDoesNotUpgradeResolution() {
        val budget = MotionVideoBudget()
        budget.observe(sender(6, 60.0, 200.0), null, 30.0, true, 30, 1000)
        assertEquals(540, budget.shortEdge)
        repeat(30) { budget.observe(sender(15), receiver(15), 30.0, true, 30, 5000L + it * 1000) }
        assertEquals(540, budget.shortEdge)
        repeat(12) { budget.observe(sender(), receiver(), 30.0, true, 30, 40000L + it * 1000) }
        assertEquals(720, budget.shortEdge)
    }

    @Test fun receiverStallsAlsoReducePixelBudget() {
        val budget = MotionVideoBudget()
        budget.observe(sender(), receiver(presented = 10), 30.0, true, 30, 1000)
        budget.observe(sender(), receiver(presented = 10), 30.0, true, 30, 2000)
        assertEquals(540, budget.shortEdge)
    }

    @Test fun rotationAndIdleRecoveryPreserveLogicalGeometryAndDoNotUpscale() {
        val budget = MotionVideoBudget()
        budget.observe(sender(6, 60.0, 200.0), null, 30.0, true, 30, 1000)
        val landscape = profile.copy(displayWidthPx = 1600, displayHeightPx = 720,
            captureWidthPx = 1600, captureHeightPx = 720)
        val adapted = budget.apply(landscape, true)
        assertEquals(1200, adapted.captureWidthPx)
        assertEquals(540, adapted.captureHeightPx)
        assertEquals(1600, adapted.displayWidthPx)
        budget.observe(sender(0), null, 0.0, false, 30, 3000)
        assertEquals(540, budget.apply(profile, false).captureWidthPx)
        budget.observe(sender(0), null, 0.0, false, 30, 9000)
        assertEquals(profile, budget.apply(profile, false))
        val tiny = profile.copy(captureWidthPx = 320, captureHeightPx = 712)
        assertEquals(tiny, budget.apply(tiny, true))
    }

    @Test fun severeNetworkFailureCanBypassMotionCadenceFloor() {
        val cadence = VideoCadenceGovernor(60, 30)
        assertTrue(cadence.observe(sender().copy(packetLossRatio = 0.20), null, 30, 1000, minimumFps = 30))
        assertTrue(cadence.cap < 30)
    }

    @Test fun moderateReceiverJitterCannotPinCadenceWhilePixelBudgetIsUnchanged() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(30, 30)
        val delayed = receiver().copy(jitterMs = 95.0)
        repeat(2) { index ->
            val now = (index + 1) * 1000L
            budget.observe(sender(), delayed, 30.0, true, 30, now)
            cadence.observe(sender(), delayed, 30, now, budget.cadenceFloor(profile, true, now))
        }
        // This delay is below the pixel governor threshold but above cadence's
        // freshness budget. The old permanent 30-FPS floor blocked all relief.
        assertEquals(720, budget.shortEdge)
        assertEquals(24, cadence.cap)
    }

    @Test fun thirtyFpsSessionRecoversWithoutProbingFortyFiveOrSixty() {
        val cadence = VideoCadenceGovernor(30, 30)
        assertTrue(cadence.observe(sender(6, 60.0, 200.0), null, 30, 1000))
        assertTrue(cadence.cap < 30)
        repeat(40) { index ->
            cadence.observe(sender(), receiver(), cadence.cap, 4000L + index * 1000)
            assertTrue(cadence.cap <= 30)
        }
        assertEquals(30, cadence.cap)
    }

    @Test fun trulyQuietProducerDoesNotReduceCadenceForStaleTransportStats() {
        val cadence = VideoCadenceGovernor(30, 30)
        val still = sender(fps = 1).copy(
            roundTripTimeMs = 1_000,
            packetLossRatio = 0.20,
            qualityLimitationReason = "bandwidth"
        )

        assertFalse(
            cadence.observe(
                outbound = still,
                receiver = null,
                requestedFps = 30,
                nowMs = 1_000,
                producerFps = 0.0
            )
        )
        assertEquals(30, cadence.cap)

        // An active producer still receives the original loss protection.
        assertTrue(
            cadence.observe(
                outbound = sender(30).copy(
                    roundTripTimeMs = 1_000,
                    packetLossRatio = 0.20
                ),
                receiver = null,
                requestedFps = 30,
                nowMs = 2_000,
                producerFps = 30.0
            )
        )
        assertEquals(24, cadence.cap)
    }

    @Test fun newMotionRecoversOneRungAfterProvenQuietHealthyPath() {
        val cadence = VideoCadenceGovernor(30, 30)
        val congested = sender(30).copy(packetLossRatio = 0.20)
        assertTrue(cadence.observe(congested, null, 30, 1_000))
        assertEquals(24, cadence.cap)

        val quiet = sender(1)
        assertFalse(cadence.tryProbeAfterQuiet(quiet, 0.0, 4_000, 4_500))
        assertEquals(24, cadence.cap)

        assertTrue(cadence.tryProbeAfterQuiet(quiet, 0.0, 10_500, 11_000))
        assertEquals(30, cadence.cap)
        assertFalse(cadence.tryProbeAfterQuiet(quiet, 0.0, 10_500, 11_100))
    }

    @Test fun idleProbeRejectsStaleOrUnprovenPathAndDoesNotForceRecovery() {
        val cadence = VideoCadenceGovernor(30, 30)
        assertTrue(
            cadence.observe(
                sender(30).copy(packetLossRatio = 0.20),
                null,
                30,
                1_000
            )
        )
        val quiet = sender(1)
        assertFalse(cadence.tryProbeAfterQuiet(quiet, 0.0, 5_000, 11_000))
        assertFalse(cadence.tryProbeAfterQuiet(quiet, 30.0, 10_500, 11_000))
        assertFalse(cadence.tryProbeAfterQuiet(
            quiet.copy(roundTripTimeMs = 800),
            0.0,
            10_500,
            11_000
        ))
        assertFalse(cadence.tryProbeAfterQuiet(
            quiet.copy(qualityLimitationReason = "cpu"),
            0.0,
            10_500,
            11_000
        ))
        assertFalse(cadence.tryProbeAfterQuiet(
            quiet.copy(recent = quiet.recent!!.copy(processingMs = 90.0)),
            0.0,
            10_500,
            11_000
        ))
        assertEquals(24, cadence.cap)
    }

}
