package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import org.junit.Assert.*
import org.junit.Test

class HighCadenceProbeTest {
    private fun sender(fps: Int = 30, encode: Double = 6.0, queue: Double = 4.0) =
        VideoHealthSnapshot("outbound", "video/H264", 0, 0, 0, 0, 0, 360, 800,
            "none", 40, 0.0,
            recent = VideoHealthWindow(1000, fps, encode, null, null, null, sendQueueMs = queue))

    private fun receiver(fps: Int = 30, refresh: Double? = 60.0) =
        VideoHealthWindow(1000, fps, 5.0, 8.0, 0, 0,
            presentationIntervalMs = 1000, presentedFrames = fps,
            maxRenderGapMs = 34, presentationAgeMs = 100, displayRefreshRateHz = refresh)

    private fun sample(g: VideoCadenceGovernor, time: Long, fps: Int = g.cap,
                       recv: VideoHealthWindow? = receiver(fps), source: Double? = 60.0,
                       encode: Double = 6.0, queue: Double = 4.0, allow: Boolean = true,
                       maximum: Int = 60): Boolean =
        g.observe(sender(fps, encode, queue), recv, g.cap, time,
            producerFps = source, maximumFps = maximum, allowHighCadenceProbe = allow)

    private fun promote45(g: VideoCadenceGovernor) {
        assertFalse(sample(g, 1000L))
        assertTrue(sample(g, 2000L))
        assertEquals(45, g.cap)
        assertTrue(g.probingHighCadence)
    }

    @Test fun measuredPathCanProbeAndValidateFortyFiveThenSixty() {
        val g = VideoCadenceGovernor(60, 30)
        promote45(g)

        // Two delivered trial windows validate 45 fps.
        assertFalse(sample(g, 3000L))
        assertFalse(sample(g, 4000L))
        assertFalse(g.probingHighCadence)

        // Three additional end-to-end clean windows earn the 60 fps trial.
        assertFalse(sample(g, 5000L))
        assertFalse(sample(g, 6000L))
        assertTrue(sample(g, 7000L))
        assertEquals(60, g.cap)

        sample(g, 8000L)
        sample(g, 9000L)
        assertFalse(g.probingHighCadence)
    }

    @Test fun slowRecordedEncoderDoesNotEarnFortyFiveFromFastCaptureAlone() {
        val g = VideoCadenceGovernor(60, 30)
        repeat(30) { sample(g, (it + 1) * 1000L, encode = 22.0) }
        assertEquals(30, g.cap)
    }

    @Test fun missingStaleMalformedOrDecoderOnlyEvidenceCannotPromote() {
        val invalid = listOf(null, receiver().copy(presentedFrames = null),
            receiver(refresh = null), receiver().copy(presentationAgeMs = 2000),
            receiver().copy(processingMs = Double.NaN),
            receiver().copy(jitterMs = null), receiver().copy(freezes = null),
            receiver().copy(displayRefreshRateHz = 30.0))
        for (recv in invalid) {
            val g = VideoCadenceGovernor(60, 30)
            repeat(25) { sample(g, (it + 1) * 1000L, recv = recv) }
            assertTrue("Unsafe promotion for $recv", g.cap <= 30)
        }
    }

    @Test fun sourceLimitedOrIdleScreenAndThermalLimitCannotProbe() {
        for (source in listOf(null, 0.0, 30.0, Double.NaN)) {
            val g = VideoCadenceGovernor(60, 30)
            repeat(20) { sample(g, (it + 1) * 1000L, source = source) }
            assertEquals(30, g.cap)
        }
        val g = VideoCadenceGovernor(60, 30)
        repeat(20) { sample(g, (it + 1) * 1000L, allow = false) }
        repeat(20) { sample(g, 21000L + it * 1000L, maximum = 30) }
        assertEquals(30, g.cap)
    }

    @Test fun failedTrialRollsBackAndCannotOscillateOnHealthyWindows() {
        val g = VideoCadenceGovernor(60, 30)
        promote45(g)
        // Transport/encode look clean, but fresh source frames never make the
        // new cadence. This is exactly what sender-only promotion cannot see.
        assertFalse(sample(g, 3000L, fps = 30))
        assertTrue(sample(g, 4000L, fps = 30))
        assertEquals(30, g.cap)

        // Failed trials get a bounded 8s retry cooldown.
        for (time in 5000L..11000L step 1000L) {
            assertFalse(sample(g, time))
        }
        assertFalse(sample(g, 12000L))
        assertTrue(sample(g, 13000L))
        assertEquals(45, g.cap)
    }

    @Test fun repeatedFailedFortyFiveTrialsLearnLongerRetryBackoff() {
        val g = VideoCadenceGovernor(60, 30)

        // First 45-fps experiment fails because end-to-end delivery stays at 30.
        promote45(g)
        assertFalse(sample(g, 3000L, fps = 30))
        assertTrue(sample(g, 4000L, fps = 30))
        assertEquals(30, g.cap)

        // The original bounded 8s cooldown still allows a retry.
        assertFalse(sample(g, 12000L))
        assertTrue(sample(g, 13000L))
        assertEquals(45, g.cap)

        // A second capability failure is stronger evidence. Back off the same
        // target for 16s instead of hammering the encoder every 8s.
        assertFalse(sample(g, 14000L, fps = 30))
        assertTrue(sample(g, 15000L, fps = 30))
        assertEquals(30, g.cap)

        for (time in 23000L..30000L step 1000L) {
            assertFalse(sample(g, time))
            assertEquals(30, g.cap)
        }

        // Once the learned cooldown expires, fresh clean proof can retry.
        assertFalse(sample(g, 31000L))
        assertTrue(sample(g, 32000L))
        assertEquals(45, g.cap)
    }

