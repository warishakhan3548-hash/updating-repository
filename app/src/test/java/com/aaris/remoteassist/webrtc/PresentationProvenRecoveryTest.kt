package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport

class PresentationProvenRecoveryTest {
    private fun snapshot(time: Long, frames: Long, total: Double): VideoHealthSnapshot {
        val stat = RTCStats(
            time,
            "inbound-rtp",
            "video",
            mapOf(
                "kind" to "video",
                "bytesReceived" to frames * 1000,
                "framesReceived" to frames,
                "framesDecoded" to frames,
                "packetsReceived" to frames * 3,
                "totalDecodeTime" to total,
                "jitterBufferDelay" to total * 2,
                "jitterBufferEmittedCount" to frames,
                "framesDropped" to 0L,
                "freezeCount" to 0L
            )
        )
        return checkNotNull(
            VideoHealthSnapshot.from(
                RTCStatsReport(time, mapOf("video" to stat)),
                PeerRole.CONTROLLER
            )
        )
    }

    private fun outbound(frames: Int, processingMs: Double): VideoHealthSnapshot =
        snapshot(2_000_000, 30, 0.15).copy(
            direction = "outbound",
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            recent = VideoHealthWindow(
                intervalMs = 1000,
                frames = frames,
                processingMs = processingMs,
                jitterMs = null,
                dropped = null,
                freezes = null,
                sendQueueMs = 0.0
            )
        )

    private fun receiver(
        frames: Int,
        processingMs: Double,
        presentedFrames: Int = 0,
        maxRenderGapMs: Int? = null
    ) = VideoHealthWindow(
        intervalMs = 1000,
        frames = frames,
        processingMs = processingMs,
        jitterMs = 20.0,
        dropped = 0,
        freezes = 0,
        presentationIntervalMs = if (presentedFrames > 0) 1000 else null,
        presentedFrames = if (presentedFrames > 0) presentedFrames else null,
        maxRenderGapMs = maxRenderGapMs
    )

    @Test
    fun realHealthyEglPresentationLetsTransientDownshiftRecoverWithoutStickyLag() {
        val governor = VideoCadenceGovernor(60)
        val sending60 = outbound(frames = 60, processingMs = 5.0)
        val overloadedReceiver = receiver(frames = 60, processingMs = 25.0)

        assertFalse(governor.observe(sending60, overloadedReceiver, 60, 1_000))
        assertTrue(governor.observe(sending60, overloadedReceiver, 60, 2_000))
        assertEquals(30, governor.cap)

        val healthySender = outbound(frames = 30, processingMs = 5.0)
        val healthyDisplay = receiver(
            frames = 30,
            processingMs = 5.0,
            presentedFrames = 30,
            maxRenderGapMs = 35
        )

        repeat(4) { index ->
            assertFalse(
                governor.observe(
                    healthySender,
                    healthyDisplay,
                    30,
                    3_000L + index * 1_000L
                )
            )
        }
        assertTrue(governor.observe(healthySender, healthyDisplay, 30, 7_000))
        assertEquals(60, governor.cap)
    }
}
