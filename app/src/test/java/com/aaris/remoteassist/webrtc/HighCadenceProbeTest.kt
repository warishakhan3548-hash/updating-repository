package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test

class HighCadenceProbeTest {
    private fun sender(
        fps: Int = 30,
        encode: Double = 6.0,
        queue: Double = 4.0,
        loss: Double = 0.0,
        rtt: Int = 40
    ) =
        VideoHealthSnapshot(
            "outbound", "video/H264", 0, 0, 0, 0, 0, 360, 800,
            "none", rtt, loss,
            recent =
                VideoHealthWindow(
                    1000, fps, encode, null, null, null,
                    sendQueueMs = queue
                )
        )

    private fun receiver(
        fps: Int = 30,
        refresh: Double? = 60.0,
        presented: Int = fps,
        dropped: Int = 0,
        gap: Int = 34,
        sequence: Long? = null,
        fresh: Boolean = true
    ) =
        VideoHealthWindow(
            1000, fps, 5.0, 8.0, dropped, 0,
            presentationIntervalMs = 1000,
            presentedFrames = presented,
            maxRenderGapMs = gap,
            presentationAgeMs = 100,
            displayRefreshRateHz = refresh,
            presentationSampleSequence = sequence,
            presentationSampleAgeMs = 100,
            presentationSampleFresh = fresh
        )

    private fun sample(
        g: VideoCadenceGovernor,
        time: Long,
        fps: Int = g.cap,
        recv: VideoHealthWindow? = receiver(fps),
        source: Double? = 60.0,
        encode: Double = 6.0,
        queue: Double = 4.0,
        loss: Double = 0.0,
        rtt: Int = 40,
        allow: Boolean = true,
        maximum: Int = 60
    ): Boolean =
        g.observe(
            sender(fps, encode, queue, loss, rtt),
            recv,
            g.cap,
            time,
            producerFps = source,
            maximumFps = maximum,
            allowHighCadenceProbe = allow
        )

    private fun driveCleanUntil(
        g: VideoCadenceGovernor,
        target: Int,
        startMs: Long = 1_000L
    ): Long {
        var time = startMs
        repeat(120) {
            sample(g, time)
            time += 1_000L
            if (g.cap >= target && !g.probingHighCadence) return time
        }
        fail("Governor never reached stable ${target}fps; cap=${g.cap}")
        return time
    }


    @Test
    fun missingRemoteLossCounterDoesNotTrapGenuinelyCleanSixtyHzPath() {
        val g = VideoCadenceGovernor(60, 30)
        val outbound = sender().copy(packetLossRatio = null)
        assertFalse(
            g.observe(
                outbound, receiver(sequence = 1), 30, 1_000L,
                producerFps = 60.0
            )
        )
        assertTrue(
            g.observe(
                outbound, receiver(sequence = 2), 30, 2_000L,
                producerFps = 60.0
            )
        )
        assertEquals(36, g.cap)
    }

    @Test
    fun missingLossFallbackCannotBypassDropOrExplicitBadLoss() {
        for (outbound in listOf(
            sender().copy(packetLossRatio = null),
            sender().copy(packetLossRatio = 0.15),
            sender().copy(packetLossRatio = Double.NaN)
        )) {
            val g = VideoCadenceGovernor(60, 30)
            repeat(5) { index ->
                // Explicit high loss may legitimately trigger a DOWNshift.
                // This regression only forbids an unsafe high-FPS promotion.
                g.observe(
                    outbound,
                    receiver(sequence = index.toLong() + 1, dropped = 2),
                    30,
                    1_000L + index * 1_000L,
                    producerFps = 60.0
                )
            }
            assertTrue("Loss/drop evidence must not promote high cadence", g.cap <= 30)
        }
    }
    @Test
    fun spatialBudgetTransitionCancelsActiveTrialWithoutDroppingLearnedCap() {
        val g = VideoCadenceGovernor(60, 30)

        assertFalse(
            sample(
                g,
                1_000L,
                recv = receiver(30, sequence = 1)
            )
        )
        assertTrue(
            sample(
                g,
                2_000L,
                recv = receiver(30, sequence = 2)
            )
        )
        assertEquals(36, g.cap)
        assertTrue(g.probingHighCadence)

        g.onSpatialBudgetTransition(2_100L)

        assertEquals(36, g.cap)
        assertFalse(g.probingHighCadence)

        // The first post-resize glass sample may describe a codec restart.
        // It must not immediately launch another cadence experiment.
        assertFalse(
            sample(
                g,
                2_600L,
                fps = 36,
                recv = receiver(36, sequence = 3)
            )
        )
        assertEquals(36, g.cap)
        assertFalse(g.probingHighCadence)
    }

