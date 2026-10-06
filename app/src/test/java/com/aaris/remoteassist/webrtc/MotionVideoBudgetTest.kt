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
        // Once the minimum pixel budget has been tried, freshness still has a safety exit.
        assertTrue(cadence.observe(collapse, null, 30, 7000, budget.cadenceFloor(profile, true, 7000)))
        assertTrue(cadence.cap < 30)
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
}
