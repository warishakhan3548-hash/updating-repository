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

    private fun nativeWarmBudget(): MotionVideoBudget = MotionVideoBudget().apply {
        assertTrue(primeForMotion(profile.copy(maxVideoBitrateBps = 10_000_000), 0L,
            sender(fps = 1).copy(availableOutgoingBitrateBps = 4_500_000.0)))
        assertEquals(720, shortEdge)
    }

    @Test fun retainedGlassHitchCannotBecomeASecondResolutionPressureVote() {
        val budget = nativeWarmBudget()
        val hitch = receiver(presented = 10).copy(maxRenderGapMs = 160)
        assertFalse(budget.observe(sender(), hitch, 30.0, true, 30, 4_000L))
        assertFalse(budget.observe(sender(), hitch.copy(presentationSampleFresh = false), 30.0, true, 30, 4_500L))
        assertEquals(720, budget.shortEdge)
    }

    @Test fun distinctGlassHitchesStillReceiveResolutionRelief() {
        val budget = nativeWarmBudget()
        val hitch = receiver(presented = 10).copy(maxRenderGapMs = 160)
        assertFalse(budget.observe(sender(), hitch, 30.0, true, 30, 4_000L))
        assertTrue(budget.observe(sender(), hitch, 30.0, true, 30, 4_500L))
        assertEquals(540, budget.shortEdge)
    }

    @Test fun heldGlassTelemetryDoesNotSuppressIndependentEncoderPressure() {
        val budget = nativeWarmBudget()
        val held = receiver().copy(presentationSampleFresh = false)
        val slowEncoder = sender(fps = 20, encode = 35.0)
        assertFalse(budget.observe(slowEncoder, held, 30.0, true, 30, 4_000L))
        assertTrue(budget.observe(slowEncoder, held, 30.0, true, 30, 4_500L))
        assertEquals(540, budget.shortEdge)
    }

    @Test fun shortStatsProbeCannotEraseRealEncoderPressureEvidence() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val overloaded = sender(fps = 20, encode = 35.0, queue = 5.0)

        // The first completed one-second interval is genuine encoder pressure,
        // but hysteresis deliberately requires another completed observation.
        assertFalse(budget.observe(overloaded, null, 30.0, true, 30, 4_000L, true))
        assertEquals(360, budget.shortEdge)

        // A 120 ms reconfiguration kick has no complete recent window. It
        // must not turn one measured pressure window into zero.
        assertFalse(
            budget.observe(overloaded.copy(recent = null), null, 30.0, true, 30, 4_120L, true)
        )
        assertTrue(budget.observe(overloaded, null, 30.0, true, 30, 5_000L, true))
        assertEquals(240, budget.shortEdge)
    }

    @Test fun staleEncoderPressureExpiresAfterAnUnmeasuredGap() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val overloaded = sender(fps = 20, encode = 35.0, queue = 5.0)

        assertFalse(budget.observe(overloaded, null, 30.0, true, 30, 4_000L, true))
        // Multiple short or missing probes must not become fabricated samples.
        assertFalse(
            budget.observe(overloaded.copy(recent = null), null, 30.0, true, 30, 10_400L, true)
        )
        assertFalse(budget.observe(overloaded, null, 30.0, true, 30, 10_500L, true))
        assertEquals(360, budget.shortEdge)

        // New consecutive full windows can establish pressure again.
        assertTrue(budget.observe(overloaded, null, 30.0, true, 30, 11_500L, true))
        assertEquals(240, budget.shortEdge)
    }

    @Test fun replacementCodecOrStreamCannotInheritOldPressure() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val previousStream = sender(fps = 20, encode = 35.0, queue = 5.0)
            .copy(streamId = "video-old")

        assertFalse(budget.observe(previousStream, null, 30.0, true, 30, 4_000L, true))
        val replacement = previousStream.copy(streamId = "video-new", codec = "video/H264")
        // New stream/codec starts with a short native probe; old pressure must
        // be forgotten before the first new-stream complete sender window.
        assertFalse(
            budget.observe(replacement.copy(recent = null), null, 30.0, true, 30, 4_120L, true)
        )
        assertFalse(budget.observe(replacement, null, 30.0, true, 30, 5_000L, true))
        assertEquals(360, budget.shortEdge)
        assertTrue(budget.observe(replacement, null, 30.0, true, 30, 6_000L, true))
        assertEquals(240, budget.shortEdge)
    }

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

    @Test fun provenQuietHardwareHeadroomKeepsNativeResolutionAtTouchDown() {
        val budget = MotionVideoBudget()
        val capableProfile =
            profile.copy(maxVideoBitrateBps = 10_000_000)
        val quietHealthyPath =
            sender(
                fps = 1,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                roundTripTimeMs = 80,
                packetLossRatio = 0.005,
                availableOutgoingBitrateBps = 4_500_000.0
            )

        assertTrue(
            budget.primeForMotion(
                profile = capableProfile,
                nowMs = 1_000L,
                warmStartEvidence = quietHealthyPath
            )
        )
        assertEquals(720, budget.shortEdge)
        assertEquals(capableProfile, budget.apply(capableProfile, true))
    }

    @Test fun provenModerateHeadroomUsesOneSafeMidRungInsteadOfBlindThreeSixty() {
        val budget = MotionVideoBudget()
        val quietHealthyPath =
            sender(
                fps = 1,
                encode = 5.0,
                queue = 5.0,
                implementation = "OMX.qcom.video.encoder.avc"
            ).copy(
                roundTripTimeMs = 90,
                packetLossRatio = 0.005,
                availableOutgoingBitrateBps = 2_400_000.0
            )

        assertTrue(
            budget.primeForMotion(
                profile = profile,
                nowMs = 1_000L,
                warmStartEvidence = quietHealthyPath
            )
        )
        assertEquals(540, budget.shortEdge)
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun warmStartBudgetsTheCadenceActuallyRequested() {
        val capableProfile =
            profile.copy(maxVideoBitrateBps = 10_000_000)
        val quietHealthyPath =
            sender(
                fps = 1,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                roundTripTimeMs = 80,
                packetLossRatio = 0.005,
                availableOutgoingBitrateBps = 4_500_000.0
            )

        val thirty = MotionVideoBudget()
        assertTrue(
            thirty.primeForMotion(
                profile = capableProfile,
                nowMs = 1_000L,
                warmStartEvidence = quietHealthyPath,
                targetFps = 30
            )
        )
        assertEquals(720, thirty.shortEdge)

        val sixty = MotionVideoBudget()
        assertTrue(
            sixty.primeForMotion(
                profile = capableProfile,
                nowMs = 1_000L,
                warmStartEvidence = quietHealthyPath,
                targetFps = 60
            )
        )
        // 4.5 Mbps has headroom for 540@60, not the native 720@60 budget.
        assertEquals(540, sixty.shortEdge)
    }

    @Test fun softwareOrUnprovenWarmStartEvidenceKeepsConservativeSafetyRung() {
        val software = MotionVideoBudget()
        val softwareEvidence =
            sender(
                fps = 1,
                encode = 4.0,
                queue = 1.0,
                implementation = "libvpx"
            ).copy(
                roundTripTimeMs = 40,
                packetLossRatio = 0.0,
                availableOutgoingBitrateBps = 10_000_000.0
            )
        assertTrue(
            software.primeForMotion(
                profile = profile.copy(maxVideoBitrateBps = 10_000_000),
                nowMs = 1_000L,
                warmStartEvidence = softwareEvidence
            )
        )
        assertEquals(360, software.shortEdge)

        val missingBandwidth = MotionVideoBudget()
        assertTrue(
            missingBandwidth.primeForMotion(
                profile = profile,
                nowMs = 1_000L,
                warmStartEvidence = sender(fps = 1)
            )
        )
        assertEquals(360, missingBandwidth.shortEdge)
    }

    @Test fun activeInteractionCanHoldResolutionRecoveryUntilGestureSettles() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        val healthy =
            sender().copy(
                availableOutgoingBitrateBps = 2_400_000.0
            )

        repeat(20) { index ->
            budget.observe(
                outbound = healthy,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 20_000L + index * 1_000L,
                interactionActive = true,
                allowResolutionRecovery = false
            )
        }
        assertEquals(360, budget.shortEdge)

        repeat(12) { index ->
            budget.observe(
                outbound = healthy,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 50_000L + index * 1_000L,
                interactionActive = false,
                allowResolutionRecovery = true
            )
        }
        assertEquals(540, budget.shortEdge)
    }

    @Test fun recordedSoftwareCollapseGetsPixelAndUrgentCadenceRelief() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(60, 30)
        val collapse = sender(6, 53.0, 585.0, "libvpx")
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 1000))
        assertEquals(540, budget.shortEdge)
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
        assertTrue(cadence.observe(collapse, null, 30, 1000, budget.cadenceFloor(profile, true, 1000)))
        assertEquals(24, cadence.cap)
        budget.observe(collapse, null, 30.0, true, 30, 4000)
        assertEquals(360, budget.shortEdge)
        assertEquals(800, budget.apply(profile, true).captureHeightPx)
        assertTrue(cadence.observe(collapse, null, 30, 4000, budget.cadenceFloor(profile, true, 4000)))
        // Pixel relief continues while the severe stale queue drains.
        budget.observe(collapse, null, 30.0, true, 30, 7000)
        assertEquals(240, budget.shortEdge)
        assertTrue(cadence.observe(collapse, null, 30, 7000, budget.cadenceFloor(profile, true, 7000)))
        // The emergency cadence floor has now been reached.
        assertFalse(cadence.observe(collapse, null, 30, 10000, budget.cadenceFloor(profile, true, 10000)))
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


    @Test fun sustainedResidenceGrowthPreemptsVisibleQueueAtSixtyFps() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        /*
         * Queue and jitter remain below the existing absolute alarms. The new
         * signal reacts only after two consecutive rising residence intervals.
         */
        listOf(15.0, 30.0, 45.0).forEachIndexed { index, queue ->
            val changed =
                budget.observe(
                    outbound = sender(
                        fps = 60,
                        encode = 5.0,
                        queue = queue,
                        implementation = "c2.qti.avc.encoder"
                    ),
                    receiver = receiver(fps = 60, decode = 5.0, presented = 60)
                        .copy(jitterMs = 10.0),
                    sourceFps = 60.0,
                    motionActive = true,
                    targetFps = 60,
                    nowMs = (index + 1) * 1_000L,
                    interactionActive = true
                )
            if (index < 2) assertFalse(changed) else assertTrue(changed)
        }

        assertEquals(240, budget.shortEdge)
    }

    @Test fun oneResidenceSpikeDoesNotTriggerPredictivePixelRelief() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))

        listOf(15.0, 50.0, 20.0).forEachIndexed { index, queue ->
            assertFalse(
                budget.observe(
                    outbound = sender(
                        fps = 60,
                        encode = 5.0,
                        queue = queue,
                        implementation = "c2.qti.avc.encoder"
                    ),
                    receiver = receiver(fps = 60, decode = 5.0, presented = 60)
                        .copy(jitterMs = 10.0),
                    sourceFps = 60.0,
                    motionActive = true,
                    targetFps = 60,
                    nowMs = (index + 1) * 1_000L,
                    interactionActive = true
                )
            )
        }

        assertEquals(360, budget.shortEdge)
    }

    @Test fun thirtyFpsGetsWiderResidenceGrowthBudgetThanSixtyFps() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))

        listOf(15.0, 30.0, 45.0, 60.0).forEachIndexed { index, queue ->
            assertFalse(
                budget.observe(
                    outbound = sender(
                        fps = 30,
                        encode = 5.0,
                        queue = queue,
                        implementation = "c2.qti.avc.encoder"
                    ),
                    receiver = receiver(fps = 30, decode = 5.0, presented = 30)
                        .copy(jitterMs = 10.0),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = (index + 1) * 1_000L,
                    interactionActive = true
                )
            )
        }

        assertEquals(360, budget.shortEdge)
    }

    @Test fun staticScreenCannotAccumulateResidenceGrowthPressure() {
        val budget = MotionVideoBudget()

        // The first motion-active observation legitimately flips the existing
        // resolution-hold state even though no pixel rung changes. Establish
        // that state before asserting that a static producer cannot build the
        // new predictive pressure signal.
        assertTrue(
            budget.observe(
                outbound = sender(
                    fps = 1,
                    encode = 5.0,
                    queue = 5.0,
                    implementation = "c2.qti.avc.encoder"
                ),
                receiver = null,
                sourceFps = 1.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 500L,
                interactionActive = false
            )
        )
        assertEquals(720, budget.shortEdge)

        listOf(15.0, 35.0, 55.0, 70.0).forEachIndexed { index, queue ->
            assertFalse(
                budget.observe(
                    outbound = sender(
                        fps = 1,
                        encode = 5.0,
                        queue = queue,
                        implementation = "c2.qti.avc.encoder"
                    ),
                    receiver = null,
                    sourceFps = 1.0,
                    motionActive = true,
                    targetFps = 60,
                    nowMs = (index + 1) * 1_000L,
                    interactionActive = false
                )
            )
        }

        assertEquals(720, budget.shortEdge)
    }

    @Test fun receiverTargetPlayoutDebtRelievesSixtyFpsBeforeVisibleStall() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        /*
         * Actual jitter is still tiny and presentation is perfect, but WebRTC
         * has already raised its target playout residence. At 60 Hz the serial
         * encode + sender queue + playout + decode debt now consumes more than
         * ~2.5 frame periods. Two clean samples should spend pixels before that
         * target delay turns into a visible hitch.
         */
        val sixtySender =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 10.0,
                implementation = "c2.qti.avc.encoder"
            )
        val sixtyReceiver =
            receiver(
                fps = 60,
                decode = 5.0,
                presented = 60
            ).copy(
                jitterMs = 5.0,
                jitterTargetMs = 35.0
            )

        assertFalse(
            budget.observe(
                outbound = sixtySender,
                receiver = sixtyReceiver,
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = sixtySender,
                receiver = sixtyReceiver,
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)

        /*
         * The exact same 55 ms serial residence fits comfortably inside the
         * wider 30 Hz deadline budget. Do not sacrifice clarity there.
         */
        val thirty = MotionVideoBudget()
        assertTrue(thirty.primeForMotion(profile, 0L))
        val thirtySender =
            sender(
                fps = 30,
                encode = 5.0,
                queue = 10.0,
                implementation = "c2.qti.avc.encoder"
            )
        val thirtyReceiver =
            receiver(
                fps = 30,
                decode = 5.0,
                presented = 30
            ).copy(
                jitterMs = 5.0,
                jitterTargetMs = 35.0
            )

        repeat(3) { index ->
            assertFalse(
                thirty.observe(
                    outbound = thirtySender,
                    receiver = thirtyReceiver,
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 1_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }
        assertEquals(360, thirty.shortEdge)
    }

    @Test fun provenSixtyFpsCodecPressureGetsBoundedFastPixelRelief() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        /*
         * 20 ms encode residence is fine at 30 Hz but misses a 60 Hz frame
         * budget. Two consecutive high-cadence pressure windows should spend
         * pixels before the legacy 3-second settle can build visible staleness.
         */
        val stressed = sender(
            fps = 42,
            encode = 20.0,
            queue = 5.0,
            implementation = "c2.qti.avc.encoder"
        )

        assertFalse(
            budget.observe(
                outbound = stressed,
                receiver = receiver(fps = 42, decode = 5.0, presented = 42),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = stressed,
                receiver = receiver(fps = 42, decode = 5.0, presented = 42),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)

        // The same encoder timing is not pressure for a real 30 fps target.
        val thirtyFps = MotionVideoBudget()
        assertTrue(thirtyFps.primeForMotion(profile, 0L))
        repeat(3) { index ->
            assertFalse(
                thirtyFps.observe(
                    outbound = stressed,
                    receiver = receiver(fps = 30, decode = 5.0, presented = 30),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 1_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }
        assertEquals(360, thirtyFps.shortEdge)
    }

    @Test fun sixtyFpsTargetUsesSixtyFpsFrameBudgetForPixelRelief() {
        val budget = MotionVideoBudget()

        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        /*
         * A hardware path delivering 30 fps with ~16 ms encode residence is
         * acceptable for a 30 fps goal, but it is temporal under-delivery for
         * a proven 60 fps target. The pixel governor must see the 16.7 ms frame
         * budget and spend resolution before cadence is sacrificed.
         */
        val halfCadence = sender(
            fps = 30,
            encode = 16.0,
            queue = 5.0,
            implementation = "c2.qti.avc.encoder"
        )

        assertFalse(
            budget.observe(
                outbound = halfCadence,
                receiver = receiver(fps = 30, decode = 5.0, presented = 30),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = halfCadence,
                receiver = receiver(fps = 30, decode = 5.0, presented = 30),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 3_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)
        assertEquals(500_000, budget.bitrateCeiling(profile, true))
    }

    @Test fun bandwidthEstimateSpendsPixelsBeforeQueuesBuild() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        val lowHeadroom =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                availableOutgoingBitrateBps = 700_000.0
            )

        // Encoder, queue and receiver are still healthy. The WebRTC congestion
        // controller already knows that the path lacks headroom for this rung,
        // so the second stable BWE window preempts future queue growth.
        assertFalse(
            budget.observe(
                lowHeadroom,
                receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                lowHeadroom,
                receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)
        assertEquals(500_000, budget.bitrateCeiling(profile, true))
    }

    @Test fun sixtyFpsBandwidthPredictionUsesPixelRateNotThirtyFpsRung() {
        val sixty = MotionVideoBudget()
        assertTrue(sixty.primeForMotion(profile, 0L))
        assertEquals(
            1_800_000,
            sixty.bitrateCeiling(profile, true, targetFps = 60)
        )
        val path =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                availableOutgoingBitrateBps = 1_200_000.0
            )

        assertFalse(
            sixty.observe(
                path,
                receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            sixty.observe(
                path,
                receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(240, sixty.shortEdge)
        assertEquals(
            1_000_000,
            sixty.bitrateCeiling(profile, true, targetFps = 60)
        )

        // The same estimate comfortably fits 360-short-edge at 30 fps. A BWE
        // stat by itself must not trigger relief when the requested pixel-rate
        // really has headroom.
        val thirty = MotionVideoBudget()
        assertTrue(thirty.primeForMotion(profile, 0L))
        assertEquals(
            900_000,
            thirty.bitrateCeiling(profile, true, targetFps = 30)
        )
        val thirtyPath =
            path.copy(
                recent =
                    path.recent!!.copy(
                        frames = 30,
                        processingMs = 5.0
                    )
            )
        repeat(3) { index ->
            assertFalse(
                thirty.observe(
                    thirtyPath,
                    receiver(fps = 30, decode = 5.0, presented = 30),
                    sourceFps = 30.0,
                    motionActive = true,
                    targetFps = 30,
                    nowMs = 1_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }
        assertEquals(360, thirty.shortEdge)
    }

    @Test fun lowBandwidthEstimateCannotBlurAStaticScreen() {
        val budget = MotionVideoBudget()
        val lowBwe =
            sender(fps = 1).copy(
                availableOutgoingBitrateBps = 250_000.0
            )

        repeat(6) { index ->
            budget.observe(
                outbound = lowBwe,
                receiver = null,
                sourceFps = 1.0,
                motionActive = true,
                targetFps = 30,
                nowMs = (index + 1) * 1_000L,
                interactionActive = false
            )
        }

        assertEquals(720, budget.shortEdge)
    }

    @Test fun resolutionRecoveryRequiresBandwidthForTheNextRung() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)

        val onlyEnoughForCurrentRung =
            sender().copy(
                availableOutgoingBitrateBps = 1_050_000.0
            )
        repeat(20) { index ->
            budget.observe(
                outbound = onlyEnoughForCurrentRung,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 20_000L + index * 1_000L
            )
        }
        assertEquals(360, budget.shortEdge)

        val enoughForNextRung =
            sender().copy(
                availableOutgoingBitrateBps = 2_400_000.0
            )
        repeat(12) { index ->
            budget.observe(
                outbound = enoughForNextRung,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 50_000L + index * 1_000L
            )
        }
        assertEquals(540, budget.shortEdge)
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
        assertTrue(
            cadence.observe(
                recorded,
                null,
                30,
                1_000L,
                budget.cadenceFloor(profile, true, 1_000L),
                producerFps = 14.0
            )
        )
        assertEquals(24, cadence.cap)

        val worse = recorded.copy(
            recent = recorded.recent!!.copy(frames = 2, sendQueueMs = 1_669.0)
        )
        assertTrue(budget.observe(worse, null, 31.0, true, 30, 2_000L))
        assertEquals(180, budget.shortEdge)
        assertEquals(350_000, budget.bitrateCeiling(profile, true))
        assertTrue(
            cadence.observe(
                worse,
                null,
                24,
                2_000L,
                budget.cadenceFloor(profile, true, 2_000L),
                producerFps = 31.0
            )
        )
        assertEquals(20, cadence.cap)

        // Once the smallest pixel rung has had time to drain the old queue,
        // cadence remains the final safety valve if the link is still bad.
        assertTrue(
            cadence.observe(
                worse,
                null,
                24,
                5_100L,
                budget.cadenceFloor(profile, true, 5_100L),
                producerFps = 31.0
            )
        )
        assertTrue(cadence.cap < 30)
    }

    @Test fun activeInteractionKeepsSparseProducerFreshInsteadOfCollapsingCadence() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(30, 24)
        val recorded = sender(
            fps = 6,
            encode = 16.0,
            queue = 120.0,
            implementation = "c2.mtk.avc.encoder"
        ).copy(
            qualityLimitationReason = "bandwidth",
            roundTripTimeMs = 160
        )

        // Mirrors the uploaded run: the producer reports only ~3 fps, but a
        // real remote gesture is actively changing the UI. Interaction is
        // authoritative motion evidence and must not be vetoed by sourceFps.
        assertTrue(budget.primeForMotion(profile, 0L))
        assertTrue(
            budget.observe(
                outbound = recorded,
                receiver = null,
                sourceFps = 3.0,
                motionActive = true,
                targetFps = 24,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertEquals(240, budget.shortEdge)
        assertEquals(500_000, budget.bitrateCeiling(profile, true))

        val floor = budget.cadenceFloor(
            profile = profile,
            motionActive = true,
            nowMs = 1_000L,
            interactionActive = true
        )
        assertEquals(24, floor)
        assertFalse(
            cadence.observe(
                outbound = recorded,
                receiver = null,
                requestedFps = 24,
                nowMs = 1_000L,
                minimumFps = floor,
                producerFps = 3.0
            )
        )
        assertEquals(24, cadence.cap)

        // A second bad window spends the final pixel rung, not temporal
        // cadence, while the user is still interacting.
        assertTrue(
            budget.observe(
                outbound = recorded,
                receiver = null,
                sourceFps = 3.0,
                motionActive = true,
                targetFps = 24,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(180, budget.shortEdge)
        assertEquals(350_000, budget.bitrateCeiling(profile, true))
        assertFalse(
            cadence.observe(
                outbound = recorded,
                receiver = null,
                requestedFps = 24,
                nowMs = 2_000L,
                minimumFps = budget.cadenceFloor(
                    profile,
                    true,
                    2_000L,
                    interactionActive = true
                ),
                producerFps = 3.0
            )
        )
        assertEquals(24, cadence.cap)
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
        assertEquals(360, budget.shortEdge)
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
