package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test
import org.webrtc.RTCStats
import org.webrtc.RTCStatsReport

class SentFrameSupplyTest {
    private fun outbound(time: Long, encoded: Long, sent: Long?): VideoHealthSnapshot {
        val members = mutableMapOf<String, Any>(
            "kind" to "video", "framesEncoded" to encoded,
            "bytesSent" to encoded * 1_000, "packetsSent" to encoded * 3,
            "totalEncodeTime" to encoded * 0.010,
            "totalPacketSendDelay" to encoded * 3 * 0.005
        )
        sent?.let { members["framesSent"] = it }
        val stat = RTCStats(time, "outbound-rtp", "screen", members)
        return checkNotNull(VideoHealthSnapshot.from(
            RTCStatsReport(time, mapOf("screen" to stat)), PeerRole.HOST
        ))
    }

    @Test fun encodeCostAndTransmittedCadenceUseTheirOwnCounters() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(outbound(1_000_000L, 100, 100))
        val window = checkNotNull(tracker.sample(
            outbound(2_000_000L, 160, 130)
        ).recent)
        assertEquals(60, window.frames)
        assertEquals(30, window.sentFrames)
        assertEquals(60.0, window.fps, 0.001)
        assertEquals(30.0, window.deliveryFps, 0.001)
        assertEquals(10.0, window.processingMs!!, 0.001)
        assertEquals(5.0, window.sendQueueMs!!, 0.001)
        assertTrue(window.compact().contains("sent=30fps"))
    }

    @Test fun measuredZeroSupplyRemainsZero() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(outbound(1_000_000L, 100, 100))
        val window = tracker.sample(outbound(2_000_000L, 160, 100)).recent!!
        assertEquals(0, window.sentFrames)
        assertEquals(0.0, window.deliveryFps, 0.001)
        assertEquals(60.0, window.fps, 0.001)
    }

    @Test fun absentOrResetSentCountersDoNotInventAZeroOrNegativeDelta() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(outbound(1_000_000L, 100, 100))
        val missing = tracker.sample(outbound(2_000_000L, 160, null)).recent!!
        assertNull(missing.sentFrames)
        assertEquals(missing.fps, missing.deliveryFps, 0.001)
        assertNull(tracker.sample(outbound(3_000_000L, 220, 10)).recent!!.sentFrames)
        assertEquals(30, tracker.sample(outbound(4_000_000L, 280, 40)).recent!!.sentFrames)
        assertNull(tracker.sample(outbound(5_000_000L, 340, 2)).recent!!.sentFrames)
        assertEquals(30, tracker.sample(outbound(6_000_000L, 400, 32)).recent!!.sentFrames)
    }

    @Test fun pacerCanDrainOlderFramesWithoutCorruptingEncodeCost() {
        val tracker = VideoHealthWindowTracker()
        tracker.sample(outbound(1_000_000L, 100, 70))
        val drained = tracker.sample(outbound(2_000_000L, 110, 100)).recent!!
        assertEquals(10.0, drained.fps, 0.001)
        assertEquals(30.0, drained.deliveryFps, 0.001)
        assertEquals(10.0, drained.processingMs!!, 0.001)
    }
}
