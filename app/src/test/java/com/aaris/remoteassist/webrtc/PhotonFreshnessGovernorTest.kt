package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class PhotonFreshnessGovernorTest {
    private fun outbound(
        fps: Int = 60,
        queueMs: Double = 8.0,
        encodeMs: Double = 5.0,
        loss: Double = 0.0,
        retransmitRatio: Double? = 0.0,
        nacks: Int? = 0,
        plis: Int? = 0
    ) =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 100_000,
            frames = fps.toLong(),
            framesSecondary = fps.toLong(),
            packets = (fps * 3).toLong(),
            packetsLost = 0,
            frameWidth = 720,
            frameHeight = 1600,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = loss,
            recent =
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = fps,
                    processingMs = encodeMs,
                    jitterMs = null,
                    dropped = null,
                    freezes = null,
                    sendQueueMs = queueMs,
                    retransmitRatio = retransmitRatio,
                    nacks = nacks,
                    plis = plis
                )
        )

    private fun receiver(
        fps: Int = 60,
        presented: Int = fps,
        playoutMs: Double = 15.0,
        presentationAgeMs: Int = 40,
        sampleFresh: Boolean = true,
        postAckMs: Int? = 20,
        ackMs: Int? = 40
    ) =
        VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = 4.0,
            jitterMs = playoutMs,
            dropped = 0,
            freezes = 0,
            presentationIntervalMs = 1_000,
            presentedFrames = presented,
            maxRenderGapMs = 20,
            presentationAgeMs = presentationAgeMs,
            displayRefreshRateHz = 60.0,
            presentationSampleSequence = 10,
            presentationSampleAgeMs = 40,
            presentationSampleFresh = sampleFresh,
            inputToGlassUpperBoundMs =
                if (ackMs != null && postAckMs != null) ackMs + postAckMs else null,
            commandAckMs = ackMs,
            postAckPresentMs = postAckMs,
            photonSampleSequence = 20,
            photonSampleAgeMs =
                if (ackMs != null && postAckMs != null) 40 else null,
            photonSampleFresh = true
        )

    @Test
    fun cleanGlassProofGatesCadenceThenDetailRecovery() {
        val g = PhotonFreshnessGovernor()

        var p = g.observe(outbound(), receiver(), 60, false, 1_000)
        assertEquals(PhotonFreshnessState.CLEAN, p.state)
        assertFalse(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)

        p = g.observe(outbound(), receiver(), 60, false, 1_500)
        assertTrue(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)

        g.observe(outbound(), receiver(), 60, false, 2_000)
        p = g.observe(outbound(), receiver(), 60, false, 2_500)
        assertTrue(p.allowCadencePromotion)
        assertTrue(p.allowResolutionRecovery)
    }

    @Test
    fun heldGlassWindowDoesNotBecomeAnotherCleanVote() {
        val g = PhotonFreshnessGovernor()
        g.observe(outbound(), receiver(), 60, false, 1_000)

        val held =
            receiver(sampleFresh = false)
                .copy(presentationSampleAgeMs = 500)
        val p = g.observe(outbound(), held, 60, false, 1_500)

        assertEquals(1, p.cleanGlassWindows)
        assertFalse(p.allowCadencePromotion)
    }

    @Test
    fun slowCommandAckWithFastPostAckGlassDoesNotPunishVideo() {
        val g = PhotonFreshnessGovernor()
        val r = receiver(postAckMs = 20, ackMs = 320)

        g.observe(outbound(), r, 60, false, 1_000)
        val p = g.observe(outbound(), r, 60, false, 1_500)

        assertEquals(340, p.inputToGlassUpperBoundMs)
        assertEquals(320, p.commandAckMs)
        assertEquals(20, p.postAckPresentMs)
        assertEquals(PhotonFreshnessState.CLEAN, p.state)
        assertTrue(p.allowCadencePromotion)
    }

    @Test
    fun slowPostAckPresentationBlocksRiskyUpgrades() {
        val g = PhotonFreshnessGovernor()
        val r = receiver(postAckMs = 220, ackMs = 40)

        val p = g.observe(outbound(), r, 60, false, 1_000)

        assertEquals(PhotonFreshnessState.PRESSURE, p.state)
        assertFalse(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)
        assertEquals(220, p.postAckPresentMs)
    }

    @Test
    fun queueOrPoorGlassResetsCleanEvidence() {
        val g = PhotonFreshnessGovernor()
        g.observe(outbound(), receiver(), 60, false, 1_000)
        g.observe(outbound(), receiver(), 60, false, 1_500)

        val p =
            g.observe(
                outbound(queueMs = 140.0),
                receiver(presented = 40),
                60,
                false,
                2_000
            )

        assertEquals(PhotonFreshnessState.PRESSURE, p.state)
        assertEquals(0, p.cleanGlassWindows)
        assertFalse(p.allowCadencePromotion)
    }

    @Test
    fun missingProofStaysUnknownInsteadOfInventingHealth() {
        val g = PhotonFreshnessGovernor()
        val p = g.observe(outbound(), null, 60, false, 1_000)

        assertEquals(PhotonFreshnessState.UNKNOWN, p.state)
        assertFalse(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)
    }

    @Test
    fun activeTouchCanPromoteCadenceButNeverUpscaleDetail() {
        val g = PhotonFreshnessGovernor()
        var p: PhotonPolicy? = null
        repeat(5) { i ->
            p = g.observe(outbound(), receiver(), 60, true, 1_000L + i * 500L)
        }

        assertTrue(checkNotNull(p).allowCadencePromotion)
        assertFalse(checkNotNull(p).allowResolutionRecovery)
    }

    @Test
    fun activeRetransmissionRepairBlocksPromotionWithoutInventingHardPressure() {
        val g = PhotonFreshnessGovernor()
        g.observe(outbound(), receiver(), 60, false, 1_000)
        val p =
            g.observe(
                outbound(
                    retransmitRatio = 0.12,
                    nacks = 2,
                    plis = 0
                ),
                receiver(),
                60,
                false,
                2_000
            )

        assertEquals(PhotonFreshnessState.WATCH, p.state)
        assertEquals(0, p.cleanGlassWindows)
        assertFalse(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)
    }

    @Test
    fun pictureLossIndicationCancelsCleanPromotionEvidence() {
        val g = PhotonFreshnessGovernor()
        g.observe(outbound(), receiver(), 60, false, 1_000)
        g.observe(outbound(), receiver(), 60, false, 1_500)

        val p =
            g.observe(
                outbound(plis = 1),
                receiver(),
                60,
                false,
                2_000
            )

        assertEquals(PhotonFreshnessState.WATCH, p.state)
        assertEquals(0, p.cleanGlassWindows)
        assertFalse(p.allowCadencePromotion)
    }

    @Test
    fun lightNackActivityWithholdsGrowthWithoutForcingPressure() {
        val g = PhotonFreshnessGovernor()
        val p =
            g.observe(
                outbound(
                    retransmitRatio = 0.01,
                    nacks = 1,
                    plis = 0
                ),
                receiver(),
                60,
                false,
                1_000
            )

        // One NACK in a one-second sample is not a reason to downshift, but it
        // is also not sufficiently clean evidence for an upward quality step.
        assertEquals(PhotonFreshnessState.UNKNOWN, p.state)
        assertEquals(0, p.cleanGlassWindows)
        assertFalse(p.allowCadencePromotion)
        assertFalse(p.allowResolutionRecovery)
    }
}
