package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.*
import org.junit.Test

/** Independent 500 ms host/EGL clocks and a 1500 ms idle decoder stats clock. */
class FeedbackCadenceIntegrationTest {
    private val feedback = ReceiverVideoFeedback()
    private var sequence = 0L

    private fun sender(fps: Int, encodeMs: Double = 6.0, queueMs: Double = 5.0) =
        VideoHealthSnapshot(
            "outbound", "video/H264", 0, 0, 0, 0, 0, 360, 800,
            "none", 40, 0.0, streamId = "screen-1",
            recent = VideoHealthWindow(500, fps / 2, encodeMs, null, null, null,
                sendQueueMs = queueMs)
        )

    private fun receive(nowMs: Long, fps: Int, decoderFrames: Int? = null,
        newPresentation: Boolean = true): VideoHealthWindow {
        assertTrue(feedback.accept(ControlPacket.DisplayCapabilities(
            42, 2, ++sequence, 60f), 42, 2, nowMs))
        if (newPresentation) {
            assertTrue(feedback.accept(ControlPacket.PresentationFeedback(
                42, 2, ++sequence, 500, fps / 2, 50), 42, 2, nowMs))
        }
        assertTrue(feedback.accept(ControlPacket.PresentationHeartbeat(
            42, 2, ++sequence), 42, 2, nowMs))
        if (decoderFrames != null) {
            assertTrue(feedback.accept(ControlPacket.VideoFeedback(
                42, 2, ++sequence, 1500, decoderFrames,
                if (decoderFrames > 0) 5f else -1f, 10f, 0, 0), 42, 2, nowMs))
        }
        return checkNotNull(feedback.consume(42, 2, nowMs))
    }

