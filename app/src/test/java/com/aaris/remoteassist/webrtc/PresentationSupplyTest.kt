package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PresentationSupplyTest {
    private fun sender(fps: Int = 60, streamId: String = "screen-1") =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 1_000_000,
            frames = 60,
            framesSecondary = 60,
            packets = 180,
            packetsLost = 0,
            frameWidth = 360,
            frameHeight = 800,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            streamId = streamId,
            recent = VideoHealthWindow(
                intervalMs = 1_000,
                frames = fps,
                processingMs = 5.0,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = 5.0
            )
        )

    private fun present(
        governor: VideoCadenceGovernor,
        frames: Int = 15,
        gapMs: Int = 34,
        nowMs: Long = 1_500L
    ) = governor.observeFastPresentation(
        intervalMs = 500,
        renderedFrames = frames,
        maxGapMs = gapMs,
        requestedFps = governor.cap,
        interactionActive = true,
        nowMs = nowMs
    )

    @Test fun evenlyDeliveredThirtyFpsMustNotBeJudgedAgainstSixtyFpsCeiling() {
        val governor = VideoCadenceGovernor(60)
        assertFalse(governor.observe(sender(30), null, 60, 1_000L, producerFps = 30.0))
        assertFalse(present(governor))
        assertEquals(60, governor.cap)
    }

    @Test fun sparseScreenUpdatesMustNotAccumulateFalseGlassPressure() {
        val governor = VideoCadenceGovernor(60)
        for (now in 1_000L..5_000L step 500L) {
            assertFalse(governor.observe(sender(10), null, 60, now, producerFps = 10.0))
            assertFalse(present(governor, frames = 5, gapMs = 100, nowMs = now + 100L))
            assertEquals(60, governor.cap)
        }
    }

    @Test fun unknownUpstreamSupplyCannotProveRendererOverload() {
        val governor = VideoCadenceGovernor(60)
        assertFalse(present(governor, frames = 10, gapMs = 180))
        assertEquals(60, governor.cap)
    }

    @Test fun staleOrFutureSenderMeasurementCannotDriveFastRelief() {
        for (now in listOf(999L, 2_501L)) {
            val governor = VideoCadenceGovernor(60)
            assertFalse(governor.observe(sender(), null, 60, 1_000L))
            assertFalse(present(governor, frames = 10, gapMs = 180, nowMs = now))
            assertEquals(60, governor.cap)
        }
    }

    @Test fun replacementStreamOrCodecInvalidatesOldSupplyImmediately() {
        for (replacement in listOf(
            sender(streamId = "screen-2").copy(recent = null),
            sender().copy(codec = "video/VP8", recent = null)
        )) {
            val governor = VideoCadenceGovernor(60)
            assertFalse(governor.observe(sender(), null, 60, 1_000L))
            assertFalse(governor.observe(replacement, null, 60, 1_200L))
            assertFalse(present(governor, frames = 10, gapMs = 180))
            assertEquals(60, governor.cap)
        }
    }

    @Test fun shortSameStreamProbeKeepsRecentCompletedSupply() {
        val governor = VideoCadenceGovernor(60)
        assertFalse(governor.observe(sender(), null, 60, 1_000L))
        assertFalse(governor.observe(sender().copy(recent = null), null, 60, 1_100L))
        assertTrue(present(governor, frames = 10, gapMs = 180))
        assertEquals(58, governor.cap)
    }

    @Test fun longOrEmptySenderWindowCannotProveCurrentGlassOverload() {
        val complete = sender()
        val measured = checkNotNull(complete.recent)
        for (window in listOf(
            measured.copy(intervalMs = 4_000, frames = 240),
            measured.copy(frames = 0)
        )) {
            val governor = VideoCadenceGovernor(60)
            assertFalse(governor.observe(complete.copy(recent = window), null, 60, 1_000L))
            assertFalse(present(governor, frames = 10, gapMs = 180))
            assertEquals(60, governor.cap)
        }
    }

    @Test fun healthyMeasuredSupplyStillAllowsBoundedPersistentGlassRelief() {
        val governor = VideoCadenceGovernor(60)
        assertFalse(governor.observe(sender(), null, 60, 1_000L))
        assertTrue(present(governor, frames = 10, gapMs = 180))
        assertEquals(58, governor.cap)
        assertTrue(present(governor, frames = 10, gapMs = 180, nowMs = 2_000L))
        assertEquals(55, governor.cap)
    }
}