    @Test fun trialPressureRollsBackImmediatelyAndLostFeedbackExpires() {
        val g = VideoCadenceGovernor(60, 30)
        promote45(g)
        assertTrue(sample(g, 6000, queue = 100.0))
        assertEquals(30, g.cap)

        val h = VideoCadenceGovernor(60, 30)
        promote45(h)
        sample(h, 6000)
        sample(h, 7000)
        for (time in 8000L..10000L step 1000L) sample(h, time, recv = null)
        assertTrue(sample(h, 11000, recv = null))
        assertEquals(30, h.cap)
    }

    @Test fun oneVisibleQueueBurstAtSixtyRelievesBeforeStaleFramesPileUp() {
        val g = VideoCadenceGovernor(60, 60)

        assertTrue(
            g.observe(
                outbound = sender(fps = 60, queue = 45.0),
                receiver = receiver(60),
                requestedFps = 60,
                nowMs = 1_000L,
                producerFps = 60.0
            )
        )
        assertEquals(45, g.cap)
    }

    @Test fun severeQueueBypassesInteractionFloorAndNewTouchCannotUndoRelief() {
        val g = VideoCadenceGovernor(60, 24)
        assertTrue(g.observe(sender(24, queue = 300.0), receiver(24), 24, 1000,
            minimumFps = 24, producerFps = 60.0))
        assertEquals(20, g.cap)
        assertFalse(g.ensureInteractionFloor(24, 1100))
        assertFalse(g.ensureInteractionFloor(24, 8000))
        assertEquals(20, g.cap)
        assertTrue(g.ensureInteractionFloor(24, 9000))
    }

    @Test fun thermalAndDisplayCeilingsCanInterruptAnOtherwiseHealthyTrial() {
        val hot = VideoCadenceGovernor(60, 30)
        promote45(hot)
        assertTrue(sample(hot, 6000, maximum = 24))
        assertEquals(24, hot.cap)
        val limitedDisplay = VideoCadenceGovernor(60, 30)
        promote45(limitedDisplay)
        assertTrue(sample(limitedDisplay, 6000, recv = receiver(45, refresh = 24.0)))
        assertEquals(24, limitedDisplay.cap)
    }

    @Test fun pixelRecoveryIsPausedDuringCadenceTrialButPressureReliefRemainsAvailable() {
        val profile = com.aaris.remoteassist.capture.CaptureProfile(720, 1600, 720, 1600, 30,
            3_000_000, com.aaris.remoteassist.capture.CaptureTier.STANDARD, 60)
        val budget = MotionVideoBudget()
        budget.primeForMotion(profile, 0)
        repeat(20) {
            budget.observe(sender(), receiver(), 60.0, true, 30, (it + 1) * 1000L,
                allowResolutionRecovery = false)
        }
        assertEquals(360, budget.shortEdge)
        budget.observe(sender(5, queue = 300.0).copy(qualityLimitationReason = "bandwidth"),
            receiver(5), 60.0, true, 30, 21000, allowResolutionRecovery = false)
        assertEquals(240, budget.shortEdge)
    }

    @Test fun capabilityPacketIsBoundedLeaseBoundReplaySafeAndExpires() {
        val packet = ControlPacket.DisplayCapabilities(42, 3, 1, 59.94f)
        val bytes = ControlProtocol.encode(packet)
        assertEquals(26, bytes.size)
        assertEquals(packet, ControlProtocol.decode(bytes))
        assertNull(ControlProtocol.toRemoteCommand("session", packet, 1080, 2400))
        assertNull(ControlProtocol.decode(bytes.copyOf(bytes.size - 1)))
        assertNull(ControlProtocol.decode(bytes + byteArrayOf(0)))
        assertThrows(IllegalArgumentException::class.java) { ControlProtocol.encode(packet.copy(refreshRateHz = Float.NaN)) }
        val feedback = ReceiverVideoFeedback()
        assertFalse(feedback.accept(packet, 99, 3, 1000))
        assertFalse(feedback.accept(packet, 42, 4, 1000))
        assertTrue(feedback.accept(packet, 42, 3, 1000))
        assertFalse(feedback.accept(packet, 42, 3, 1001))
        feedback.accept(ControlPacket.PresentationHeartbeat(42, 3, 1), 42, 3, 1000)
        assertEquals(59.94, feedback.consume(42, 3, 1200)!!.displayRefreshRateHz!!, 0.001)
        // Display capability is control-plane metadata. It intentionally
        // outlives sparse/no EGL presentation windows, but still expires if
        // the controller stops refreshing it.
        assertEquals(59.94, feedback.consume(42, 3, 6000)!!.displayRefreshRateHz!!, 0.001)
        assertNull(feedback.consume(42, 3, 16001)!!.displayRefreshRateHz)
        feedback.accept(ControlPacket.PresentationHeartbeat(42, 4, 1), 42, 4, 4100)
        assertNull(feedback.consume(42, 4, 4200)!!.displayRefreshRateHz)
    }
}