    @Test fun phasedDecoderReportsDoNotPinProvenRecoveryAtTwentyFour() {
        val cadence = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..16_000L step 500L) {
            val fps = cadence.cap
            val decoded = if ((now - 1_000L) % 1_500L == 0L) fps * 3 / 2 else null
            cadence.observe(sender(fps, encodeMs = 25.0), receive(now, fps, decoded),
                fps, now, producerFps = 60.0, allowHighCadenceProbe = false)
        }
        assertEquals(30, cadence.cap)
    }

    @Test fun phasedDecoderReportsAllowAProvenHighCadenceTrialToComplete() {
        val cadence = VideoCadenceGovernor(60, initialCap = 30)
        val photon = PhotonFreshnessGovernor()
        for (now in 1_000L..16_000L step 500L) {
            val fps = cadence.cap
            val decoded = if ((now - 1_000L) % 1_500L == 0L) fps * 3 / 2 else null
            val outbound = sender(fps)
            val receiver = receive(now, fps, decoded)
            val policy = photon.observe(outbound, receiver, fps, false, now)
            cadence.observe(outbound, receiver, fps, now, producerFps = 60.0,
                maximumFps = 36, allowHighCadenceProbe = policy.allowCadencePromotion)
        }
        assertEquals(36, cadence.cap)
        assertFalse(cadence.probingHighCadence)
    }

    @Test fun aDecoderReportMayPairWithRecentGlassConsumedOnAnEarlierHostTick() {
        val cadence = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..16_000L step 500L) {
            val fps = cadence.cap
            val decoded = if ((now - 1_000L) % 1_500L == 0L) fps * 3 / 2 else null
            val newGlass = (now - 1_000L) % 1_000L == 0L
            cadence.observe(sender(fps, encodeMs = 25.0), receive(now, fps, decoded, newGlass),
                fps, now, producerFps = 60.0, allowHighCadenceProbe = false)
        }
        assertEquals(30, cadence.cap)
    }

    @Test fun independentlyPhasedGlassDoesNotTimeOutAHealthyHighCadenceTrial() {
        val cadence = VideoCadenceGovernor(60, initialCap = 30)
        val photon = PhotonFreshnessGovernor()
        for (now in 1_000L..16_000L step 500L) {
            val fps = cadence.cap
            val decoded = if ((now - 1_000L) % 1_500L == 0L) fps * 3 / 2 else null
            val newGlass = (now - 1_000L) % 1_000L == 0L
            val outbound = sender(fps)
            val receiver = receive(now, fps, decoded, newGlass)
            val policy = photon.observe(outbound, receiver, fps, false, now)
            cadence.observe(outbound, receiver, fps, now, producerFps = 60.0,
                maximumFps = 36, allowHighCadenceProbe = policy.allowCadencePromotion)
        }
        assertEquals(36, cadence.cap)
        assertFalse(cadence.probingHighCadence)
    }

    @Test fun oneGlassSampleCannotVoteAgainWhenAnotherDecoderReportArrives() {
        val photon = PhotonFreshnessGovernor()
        photon.observe(sender(30), receive(1_000L, 30, 45), 30, false, 1_000L)
        val policy = photon.observe(sender(30), receive(1_500L, 30, 45, false),
            30, false, 1_500L)
        assertEquals(1, policy.cleanGlassWindows)
        assertFalse(policy.allowCadencePromotion)
    }

    @Test fun pairingUnusedHeldGlassDoesNotRepeatItsPresentationPressure() {
        val cadence = VideoCadenceGovernor(60)
        val hitch = receive(1_000L, 20)
        assertTrue(cadence.observe(sender(60), hitch, 60, 1_000L,
            producerFps = 60.0, allowHighCadenceProbe = false))
        val relievedCap = cadence.cap
        val paired = receive(1_500L, relievedCap, 90, false)
        assertFalse(paired.presentationSampleFresh)
        assertFalse(cadence.observe(sender(relievedCap), paired, relievedCap, 1_500L,
            producerFps = 60.0, allowHighCadenceProbe = false))
        assertEquals(relievedCap, cadence.cap)
    }

    @Test fun phasedDecoderReportsDoNotPermanentlyBlockDetailRecovery() {
        val profile = CaptureProfile(720, 1600, 720, 1600, 30, 3_000_000,
            CaptureTier.STANDARD, 60)
        val budget = MotionVideoBudget()
        assertTrue(budget.primeForMotion(profile, 0L))
        assertEquals(360, budget.shortEdge)
        val photon = PhotonFreshnessGovernor()
        for (now in 1_000L..25_000L step 500L) {
            val decoded = if ((now - 1_000L) % 1_500L == 0L) 45 else null
            val outbound = sender(30)
            val receiver = receive(now, 30, decoded)
            val policy = photon.observe(outbound, receiver, 30, false, now)
            budget.observe(outbound, receiver, 60.0, true, 30, now,
                allowResolutionRecovery = policy.allowResolutionRecovery)
        }
        assertEquals(540, budget.shortEdge)
    }

    @Test fun absenceCannotVoteAndARealZeroDecodeWindowClearsProof() {
        val photon = PhotonFreshnessGovernor()
        var policy = photon.observe(sender(30), receive(1_000L, 30, 45), 30, false, 1_000L)
        assertEquals(1, policy.cleanGlassWindows)
        for (now in 1_500L..2_000L step 500L) {
            policy = photon.observe(sender(30), receive(now, 30), 30, false, now)
            assertEquals(1, policy.cleanGlassWindows)
            assertFalse(policy.allowCadencePromotion)
            assertFalse(policy.allowResolutionRecovery)
        }
        policy = photon.observe(sender(30), receive(2_500L, 30, 0, false), 30, false, 2_500L)
        assertNull(policy.glassDeliveryRatio)
        assertEquals(0, policy.cleanGlassWindows)
        assertFalse(policy.allowCadencePromotion)
    }

    @Test fun prolongedDecoderSilenceExpiresProofEvenWithContinuingEglSwaps() {
        val photon = PhotonFreshnessGovernor()
        photon.observe(sender(30), receive(1_000L, 30, 45), 30, false, 1_000L)
        var policy = photon.current()
        for (now in 1_500L..5_000L step 500L) {
            policy = photon.observe(sender(30), receive(now, 30), 30, false, now)
            assertFalse(policy.allowCadencePromotion)
        }
        assertEquals(0, policy.cleanGlassWindows)
    }

    @Test fun freshGlassWithoutAnyDecoderReportCannotInventCapacity() {
        val cadence = VideoCadenceGovernor(60, initialCap = 30)
        val photon = PhotonFreshnessGovernor()
        for (now in 1_000L..8_000L step 500L) {
            val outbound = sender(30)
            val receiver = receive(now, 30)
            val policy = photon.observe(outbound, receiver, 30, false, now)
            assertEquals(0, policy.cleanGlassWindows)
            assertFalse(policy.allowCadencePromotion)
            assertFalse(cadence.observe(outbound, receiver, 30, now, producerFps = 60.0,
                allowHighCadenceProbe = policy.allowCadencePromotion))
        }
        assertEquals(30, cadence.cap)
    }

    @Test fun missingDecoderReportDoesNotSuppressRealSenderQueuePressure() {
        val photon = PhotonFreshnessGovernor()
        photon.observe(sender(30), receive(1_000L, 30, 45), 30, false, 1_000L)
        val policy = photon.observe(sender(30, queueMs = 350.0), receive(1_500L, 30),
            30, false, 1_500L)
        assertEquals(PhotonFreshnessState.PRESSURE, policy.state)
        assertEquals(0, policy.cleanGlassWindows)
        assertFalse(policy.allowCadencePromotion)
    }

    @Test fun missingDecoderReportDoesNotSuppressMeasuredGlassPressure() {
        val photon = PhotonFreshnessGovernor()
        photon.observe(sender(30), receive(1_000L, 30, 45), 30, false, 1_000L)
        val policy = photon.observe(sender(30), receive(1_500L, 6), 30, false, 1_500L)
        assertEquals(PhotonFreshnessState.PRESSURE, policy.state)
        assertEquals(0, policy.cleanGlassWindows)
        assertFalse(policy.allowCadencePromotion)
    }

    @Test fun lateDecoderReportCannotReuseExpiredCadenceRecoveryVotes() {
        val cadence = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..16_000L step 500L) {
            val fps = cadence.cap
            val reportDue = (now - 1_000L) % 1_500L == 0L
            val decoderOnline = now <= 5_500L || now >= 9_500L
            val decoded = if (reportDue && decoderOnline) fps * 3 / 2 else null
            cadence.observe(sender(fps, encodeMs = 25.0), receive(now, fps, decoded),
                fps, now, producerFps = 60.0, allowHighCadenceProbe = false)
            // The decoder resumes on its next 1500 ms tick at 10000 ms.
            // Only its fifth new complete report, at 16000 ms, may recover.
            if (now < 16_000L) assertEquals(24, cadence.cap)
        }
        assertEquals(30, cadence.cap)
    }
}
