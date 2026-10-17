package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class InteractiveClarityRecoveryTest {
    private val profile = CaptureProfile(
        displayWidthPx = 1080, displayHeightPx = 2400,
        captureWidthPx = 1080, captureHeightPx = 2400,
        fps = 60, maxVideoBitrateBps = 25_000_000,
        tier = CaptureTier.STANDARD, motionFps = 60
    )

    private fun sender(edge: Int = 720) = VideoHealthSnapshot(
        direction = "outbound", codec = "video/H264",
        bytes = 0, frames = 0, framesSecondary = 0, packets = 0, packetsLost = 0,
        frameWidth = edge, frameHeight = edge * 20 / 9,
        qualityLimitationReason = "none", roundTripTimeMs = 28,
        packetLossRatio = 0.0, codecImplementation = "c2.qti.avc.encoder",
        recent = VideoHealthWindow(
            intervalMs = 1000, frames = 60, processingMs = 3.0,
            jitterMs = null, dropped = null, freezes = null,
            bitrateBps = 3_500_000, sendQueueMs = 3.0
        ),
        availableOutgoingBitrateBps = 18_000_000.0
    )

    private fun receiver() = VideoHealthWindow(
        intervalMs = 1000, frames = 60, processingMs = 2.8,
        jitterMs = 6.0, dropped = 0, freezes = 0,
        presentationIntervalMs = 1000, presentedFrames = 60,
        maxRenderGapMs = 22, presentationAgeMs = 16,
        presentationSampleAgeMs = 60, presentationSampleFresh = true
    )

    private fun downgradedBudget(): MotionVideoBudget {
        val budget = MotionVideoBudget()
        val quiet = sender().let { it.copy(recent = it.recent!!.copy(frames = 1)) }
        budget.primeForMotion(profile, 0L, quiet, targetFps = 60)
        val stressed = sender().let {
            it.copy(recent = it.recent!!.copy(frames = 38, processingMs = 21.0))
        }
        assertFalse(observe(budget, 4000L, stressed, allow = false))
        assertTrue(observe(budget, 5000L, stressed, allow = false))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        return budget
    }

    private fun observe(
        budget: MotionVideoBudget,
        nowMs: Long,
        outbound: VideoHealthSnapshot = sender(),
        glass: VideoHealthWindow? = receiver(),
        allow: Boolean = true,
        sourceFps: Double? = 60.0,
        targetProfile: CaptureProfile = profile
    ) = budget.observe(
        outbound = outbound, receiver = glass, sourceFps = sourceFps,
        motionActive = true, targetFps = 60, nowMs = nowMs,
        interactionActive = true, allowResolutionRecovery = allow,
        profile = targetProfile
    )

    private fun windows(
        budget: MotionVideoBudget,
        outbound: VideoHealthSnapshot = sender(),
        glass: VideoHealthWindow? = receiver(),
        allow: Boolean = true,
        sourceFps: Double? = 60.0,
        count: Int = 20,
        startMs: Long = 6000L,
        targetProfile: CaptureProfile = profile
    ) {
        repeat(count) { index ->
            observe(budget, startMs + index * 1000L, outbound, glass, allow,
                sourceFps, targetProfile)
        }
    }

    @Test fun heldGestureRecoversThroughReal900RungWithNewProofForEachGeometry() {
        val budget = downgradedBudget()
        windows(budget, count = 4)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        assertTrue(observe(budget, 10000L))
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
        assertEquals(2000, budget.apply(profile, true).captureHeightPx)
        windows(budget, sender(900), count = 4, startMs = 11000L)
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
        assertTrue(observe(budget, 15000L, sender(900)))
        assertEquals(profile, budget.apply(profile, true))
    }

    @Test fun masterOrCadenceVetoCannotBeOverriddenByPerfectInteractiveHeadroom() {
        val budget = downgradedBudget()
        windows(budget, allow = false)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun activeRecoveryRequiresMeasuredDemandHardwareAndProjectedSenderCapacity() {
        val clean = sender()
        val cases = listOf(
            "no bytes" to clean.copy(recent = clean.recent!!.copy(bitrateBps = 0)),
            "no BWE" to clean.copy(availableOutgoingBitrateBps = null),
            "insufficient BWE" to clean.copy(availableOutgoingBitrateBps = 10_000_000.0),
            "no identity" to clean.copy(codecImplementation = null),
            "software" to clean.copy(codecImplementation = "c2.android.avc.encoder"),
            "wrong dimensions" to clean.copy(frameWidth = 540, frameHeight = 1200),
            // 4 ms fits the CURRENT 35% deadline (5.83 ms), but the projected
            // 900p cost is 6.25 ms. Current-only checks would wrongly promote.
            "projected encoder" to clean.copy(recent = clean.recent!!.copy(processingMs = 4.0)),
            "zero encoder time" to clean.copy(recent = clean.recent!!.copy(processingMs = 0.0)),
            "queue boundary" to clean.copy(recent = clean.recent!!.copy(sendQueueMs = 10.0)),
            "missing queue" to clean.copy(recent = clean.recent!!.copy(sendQueueMs = null)),
            "bandwidth limited" to clean.copy(qualityLimitationReason = "bandwidth")
        )
        cases.forEach { (reason, outbound) ->
            val budget = downgradedBudget()
            windows(budget, outbound)
            assertTrue(reason, budget.apply(profile, true).captureWidthPx <= 720)
        }
        val smallCeiling = profile.copy(maxVideoBitrateBps = 6_000_000)
        val budget = downgradedBudget()
        windows(budget, targetProfile = smallCeiling)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun activeRecoveryRequiresFreshGlassAndProjectedReceiverCapacity() {
        val clean = receiver()
        val cases = listOf(
            "missing receiver" to null,
            "projected decoder" to clean.copy(processingMs = 4.0),
            "zero decoder time" to clean.copy(processingMs = 0.0),
            "jitter boundary" to clean.copy(jitterMs = 18.0),
            "target jitter" to clean.copy(jitterTargetMs = 18.0),
            "missing decode" to clean.copy(processingMs = null),
            "missing jitter" to clean.copy(jitterMs = null),
            "held glass" to clean.copy(presentationSampleFresh = false),
            "stale sample" to clean.copy(presentationSampleAgeMs = 1001),
            "missing sample age" to clean.copy(presentationSampleAgeMs = null),
            "stale swap" to clean.copy(presentationAgeMs = 1001),
            "missing swap age" to clean.copy(presentationAgeMs = null),
            "no swaps" to clean.copy(presentedFrames = null),
            "render gap" to clean.copy(maxRenderGapMs = 80),
            "drop" to clean.copy(dropped = 1),
            "freeze" to clean.copy(freezes = 1),
            "old long-window glass" to clean.copy(
                intervalMs = 2000, frames = 120, presentationIntervalMs = 2000,
                presentedFrames = 120, presentationSampleAgeMs = 1500)
        )
        cases.forEach { (reason, glass) ->
            val budget = downgradedBudget()
            windows(budget, glass = glass)
            assertEquals(reason, 720, budget.apply(profile, true).captureWidthPx)
        }
    }

    @Test fun sourceMustProveMotionAndReportActualPostResizeDimensions() {
        for (source in listOf(null, 1.0, 50.0)) {
            val budget = downgradedBudget()
            windows(budget, sourceFps = source)
            assertEquals(720, budget.apply(profile, true).captureWidthPx)
        }
        val budget = downgradedBudget()
        windows(budget, count = 5)
        windows(budget, startMs = 11000L) // retained pre-resize sender geometry
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun deniedWindowAndEncoderReplacementEachBreakConsecutiveRecoveryProof() {
        for (replaceEncoder in listOf(false, true)) {
            val budget = downgradedBudget()
            windows(budget, count = 4)
            if (replaceEncoder) {
                budget.onSenderEvidence(sender().copy(codecImplementation = "c2.mtk.avc.encoder"))
            } else {
                observe(budget, 10000L, allow = false)
            }
            val current = sender().copy(codecImplementation =
                if (replaceEncoder) "c2.mtk.avc.encoder" else "c2.qti.avc.encoder")
            windows(budget, current, count = 4, startMs = 11000L)
            assertEquals(720, budget.apply(profile, true).captureWidthPx)
            assertTrue(observe(budget, 15000L, current))
            assertEquals(900, budget.apply(profile, true).captureWidthPx)
        }
    }

    @Test fun missingSenderWindowBreaksInteractiveRecoveryProof() {
        val budget = downgradedBudget()
        windows(budget, count = 4)
        observe(budget, 10000L, sender().copy(recent = null))
        windows(budget, count = 4, startMs = 11000L)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        assertTrue(observe(budget, 15000L))
    }

    @Test fun renewedComputePressureStillRelievesPixelsDuringHeldGesture() {
        val budget = downgradedBudget()
        windows(budget, count = 5)
        val stressed = sender(900).let {
            it.copy(recent = it.recent!!.copy(frames = 38, processingMs = 21.0))
        }
        assertFalse(observe(budget, 14000L, stressed))
        assertTrue(observe(budget, 15000L, stressed))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        windows(budget, startMs = 16000L)
        assertEquals("Failed 900p probe must not oscillate during the same gesture",
            720, budget.apply(profile, true).captureWidthPx)
        // Releasing and starting a new interaction permits a fresh attempt.
        budget.observe(sender(), receiver(), 60.0, true, 60, 36000L,
            interactionActive = false, profile = profile)
        windows(budget, count = 5, startMs = 37000L)
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun touchDownCannotBorrowFourOrdinaryRecoveryVotes() {
        val budget = downgradedBudget()
        repeat(4) { index ->
            budget.observe(sender(), receiver(), 60.0, true, 60, 6000L + index * 1000L,
                interactionActive = false, profile = profile)
        }
        assertFalse(observe(budget, 10000L))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        windows(budget, count = 4, startMs = 11000L)
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun laterIndependentNetworkDipCanRecoverWithoutLiftingFinger() {
        val budget = downgradedBudget()
        windows(budget, count = 5)
        val congested = sender(900).let {
            it.copy(recent = it.recent!!.copy(frames = 38, sendQueueMs = 90.0))
        }
        assertFalse(observe(budget, 20000L, congested))
        assertTrue(observe(budget, 21000L, congested))
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        windows(budget, count = 5, startMs = 22000L)
        assertEquals(900, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun lowerInteractiveRungsAlsoRequireUncappedMeasuredDemandAndFiveWindows() {
        for (insufficientCeiling in listOf(false, true)) {
            val budget = downgradedBudget()
            val stressed = sender().let {
                it.copy(recent = it.recent!!.copy(frames = 38, processingMs = 21.0))
            }
            observe(budget, 8000L, stressed, allow = false)
            assertTrue(observe(budget, 9000L, stressed, allow = false))
            assertEquals(540, budget.apply(profile, true).captureWidthPx)
            val clean = sender(540).let {
                it.copy(recent = it.recent!!.copy(processingMs = 1.5, bitrateBps = 1_500_000))
            }
            val glass = receiver().copy(processingMs = 1.4)
            val cap = profile.copy(maxVideoBitrateBps =
                if (insufficientCeiling) 2_000_000 else profile.maxVideoBitrateBps)
            windows(budget, clean, glass, count = 4, startMs = 10000L, targetProfile = cap)
            assertEquals(540, budget.apply(profile, true).captureWidthPx)
            observe(budget, 14000L, clean, glass, targetProfile = cap)
            assertEquals(if (insufficientCeiling) 540 else 720,
                budget.apply(profile, true).captureWidthPx)
        }
    }
}
