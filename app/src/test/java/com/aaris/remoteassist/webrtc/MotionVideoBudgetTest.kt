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

    @Test fun isolatedHugeFrameWithoutRepairDoesNotSpendPixels() {
        val budget = nativeWarmBudget()
        val cleanHuge =
            sender().let { snapshot ->
                snapshot.copy(
                    recent =
                        snapshot.recent!!.copy(
                            hugeFrames = 1,
                            retransmitRatio = 0.01,
                            nacks = 0,
                            plis = 0,
                            firs = 0
                        )
                )
            }

        assertFalse(
            budget.observe(
                cleanHuge,
                receiver(),
                30.0,
                true,
                30,
                4_000L,
                interactionActive = true
            )
        )
        assertFalse(
            budget.observe(
                cleanHuge,
                receiver(),
                30.0,
                true,
                30,
                5_000L,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test fun repairedHugeFramesSpendPixelsBeforeInteractiveCadence() {
        val budget = nativeWarmBudget()
        val repairedBurst =
            sender().let { snapshot ->
                snapshot.copy(
                    recent =
                        snapshot.recent!!.copy(
                            hugeFrames = 1,
                            retransmitRatio = 0.10,
                            nacks = 3,
                            plis = 0,
                            firs = 0
                        )
                )
            }

        assertFalse(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                4_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                5_000L,
                interactionActive = true
            )
        )
        assertEquals(540, budget.shortEdge)
        assertEquals(
            30,
            budget.cadenceFloor(
                profile,
                motionActive = true,
                nowMs = 5_000L,
                interactionActive = true
            )
        )

        // The resize can itself generate a key/huge frame. Burst-only evidence
        // must not immediately cascade into another codec reconfiguration.
        assertFalse(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                5_500L,
                interactionActive = true
            )
        )
        assertFalse(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                6_000L,
                interactionActive = true
            )
        )
        assertEquals(540, budget.shortEdge)

        // Persisting repair pressure after the spatial guard is real evidence.
        assertFalse(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                8_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                repairedBurst,
                receiver(),
                30.0,
                true,
                30,
                9_000L,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)
    }

    @Test fun nativeSourceAboveBudgetCeilingIsStableAcrossUnprovenTouchDownAndFingerUp() {
        val nativeProfile =
            CaptureProfile(
                1080,
                2400,
                1080,
                2400,
                45,
                10_000_000,
                CaptureTier.HIGH,
                60
            )
        val budget = MotionVideoBudget()

        assertTrue(budget.primeForMotion(nativeProfile, 1_000L))
        assertEquals(360, budget.shortEdge)

        /*
         * shortEdge is already a conservative control budget, but the running
         * native source must remain untouched until a measured moving window
         * validates a resize. This is the case the old 720-wide fixture could
         * not expose.
         */
        assertEquals(nativeProfile, budget.apply(nativeProfile, true))
        // The speculative 360 control budget must not hard-cut rate control
        // while the encoder is still consuming native 1080x2400 frames.
        assertEquals(
            10_000_000,
            budget.bitrateCeiling(nativeProfile, true, targetFps = 60)
        )

        assertTrue(
            budget.observe(
                outbound = sender().copy(recent = null),
                receiver = null,
                sourceFps = null,
                motionActive = false,
                targetFps = 60,
                nowMs = 1_500L
            )
        )
        assertEquals(720, budget.shortEdge)

        // Cancelling an unproven warm start must not merely move the surprise
        // 1080 -> 720 resize from finger-down to finger-up.
        assertEquals(nativeProfile, budget.apply(nativeProfile, false))
    }

    @Test fun nativeSourceResizeCommitsOnlyAfterMeasuredMotionPressure() {
        val nativeProfile =
            CaptureProfile(
                1080,
                2400,
                1080,
                2400,
                45,
                10_000_000,
                CaptureTier.HIGH,
                60
            )
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(nativeProfile, 1_000L))
        val stressed =
            sender(
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
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        assertEquals(nativeProfile, budget.apply(nativeProfile, true))

        assertTrue(
            budget.observe(
                outbound = stressed,
                receiver = receiver(fps = 42, decode = 5.0, presented = 42),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 3_000L,
                interactionActive = true
            )
        )
        val relieved = budget.apply(nativeProfile, true)
        assertEquals(360, relieved.captureWidthPx)
        assertEquals(800, relieved.captureHeightPx)
        // Once pressure has committed the source rung, rate control may tighten
        // in the same operating point instead of leading geometry speculatively.
        assertEquals(
            1_800_000,
            budget.bitrateCeiling(nativeProfile, true, targetFps = 60)
        )
    }

    @Test fun newMotionWarmStartKeepsBitrateAlignedWithCommittedSourceGeometry() {
        val budget = MotionVideoBudget()

        assertTrue(budget.primeForMotion(profile, 1_000L))
        assertEquals(360, budget.shortEdge)
        // The predictive rung is control-plane only until a complete moving
        // window proves pressure. Touch-down keeps both the running source
        // shape and its matching sender ceiling; GCC still owns the actual rate.
        assertEquals(profile, budget.apply(profile, true))
        assertEquals(30, budget.cadenceFloor(profile, true, 1_000L))
        assertEquals(3_000_000, budget.bitrateCeiling(profile, true))

        // Repeated motion pulses refresh the hold but never keep knocking a
        // stream down after its first warm-start decision.
        assertFalse(budget.primeForMotion(profile, 1_500L))
        assertEquals(360, budget.shortEdge)
        assertEquals(profile, budget.apply(profile, true))
        assertEquals(3_000_000, budget.bitrateCeiling(profile, true))
    }

    @Test fun measuredMotionPressureCommitsOneDirectPixelReliefStep() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(profile, budget.apply(profile, true))

        val overloaded = sender(fps = 20, encode = 35.0, queue = 5.0)
        assertFalse(
            budget.observe(
                outbound = overloaded,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertEquals(profile, budget.apply(profile, true))

        assertTrue(
            budget.observe(
                outbound = overloaded,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 2_000L,
                interactionActive = true
            )
        )
        // Two measured pressure windows may commit the speculative warm-start,
        // but ordinary pressure is clamped to the 360 readability floor.
        assertEquals(360, budget.apply(profile, true).captureWidthPx)
        assertEquals(800, budget.apply(profile, true).captureHeightPx)
    }

    @Test fun unvalidatedWarmStartNeverLeaksIntoIdleGeometry() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(profile, budget.apply(profile, true))

        assertTrue(
            budget.observe(
                outbound = sender().copy(recent = null),
                receiver = null,
                sourceFps = null,
                motionActive = false,
                targetFps = 30,
                nowMs = 500L
            )
        )
        assertEquals(720, budget.shortEdge)
        assertEquals(profile, budget.apply(profile, false))
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
        // Moderate quiet-path evidence may cap the initial send budget, but
        // must not resize the running source on the controller's first input.
        assertEquals(profile, budget.apply(profile, true))
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

    @Test fun activeInteractionCanHoldCommittedResolutionRecoveryUntilGestureSettles() {
        val budget = MotionVideoBudget()
        val collapse = sender(6, 53.0, 585.0, "libvpx")

        // Create a REAL committed 360px operating point. A speculative
        // touch-down budget is not a downgrade and must never enter recovery.
        assertTrue(
            budget.observe(
                outbound = collapse,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 1_000L
            )
        )
        assertEquals(540, budget.shortEdge)
        assertTrue(
            budget.observe(
                outbound = collapse,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 4_000L
            )
        )
        assertEquals(360, budget.shortEdge)

        val healthy =
            sender().copy(
                availableOutgoingBitrateBps = 5_000_000.0
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

        // After the gesture settles, the existing fast-recovery contract is
        // allowed again: three clean end-to-end windows restore 540px, then
        // five more clean windows plus the native settle restore 720px.
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
        assertEquals(720, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)
        val small = budget.apply(profile, true)
        assertEquals(360, small.captureWidthPx)
        assertEquals(800, small.captureHeightPx)
        assertEquals(720, small.displayWidthPx)
        assertEquals(1600, small.displayHeightPx)
        // Clean delivery may recover above the clarity floor; codec pressure itself
        // must never have pushed the primary stream below 360.
        repeat(12) { budget.observe(sender(), receiver(), 30.0, true, 30, 20_000L + it * 1_000) }
        assertTrue(budget.shortEdge >= 360)
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

        assertEquals(360, budget.shortEdge)
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
        assertEquals(360, budget.shortEdge)

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
        assertEquals(360, budget.shortEdge)

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
        assertEquals(360, budget.shortEdge)
        assertEquals(900_000, budget.bitrateCeiling(profile, true))
    }

    @Test fun mildBandwidthDipCanPreservePixelsBySpendingHighCadenceFirst() {
        val budget = nativeWarmBudget()
        val mildDip =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                availableOutgoingBitrateBps = 4_200_000.0
            )

        /*
         * Native 720-short-edge motion is budgeted at ~3.2 Mbps @30 fps and
         * ~6.4 Mbps @60 fps. 4.2 Mbps cannot sustain the latter with headroom,
         * but it can keep the same pixels around the 30-36 fps region.
         */
        assertEquals(
            35,
            budget.clarityPreservingCadenceCeiling(
                profile = profile.copy(maxVideoBitrateBps = 10_000_000),
                outbound = mildDip,
                receiver = receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test fun severeBandwidthConstraintStillFallsThroughToSpatialRelief() {
        val budget = nativeWarmBudget()
        val constrained =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                availableOutgoingBitrateBps = 2_800_000.0
            )

        // 2.8 Mbps cannot protect native 720 pixels even at the 30 fps floor,
        // so cadence-only relief must not block the existing spatial ladder.
        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile.copy(maxVideoBitrateBps = 10_000_000),
                outbound = constrained,
                receiver = receiver(fps = 60, decode = 5.0, presented = 60),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
    }

    @Test fun codecOrQueuePressureNeverHidesBehindTheClarityGuard() {
        val budget = nativeWarmBudget()
        val overloaded =
            sender(
                fps = 45,
                encode = 20.0,
                queue = 95.0,
                implementation = "c2.qti.avc.encoder"
            ).copy(
                availableOutgoingBitrateBps = 4_200_000.0
            )

        assertNull(
            budget.clarityPreservingCadenceCeiling(
                profile = profile.copy(maxVideoBitrateBps = 10_000_000),
                outbound = overloaded,
                receiver = receiver(fps = 45, decode = 5.0, presented = 45),
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                interactionActive = true
            )
        )
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
        assertEquals(360, budget.shortEdge)
        assertEquals(900_000, budget.bitrateCeiling(profile, true))
    }

    @Test fun sixtyFpsBandwidthPredictionUsesPixelRateNotThirtyFpsRung() {
        val sixty = MotionVideoBudget()
        assertTrue(sixty.primeForMotion(profile, 0L))
        // Prediction may use the speculative 360 rung, but the RTP ceiling
        // stays aligned with the still-committed 720-wide source.
        assertEquals(
            3_000_000,
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
        assertEquals(360, sixty.shortEdge)
        assertEquals(
            1_800_000,
            sixty.bitrateCeiling(profile, true, targetFps = 60)
        )

        // The same estimate comfortably fits 360-short-edge at 30 fps. A BWE
        // stat by itself must not trigger relief when the requested pixel-rate
        // really has headroom.
        val thirty = MotionVideoBudget()
        assertTrue(thirty.primeForMotion(profile, 0L))
        assertEquals(
            3_000_000,
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
        val collapse = sender(6, 53.0, 585.0, "libvpx")

        // Recovery is meaningful only after a spatial change was committed.
        budget.observe(collapse, null, 30.0, true, 30, 1_000L)
        budget.observe(collapse, null, 30.0, true, 30, 4_000L)
        assertEquals(360, budget.shortEdge)
        assertEquals(360, budget.apply(profile, true).captureWidthPx)

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
    @Test fun strongEndToEndHeadroomRecoversClarityWithoutTwelveSecondBlur() {
        val budget = MotionVideoBudget()
        val collapse = sender(6, 53.0, 585.0, "libvpx")

        // Commit an actual source/sender downshift to 360px.
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 1_000L))
        assertEquals(540, budget.shortEdge)
        assertTrue(budget.observe(collapse, null, 30.0, true, 30, 4_000L))
        assertEquals(360, budget.shortEdge)
        assertEquals(360, budget.apply(profile, true).captureWidthPx)

        val recovered =
            sender().copy(
                availableOutgoingBitrateBps = 5_000_000.0
            )

        // Three consecutive clean end-to-end windows restore readable 540px.
        repeat(2) { index ->
            budget.observe(
                outbound = recovered,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 5_000L + index * 1_000L
            )
        }
        assertEquals(360, budget.shortEdge)
        budget.observe(
            outbound = recovered,
            receiver = receiver(),
            sourceFps = 30.0,
            motionActive = true,
            targetFps = 30,
            nowMs = 7_000L
        )
        assertEquals(540, budget.shortEdge)

        // Native resolution is a more expensive probe: five fresh windows and
        // a five-second settle are required for the final 720px upshift.
        repeat(4) { index ->
            budget.observe(
                outbound = recovered,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 8_000L + index * 1_000L
            )
        }
        assertEquals(540, budget.shortEdge)
        budget.observe(
            outbound = recovered,
            receiver = receiver(),
            sourceFps = 30.0,
            motionActive = true,
            targetFps = 30,
            nowMs = 12_000L
        )
        assertEquals(720, budget.shortEdge)
    }

    @Test fun fastClarityRecoveryRequiresControllerGlassAndRealBweHeadroom() {
        val budget = MotionVideoBudget()
        val collapse = sender(6, 53.0, 585.0, "libvpx")
        budget.observe(collapse, null, 30.0, true, 30, 1_000L)
        budget.observe(collapse, null, 30.0, true, 30, 4_000L)
        assertEquals(360, budget.shortEdge)

        val strongSender =
            sender().copy(
                availableOutgoingBitrateBps = 5_000_000.0
            )

        // Sender-only health is insufficient. Fast recovery requires the
        // controller to prove decode + jitter + actual presentation health.
        repeat(5) { index ->
            budget.observe(
                outbound = strongSender,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 5_000L + index * 1_000L
            )
        }
        assertEquals(360, budget.shortEdge)

        val insufficientHeadroom =
            sender().copy(
                availableOutgoingBitrateBps = 2_200_000.0
            )
        repeat(5) { index ->
            budget.observe(
                outbound = insufficientHeadroom,
                receiver = receiver(),
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = 10_000L + index * 1_000L
            )
        }
        assertEquals(360, budget.shortEdge)
    }

    @Test fun networkDelayAloneCannotUseTheEmergencyCodecResolution() {
        val budget = MotionVideoBudget()
        repeat(20) { budget.observe(sender(queue = 160.0), receiver(), 30.0, true, 30, 1_000L + it * 1_000) }
        assertEquals(360, budget.shortEdge)
    }

    @Test fun recordedBandwidthQueueSpendsCadenceBeforeCrossingReadablePixels() {
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

        // The first severe moving-window sample may commit the speculative
        // warm-start resize, but it must stop at the readable 360 floor.
        assertTrue(budget.observe(recorded, null, 14.0, true, 30, 1_000L))
        assertEquals(360, budget.shortEdge)
        assertEquals(900_000, budget.bitrateCeiling(profile, true))
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
        // Once cadence is already at 24 fps, even corroborated severe
        // transport pressure must keep the readable 360px spatial floor.
        assertFalse(budget.observe(worse, null, 31.0, true, 24, 2_000L))
        assertEquals(360, budget.shortEdge)
        assertEquals(900_000, budget.bitrateCeiling(profile, true))
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

        // Continued severe pressure spends cadence, never readability pixels.
        assertFalse(budget.observe(worse, null, 31.0, true, 20, 3_000L))
        assertEquals(360, budget.shortEdge)
    }

    @Test fun activeInteractionUsesCadenceAfterReadablePixelFloor() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(30, 24)
        val recorded = sender(
            fps = 6,
            encode = 16.0,
            queue = 353.0,
            implementation = "c2.mtk.avc.encoder"
        ).copy(
            qualityLimitationReason = "bandwidth",
            roundTripTimeMs = 160
        )

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
        assertEquals(360, budget.shortEdge)
        assertEquals(900_000, budget.bitrateCeiling(profile, true))

        val floor = budget.cadenceFloor(
            profile = profile,
            motionActive = true,
            nowMs = 1_000L,
            interactionActive = true
        )
        assertEquals(30, floor)

        // 360 is terminal: a second bad window cannot spend another pixel rung.
        assertFalse(
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
        assertEquals(360, budget.shortEdge)

        // Once the pixel escape hatch is exhausted, temporal relief remains.
        assertTrue(
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
        assertEquals(20, cadence.cap)
    }

    @Test fun activeSourceStarvationMustNotTriggerBandwidthPixelCollapse() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val sourceStarved = sender(fps = 1, encode = 4.0, queue = 0.0).copy(
            qualityLimitationReason = "bandwidth",
            availableOutgoingBitrateBps = 200_000.0,
            packetLossRatio = 0.0,
            roundTripTimeMs = 38
        )

        // The uploaded screen trace alternated between source~1fps and
        // source~27fps. A 1fps capture shortage with no pacer backlog is not
        // proof of bandwidth-driven loss, even while a finger is down.
        repeat(12) { index ->
            assertFalse(
                budget.observe(
                    outbound = sourceStarved,
                    receiver = null,
                    sourceFps = 1.0,
                    motionActive = true,
                    targetFps = 24,
                    nowMs = 1_000L + index * 1_000L,
                    interactionActive = true
                )
            )
        }
        assertEquals(360, budget.shortEdge)
    }

    @Test fun activeSparseSourceWithRealRtpBacklogStopsAtReadablePixelFloor() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val congestion = sender(fps = 6, encode = 10.0, queue = 120.0).copy(
            qualityLimitationReason = "bandwidth",
            availableOutgoingBitrateBps = 200_000.0,
            packetLossRatio = 0.0,
            roundTripTimeMs = 160
        )

        assertTrue(
            budget.observe(
                outbound = congestion,
                receiver = null,
                sourceFps = 3.0,
                motionActive = true,
                targetFps = 24,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
    }

    @Test fun activeHighSupplyBandwidthUnderdeliveryStillGetsPixelRelief() {
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        val lossOfFreshThroughput = sender(fps = 5, encode = 5.0, queue = 5.0).copy(
            qualityLimitationReason = "bandwidth",
            packetLossRatio = 0.0,
            roundTripTimeMs = 160
        )

        assertTrue(
            budget.observe(
                outbound = lossOfFreshThroughput,
                receiver = null,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 24,
                nowMs = 1_000L,
                interactionActive = true
            )
        )
        assertEquals(360, budget.shortEdge)
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

    @Test fun activeInteractionHoldsThirtyFpsAgainstOrdinaryJitterPressure() {
        val budget = MotionVideoBudget()
        val cadence = VideoCadenceGovernor(30, 30)
        val delayed = receiver().copy(jitterMs = 95.0)

        repeat(2) { index ->
            val now = (index + 1) * 1_000L
            budget.observe(
                outbound = sender(),
                receiver = delayed,
                sourceFps = 30.0,
                motionActive = true,
                targetFps = 30,
                nowMs = now,
                interactionActive = true
            )
            cadence.observe(
                outbound = sender(),
                receiver = delayed,
                requestedFps = 30,
                nowMs = now,
                minimumFps =
                    budget.cadenceFloor(
                        profile = profile,
                        motionActive = true,
                        nowMs = now,
                        interactionActive = true
                    ),
                producerFps = 30.0
            )
        }

        assertEquals(30, budget.cadenceFloor(profile, true, 2_000L, true))
        assertEquals(30, cadence.cap)
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


    @Test fun cpuLimitationLabelAlonePreservesReadablePixelsForCadenceRelief() {
        val budget = nativeWarmBudget()
        val cpuLimited =
            sender(
                fps = 60,
                encode = 5.0,
                queue = 5.0
            ).copy(
                qualityLimitationReason = "CPU"
            )
        val healthyReceiver = receiver(fps = 60, presented = 60)

        /*
         * WebRTC's CPU reason describes the most limiting reason for
         * resolution and/or frame rate. With MAINTAIN_RESOLUTION, the temporal
         * governor owns that generic signal. Healthy measured encode, queue,
         * decode and presentation therefore must not spend source pixels.
         */
        repeat(8) { index ->
            assertFalse(
                budget.observe(
                    cpuLimited,
                    healthyReceiver,
                    60.0,
                    true,
                    60,
                    500L + index * 500L,
                    interactionActive = true
                )
            )
        }
        assertEquals(720, budget.shortEdge)
    }

    @Test fun cpuLabelWithMeasuredEncoderCollapseStillGetsSpatialSafetyRelief() {
        val budget = nativeWarmBudget()
        val overloaded =
            sender(
                fps = 30,
                encode = 18.0,
                queue = 5.0
            ).copy(
                qualityLimitationReason = "CPU"
            )
        val receiver = receiver(fps = 30, presented = 30)

        assertFalse(
            budget.observe(
                overloaded,
                receiver,
                60.0,
                true,
                60,
                1_000L,
                interactionActive = true
            )
        )
        assertTrue(
            budget.observe(
                overloaded,
                receiver,
                60.0,
                true,
                60,
                2_000L,
                interactionActive = true
            )
        )
        assertEquals(540, budget.shortEdge)
    }

    @Test fun highCadenceSpatialPressureWaitsForTemporalReliefAndFreshEvidence() {
        val budget = nativeWarmBudget()
        val stressed =
            sender(
                fps = 42,
                encode = 20.0,
                queue = 5.0,
                implementation = "c2.qti.avc.encoder"
            )
        val glass = receiver(fps = 42, decode = 5.0, presented = 42)

        // At a 45/60-fps operating point the host keeps this gate closed while
        // cadence spends temporal excess. Repeated old operating-point pressure
        // must not accumulate a hidden pixel vote.
        repeat(2) { index ->
            assertFalse(
                budget.observe(
                    outbound = stressed,
                    receiver = glass,
                    sourceFps = 60.0,
                    motionActive = true,
                    targetFps = 60,
                    nowMs = 1_000L + index * 1_000L,
                    interactionActive = true,
                    allowSpatialRelief = false
                )
            )
        }
        assertEquals(720, budget.apply(profile, true).captureWidthPx)

        // After cadence reaches the 30-fps class, require two fresh completed
        // windows at that operating point before paying a geometry/codec reset.
        assertFalse(
            budget.observe(
                outbound = stressed,
                receiver = glass,
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 3_000L,
                interactionActive = true,
                allowSpatialRelief = true
            )
        )
        assertTrue(
            budget.observe(
                outbound = stressed,
                receiver = glass,
                sourceFps = 60.0,
                motionActive = true,
                targetFps = 60,
                nowMs = 4_000L,
                interactionActive = true,
                allowSpatialRelief = true
            )
        )
        assertEquals(540, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun motionSpatialEligibilityUsesEffectiveThirtyFpsClass() {
        val cadence = VideoCadenceGovernor(60, 60)

        assertFalse(cadence.mayReduceMotionResolution(60))
        assertFalse(cadence.mayReduceMotionResolution(45))

        // LOW/BALANCED profiles are already temporal-first at <=30 fps even if
        // the session-wide governor has a higher hardware ceiling.
        assertTrue(cadence.mayReduceMotionResolution(30))
        assertTrue(cadence.mayReduceMotionResolution(20))
    }


}