    @Test
    fun spatialBudgetTransitionInvalidatesPreResizeFastPresentationEvidence() {
        val g = VideoCadenceGovernor(60, 60)

        // Seed completed sender supply for the old spatial operating point.
        assertFalse(
            g.observe(
                outbound = sender(fps = 60),
                receiver = receiver(60, sequence = 10),
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(60, g.cap)

        g.onSpatialBudgetTransition(1_100L)

        // A controller hitch immediately after resize must wait for fresh
        // post-resize sender supply before it may vote on cadence.
        assertFalse(
            g.observeFastPresentation(
                intervalMs = 500,
                renderedFrames = 10,
                maxGapMs = 200,
                requestedFps = 60,
                interactionActive = true,
                nowMs = 1_600L,
                displayRefreshRateHz = 60.0
            )
        )
        assertEquals(60, g.cap)
    }

    @Test fun cleanPathUsesFastPromotionAndFineReliefHysteresis() {
        val g = VideoCadenceGovernor(60, 30)
        val seen = linkedSetOf(g.cap)
        var time = 1_000L

        repeat(120) {
            sample(g, time)
            seen += g.cap
            time += 1_000L
            if (g.cap == 60 && !g.probingHighCadence) return@repeat
        }

        assertEquals(60, g.cap)
        assertFalse(g.probingHighCadence)
        assertTrue(
            "Expected evidence-backed promotion ladder, saw $seen",
            seen.containsAll(listOf(30, 36, 40, 45, 50, 60)) &&
                !seen.contains(33) &&
                !seen.contains(55) &&
                !seen.contains(58)
        )
    }

    @Test
    fun ninetyHzControllerSettlesAtFortyFiveInsteadOfPulldownSixty() {
        val g = VideoCadenceGovernor(60, 30)
        var time = 1_000L

        repeat(40) {
            sample(
                g = g,
                time = time,
                fps = g.cap,
                recv =
                    receiver(
                        fps = g.cap,
                        refresh = 90.0,
                        presented = g.cap,
                        gap = 34
                    ),
                source = 60.0
            )
            time += 1_000L
        }

        assertEquals(45, g.cap)
        assertFalse(g.probingHighCadence)
    }

    @Test
    fun oneFortyFourHzControllerCanUseExactFortyEightFpsHarmonic() {
        val g = VideoCadenceGovernor(60, 30)
        var time = 1_000L

        repeat(40) {
            sample(
                g = g,
                time = time,
                fps = g.cap,
                recv =
                    receiver(
                        fps = g.cap,
                        refresh = 144.0,
                        presented = g.cap,
                        gap = 34
                    ),
                source = 60.0
            )
            time += 1_000L
        }

        assertEquals(48, g.cap)
        assertFalse(g.probingHighCadence)
    }

    @Test fun oneOrTwoRandomFrameMissesAtSixtyAreTolerated() {
        val g = VideoCadenceGovernor(60, 60)
        val recv =
            receiver(
                fps = 60,
                presented = 59,
                dropped = 1,
                gap = 34
            )

        assertFalse(
            g.observe(
                outbound = sender(fps = 60),
                receiver = recv,
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(60, g.cap)
    }

    @Test fun sustainedMildGlassMissUsesDisplayPacedReliefNotLongBeatTrim() {
        val g = VideoCadenceGovernor(60, 60)
        val recv =
            receiver(
                fps = 60,
                presented = 48,
                dropped = 0,
                gap = 50
            )

        assertFalse(
            g.observe(
                outbound = sender(fps = 60),
                receiver = recv,
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(60, g.cap)

        assertTrue(
            g.observe(
                outbound = sender(fps = 60),
                receiver = recv,
                requestedFps = 60,
                nowMs = 1_500L,
                producerFps = 60.0
            )
        )
        assertEquals(50, g.cap)
    }

    @Test fun ordinaryQueuePressureNeedsConfirmationBeforeFineRelief() {
        val g = VideoCadenceGovernor(60, 60)

        assertFalse(
            g.observe(
                outbound = sender(fps = 60, queue = 45.0),
                receiver = receiver(60),
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(60, g.cap)

        assertTrue(
            g.observe(
                outbound = sender(fps = 60, queue = 45.0),
                receiver = receiver(60),
                requestedFps = 60,
                nowMs = 1_500L,
                producerFps = 60.0
            )
        )
        assertEquals(50, g.cap)
    }

    @Test fun severeQueueCanStillTakeLargeFreshnessRelief() {
        val g = VideoCadenceGovernor(60, 60)

        assertTrue(
            g.observe(
                outbound = sender(fps = 40, queue = 300.0),
                receiver = receiver(40, presented = 38),
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertTrue(g.cap <= 30)
    }

    @Test fun retainedPresentationBridgesStatsPhaseWithoutDoubleVoting() {
        val g = VideoCadenceGovernor(60, 30)
        val first =
            receiver(30, sequence = 100, fresh = true)
        val held =
            first.copy(
                presentationSampleAgeMs = 550,
                presentationSampleFresh = false
            )
        val second =
            receiver(30, sequence = 101, fresh = true)

        assertFalse(sample(g, 1_000L, recv = first))
        assertFalse(sample(g, 1_500L, recv = held))
        assertEquals(30, g.cap)

        assertTrue(sample(g, 2_000L, recv = second))
        assertEquals(36, g.cap)
        assertTrue(g.probingHighCadence)
    }

    @Test fun retainedTrialWindowCannotValidateSameFineStepTwice() {
        val g = VideoCadenceGovernor(60, 30)

        assertFalse(sample(g, 1_000L, recv = receiver(30, sequence = 1)))
        assertTrue(sample(g, 2_000L, recv = receiver(30, sequence = 2)))
        assertEquals(36, g.cap)
        assertTrue(g.probingHighCadence)

        val fresh =
            receiver(36, sequence = 3, fresh = true)
        val held =
            fresh.copy(
                presentationSampleAgeMs = 550,
                presentationSampleFresh = false
            )

        assertFalse(sample(g, 3_000L, fps = 36, recv = fresh))
        assertFalse(sample(g, 3_500L, fps = 36, recv = held))
        assertFalse(sample(g, 4_000L, fps = 36, recv = held))
        assertTrue(g.probingHighCadence)

        assertFalse(
            sample(
                g,
                4_500L,
                fps = 36,
                recv = receiver(36, sequence = 4, fresh = true)
            )
        )
        assertFalse(g.probingHighCadence)
    }

    @Test fun slowEncoderDoesNotEarnHigherCadenceFromFastCaptureAlone() {
        val g = VideoCadenceGovernor(60, 30)
        repeat(30) {
            sample(
                g,
                (it + 1) * 1_000L,
                encode = 30.0
            )
        }
        assertEquals(30, g.cap)
    }

    @Test fun missingStaleMalformedOrDecoderOnlyEvidenceCannotPromote() {
        val invalid =
            listOf(
                null,
                receiver().copy(presentedFrames = null),
                receiver(refresh = null),
                receiver().copy(presentationAgeMs = 2_000),
                receiver().copy(processingMs = Double.NaN),
                receiver().copy(freezes = null),
                receiver().copy(displayRefreshRateHz = 30.0)
            )

        for (recv in invalid) {
            val g = VideoCadenceGovernor(60, 30)
            repeat(25) {
                sample(g, (it + 1) * 1_000L, recv = recv)
            }
            assertTrue("Unsafe promotion for $recv", g.cap <= 30)
        }
    }

    @Test fun sourceLimitedIdleDisabledOrThermalLimitedPathCannotProbe() {
        for (source in listOf(null, 0.0, 30.0, Double.NaN)) {
            val g = VideoCadenceGovernor(60, 30)
            repeat(20) {
                sample(
                    g,
                    (it + 1) * 1_000L,
                    source = source
                )
            }
            assertEquals(30, g.cap)
        }

        val disabled = VideoCadenceGovernor(60, 30)
        repeat(20) {
            sample(
                disabled,
                (it + 1) * 1_000L,
                allow = false
            )
        }
        assertEquals(30, disabled.cap)

        val limited = VideoCadenceGovernor(60, 30)
        repeat(20) {
            sample(
                limited,
                (it + 1) * 1_000L,
                maximum = 30
            )
        }
        assertEquals(30, limited.cap)
    }

    @Test fun failedFineTrialRollsBackAndUsesRetryCooldown() {
        val g = VideoCadenceGovernor(60, 30)

        assertFalse(sample(g, 1_000L))
        assertTrue(sample(g, 2_000L))
        assertEquals(36, g.cap)

        // 25fps is below the allowed delivery proof for a 36fps trial.
        assertFalse(sample(g, 3_000L, fps = 25, recv = receiver(25)))
        assertTrue(sample(g, 4_000L, fps = 25, recv = receiver(25)))
        assertEquals(30, g.cap)

        // Retry is bounded; no immediate 30<->36 oscillation.
        for (time in 5_000L..7_000L step 1_000L) {
            assertFalse(sample(g, time))
            assertEquals(30, g.cap)
        }

        assertFalse(sample(g, 8_000L))
        assertTrue(sample(g, 9_000L))
        assertEquals(36, g.cap)
    }

    @Test fun highCadenceTrialIgnoresOneSoftBlipButRollsBackWhenItPersists() {
        val g = VideoCadenceGovernor(60, 30)
        assertFalse(sample(g, 1_000L))
        assertTrue(sample(g, 2_000L))
        assertEquals(36, g.cap)

        // One ordinary queue excursion blocks fresh proof but is not enough to
        // throw away the trial. A second consecutive overload confirms it.
        assertFalse(sample(g, 3_000L, fps = 36, queue = 80.0))
        assertEquals(36, g.cap)

        assertTrue(sample(g, 4_000L, fps = 36, queue = 80.0))
        assertEquals(30, g.cap)
    }

    @Test fun highCadenceTrialStillRollsBackImmediatelyForUrgentPressure() {
        val g = VideoCadenceGovernor(60, 30)
        assertFalse(sample(g, 1_000L))
        assertTrue(sample(g, 2_000L))
        assertEquals(36, g.cap)

        assertTrue(sample(g, 3_000L, fps = 36, queue = 180.0))
        assertEquals(30, g.cap)
    }

    @Test fun displayOrDeviceCeilingCanInterruptHealthyFineTrial() {
        val deviceLimited = VideoCadenceGovernor(60, 30)
        assertFalse(sample(deviceLimited, 1_000L))
        assertTrue(sample(deviceLimited, 2_000L))
        assertEquals(36, deviceLimited.cap)
        assertTrue(sample(deviceLimited, 3_000L, maximum = 24))
        assertEquals(24, deviceLimited.cap)

        val displayLimited = VideoCadenceGovernor(60, 30)
        assertFalse(sample(displayLimited, 1_000L))
        assertTrue(sample(displayLimited, 2_000L))
        assertEquals(36, displayLimited.cap)
        assertTrue(
            sample(
                displayLimited,
                3_000L,
                recv = receiver(36, refresh = 24.0)
            )
        )
        assertEquals(24, displayLimited.cap)
    }

    @Test fun pixelRecoveryIsPausedDuringCadenceTrialButPressureReliefRemainsAvailable() {
        val profile =
            com.aaris.remoteassist.capture.CaptureProfile(
                720, 1600, 720, 1600, 30,
                3_000_000,
                com.aaris.remoteassist.capture.CaptureTier.STANDARD,
                60
            )
        val budget = MotionVideoBudget()
        budget.primeForMotion(profile, 0)
        repeat(20) {
            budget.observe(
                sender(),
                receiver(),
                60.0,
                true,
                30,
                (it + 1) * 1_000L,
                allowResolutionRecovery = false
            )
        }
        assertEquals(360, budget.shortEdge)

        budget.observe(
            sender(5, queue = 300.0).copy(qualityLimitationReason = "bandwidth"),
            receiver(5),
            60.0,
            true,
            30,
            21_000L,
            allowResolutionRecovery = false
        )
        assertEquals(240, budget.shortEdge)
    }

    @Test fun capabilityPacketIsBoundedLeaseBoundReplaySafeAndExpires() {
        val packet =
            ControlPacket.DisplayCapabilities(
                42, 3, 1, 59.94f
            )
        val bytes = ControlProtocol.encode(packet)
        assertEquals(26, bytes.size)
        assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertNull(ControlProtocol.decode(bytes + byteArrayOf(0)))
        assertThrows(IllegalArgumentException::class.java) {
            ControlProtocol.encode(
                packet.copy(refreshRateHz = Float.NaN)
            )
        }

        val feedback = ReceiverVideoFeedback()
        assertFalse(feedback.accept(packet, 99, 3, 1_000))
        assertFalse(feedback.accept(packet, 42, 4, 1_000))
        assertTrue(feedback.accept(packet, 42, 3, 1_000))
        assertFalse(feedback.accept(packet, 42, 3, 1_001))
        feedback.accept(
            ControlPacket.PresentationHeartbeat(42, 3, 1),
            42,
            3,
            1_000
        )
        assertEquals(
            59.94,
            feedback.currentDisplayRefreshRateHz(42, 3, 1_200)!!,
            0.001
        )
        assertEquals(
            59.94,
            feedback.consume(42, 3, 1_200)!!.displayRefreshRateHz!!,
            0.001
        )
        assertEquals(
            59.94,
            feedback.consume(42, 3, 6_000)!!.displayRefreshRateHz!!,
            0.001
        )
        assertNull(
            feedback.currentDisplayRefreshRateHz(
                42,
                3,
                16_001
            )
        )
        assertNull(
            feedback.consume(
                42,
                3,
                16_001
            )!!.displayRefreshRateHz
        )
        feedback.accept(
            ControlPacket.PresentationHeartbeat(42, 4, 1),
            42,
            4,
            4_100
        )
        assertNull(
            feedback.consume(
                42,
                4,
                4_200
            )!!.displayRefreshRateHz
        )
    }
}
