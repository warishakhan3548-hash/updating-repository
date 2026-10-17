package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NativeMotionRecoveryTest {
    private val profile = CaptureProfile(
        displayWidthPx = 1080,
        displayHeightPx = 2400,
        captureWidthPx = 1080,
        captureHeightPx = 2400,
        fps = 30,
        maxVideoBitrateBps = 25_000_000,
        tier = CaptureTier.STANDARD,
        motionFps = 60
    )

    private fun sender() = VideoHealthSnapshot(
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
        roundTripTimeMs = 60,
        packetLossRatio = 0.0,
        codecImplementation = "c2.qti.avc.encoder",
        recent = VideoHealthWindow(
            intervalMs = 1000,
            frames = 30,
            processingMs = 3.0,
            jitterMs = null,
            dropped = null,
            freezes = null,
            bitrateBps = 2_000_000,
            sendQueueMs = 5.0
        ),
        availableOutgoingBitrateBps = 12_000_000.0
    )

    private fun receiver() = VideoHealthWindow(
        intervalMs = 1000,
        frames = 30,
        processingMs = 3.0,
        jitterMs = 5.0,
        dropped = 0,
        freezes = 0,
        presentationIntervalMs = 1000,
        presentedFrames = 30,
        maxRenderGapMs = 34,
        presentationAgeMs = 20,
        presentationSampleAgeMs = 100,
        presentationSampleFresh = true
    )

    private fun downgradedBudget(target: CaptureProfile = profile): MotionVideoBudget {
        val budget = MotionVideoBudget()
        val quiet = sender().let {
            it.copy(recent = it.recent!!.copy(frames = 1),
                availableOutgoingBitrateBps = 20_000_000.0)
        }
        budget.primeForMotion(target, 0L, quiet, targetFps = 30)
        val overloaded = sender().let {
            it.copy(recent = it.recent!!.copy(frames = 20, processingMs = 35.0))
        }
        assertFalse(budget.observe(overloaded, receiver(), 30.0, true, 30,
            4000L, profile = target))
        assertTrue(budget.observe(overloaded, receiver(), 30.0, true, 30,
            5000L, profile = target))
        assertEquals(720, budget.apply(target, true).captureWidthPx)
        return budget
    }

    private fun recover(
        budget: MotionVideoBudget,
        target: CaptureProfile? = profile,
        outbound: VideoHealthSnapshot = sender(),
        glass: VideoHealthWindow? = receiver(),
        sourceFps: Double? = 30.0,
        interactionActive: Boolean = false,
        allowResolutionRecovery: Boolean = true,
        windows: Int = 5,
        startMs: Long = 6000L
    ) {
        repeat(windows) { index ->
            budget.observe(
                outbound = outbound,
                receiver = glass,
                sourceFps = sourceFps,
                motionActive = true,
                targetFps = 30,
                nowMs = startMs + index * 1000L,
                interactionActive = interactionActive,
                allowResolutionRecovery = allowResolutionRecovery,
                profile = target
            )
        }
    }

    @Test fun continuousMotionRecoversOneRungPerFiveMeasuredHeadroomWindows() {
        val budget = downgradedBudget()
        recover(budget, windows = 4)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
        budget.observe(sender(), receiver(), 30.0, true, 30, 10000L, profile = profile)
        assertEquals(900, budget.shortEdge)
        val resized = sender().copy(frameWidth = 900, frameHeight = 2000)
        recover(budget, outbound = resized, startMs = 11000L)
        assertEquals(1080, budget.shortEdge)
        assertEquals(profile, budget.apply(profile, true))
    }

    @Test fun nativeRecoveryStopsAtExactProfileGeometry() {
        val bounded = profile.copy(captureWidthPx = 900, captureHeightPx = 2000)
        val budget = downgradedBudget(bounded)
        recover(budget, target = bounded)
        assertEquals(900, budget.shortEdge)
        assertEquals(bounded, budget.apply(bounded, true))
    }

    @Test fun recoveredNativePressureReturnsToSevenTwentyBeforeLowerRungs() {
        val budget = downgradedBudget()
        recover(budget)
        val stressed = sender().let {
            it.copy(frameWidth = 900, frameHeight = 2000,
                recent = it.recent!!.copy(frames = 20, processingMs = 35.0))
        }
        assertFalse(budget.observe(stressed, receiver(), 30.0, true, 30,
            14000L, profile = profile))
        assertTrue(budget.observe(stressed, receiver(), 30.0, true, 30,
            15000L, profile = profile))
        assertEquals(720, budget.shortEdge)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun nativeRecoveryRequiresUncappedRtpDemandAndProjectedCodecBudget() {
        val cases = listOf(
            "missing RTP byte delta" to sender().let {
                it.copy(recent = it.recent!!.copy(bitrateBps = 0))
            },
            "missing bandwidth estimate" to sender().copy(availableOutgoingBitrateBps = null),
            // Current 720p demand fits, but the 900p probe + reserve does not.
            "projected bandwidth" to sender().copy(availableOutgoingBitrateBps = 5_000_000.0),
            "projected encoder work" to sender().let {
                it.copy(recent = it.recent!!.copy(processingMs = 11.0))
            },
            "missing implementation" to sender().copy(codecImplementation = null),
            "stale source geometry" to sender().copy(frameWidth = 540, frameHeight = 1200)
        )
        cases.forEach { (reason, outbound) ->
            val budget = downgradedBudget()
            recover(budget, outbound = outbound, windows = 20)
            assertEquals(reason, 720, budget.apply(profile, true).captureWidthPx)
        }
        val smallCeiling = profile.copy(maxVideoBitrateBps = 3_000_000)
        val budget = downgradedBudget()
        recover(budget, target = smallCeiling, windows = 20)
        assertEquals(720, budget.apply(smallCeiling, true).captureWidthPx)
    }

    @Test fun nativeRecoveryRequiresFreshPresentationAndProjectedDecoderHeadroom() {
        val cases = listOf(
            "missing receiver" to null,
            "projected decoder work" to receiver().copy(processingMs = 11.0),
            "held presentation" to receiver().copy(presentationSampleFresh = false),
            "missing presentation age" to receiver().copy(presentationSampleAgeMs = null),
            "stale presentation" to receiver().copy(presentationSampleAgeMs = 1001),
            "stale last swap" to receiver().copy(presentationAgeMs = 1001)
        )
        cases.forEach { (reason, glass) ->
            val budget = downgradedBudget()
            recover(budget, glass = glass, windows = 20)
            assertEquals(reason, 720, budget.apply(profile, true).captureWidthPx)
        }
    }

    @Test fun nativeRecoveryRequiresStricterTouchHeadroomAndPreservesCadenceVetoAndSourceProof() {
        val touch = downgradedBudget()
        // 8 ms projects to 12.5 ms at 900p: within the ordinary recovery
        // budget (15 ms), outside the held-gesture budget (11.67 ms).
        val modest = sender().let { it.copy(recent = it.recent!!.copy(processingMs = 8.0)) }
        recover(touch, outbound = modest, interactionActive = true, windows = 20)
        assertEquals(720, touch.apply(profile, true).captureWidthPx)
        val trial = downgradedBudget()
        recover(trial, allowResolutionRecovery = false, windows = 20)
        assertEquals(720, trial.apply(profile, true).captureWidthPx)
        val missingSource = downgradedBudget()
        recover(missingSource, sourceFps = null, windows = 20)
        assertEquals(720, missingSource.apply(profile, true).captureWidthPx)
    }

    @Test fun missingProfileKeepsCompatibilityRecoveryCeiling() {
        val budget = downgradedBudget()
        recover(budget, target = null, windows = 20)
        assertEquals(720, budget.shortEdge)
        assertEquals(720, budget.apply(profile, true).captureWidthPx)
    }

    @Test fun platformSoftwareComponentsCannotBorrowNativeHardwareHeadroom() {
        listOf(
            "c2.android.avc.encoder",
            "OMX.google.h264.encoder",
            "c2.google.vp8.encoder"
        ).forEach { implementation ->
            val budget = downgradedBudget()
            recover(budget, outbound = sender().copy(codecImplementation = implementation),
                windows = 20)
            assertTrue(implementation, budget.apply(profile, true).captureWidthPx <= 720)
        }
    }
}
