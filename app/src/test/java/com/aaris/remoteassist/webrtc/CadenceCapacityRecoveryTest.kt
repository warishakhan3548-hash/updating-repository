package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CadenceCapacityRecoveryTest {
    private fun sender(fps: Int, encodeMs: Double) = VideoHealthSnapshot(
        direction = "outbound",
        codec = "video/H264",
        bytes = 1_000_000,
        frames = fps.toLong(),
        framesSecondary = fps.toLong(),
        packets = 180,
        packetsLost = 0,
        frameWidth = 360,
        frameHeight = 800,
        qualityLimitationReason = "none",
        roundTripTimeMs = 40,
        packetLossRatio = 0.0,
        streamId = "screen-1",
        recent = VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = encodeMs,
            jitterMs = null,
            dropped = null,
            freezes = null,
            sendQueueMs = 5.0
        )
    )

    private fun receiver(fps: Int, decodeMs: Double, sequence: Int) = VideoHealthWindow(
        intervalMs = 1_000,
        frames = fps,
        processingMs = decodeMs,
        jitterMs = 10.0,
        dropped = 0,
        freezes = 0,
        presentedFrames = fps,
        presentationIntervalMs = 1_000,
        maxRenderGapMs = 50,
        presentationAgeMs = 40,
        displayRefreshRateHz = 60.0,
        presentationSampleSequence = sequence.toLong(),
        presentationSampleAgeMs = 40,
        presentationSampleFresh = true
    )

    private fun observe(
        governor: VideoCadenceGovernor,
        nowMs: Long,
        encodeMs: Double = 5.0,
        decodeMs: Double = 5.0,
        maximumFps: Int = 60,
        transformReceiver: (VideoHealthWindow) -> VideoHealthWindow? = { it }
    ): Boolean {
        val fps = governor.cap
        return governor.observe(
            outbound = sender(fps, encodeMs),
            receiver = transformReceiver(receiver(fps, decodeMs, (nowMs / 500).toInt())),
            requestedFps = fps,
            nowMs = nowMs,
            producerFps = fps.toDouble(),
            maximumFps = maximumFps,
            allowHighCadenceProbe = false
        )
    }

    @Test fun healthyTwentyFiveMsEncoderCanRecoverFromTwentyFourToThirty() {
        val governor = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..12_000L step 1_000L) {
            observe(governor, now, encodeMs = 25.0)
        }
        assertEquals(30, governor.cap)
    }

    @Test fun healthyTwentyFiveMsDecoderCanRecoverFromTwentyFourToThirty() {
        val governor = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..12_000L step 1_000L) {
            observe(governor, now, decodeMs = 25.0)
        }
        assertEquals(30, governor.cap)
    }

    @Test fun recoveryPricesTheNextAllowedRungAndHonorsTheDisplayCeiling() {
        val governor = VideoCadenceGovernor(60, initialCap = 20)
        for (now in 1_000L..16_000L step 1_000L) {
            observe(governor, now, encodeMs = 32.0, decodeMs = 32.0, maximumFps = 24)
        }
        assertEquals(24, governor.cap)
    }

    @Test fun eitherCodecMustRetainTwentyPercentHeadroomAtTheNextCadence() {
        for ((encodeMs, decodeMs) in listOf(27.0 to 5.0, 5.0 to 27.0)) {
            val governor = VideoCadenceGovernor(60, initialCap = 24)
            for (now in 1_000L..16_000L step 1_000L) {
                assertFalse(observe(governor, now, encodeMs, decodeMs))
            }
            assertEquals(24, governor.cap)
        }
    }

    @Test fun missingOrAlreadyConsumedPresentationKeepsConservativeRecovery() {
        val feedback = listOf<(VideoHealthWindow) -> VideoHealthWindow?>(
            { null },
            { it.copy(presentedFrames = null, presentationIntervalMs = null) },
            { it.copy(presentationSampleFresh = false) }
        )
        for (transform in feedback) {
            val governor = VideoCadenceGovernor(60, initialCap = 24)
            for (now in 1_000L..16_000L step 1_000L) {
                assertFalse(observe(governor, now, encodeMs = 25.0, transformReceiver = transform))
            }
            assertEquals(24, governor.cap)
        }
    }

    @Test fun provenRecoveryStillWaitsForTheChangeCooldown() {
        val governor = VideoCadenceGovernor(60, initialCap = 20)
        assertTrue(governor.ensureInteractionFloor(24, nowMs = 1_000L))
        for (now in 1_500L..5_500L step 500L) {
            assertFalse(observe(governor, now, encodeMs = 25.0))
            assertEquals(24, governor.cap)
        }
        assertTrue(observe(governor, 6_000L, encodeMs = 25.0))
        assertEquals(30, governor.cap)
    }

    @Test fun aDroppedFrameResetsConsecutiveRecoveryEvidence() {
        val governor = VideoCadenceGovernor(60, initialCap = 24)
        for (now in 1_000L..4_000L step 1_000L) {
            assertFalse(observe(governor, now, encodeMs = 25.0))
        }
        assertFalse(observe(governor, 5_000L, encodeMs = 25.0,
            transformReceiver = { it.copy(dropped = 1) }))
        for (now in 6_000L..9_000L step 1_000L) {
            assertFalse(observe(governor, now, encodeMs = 25.0))
            assertEquals(24, governor.cap)
        }
        assertTrue(observe(governor, 10_000L, encodeMs = 25.0))
        assertEquals(30, governor.cap)
    }
}
