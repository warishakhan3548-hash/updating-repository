package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class VideoStatsEpochWindowTest {
    private fun snapshot(timestampUs: Double, encodedFrames: Long): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = encodedFrames * 1_000L,
            frames = encodedFrames,
            framesSecondary = encodedFrames,
            packets = encodedFrames * 2L,
            packetsLost = 0L,
            frameWidth = 720,
            frameHeight = 1280,
            qualityLimitationReason = "none",
            roundTripTimeMs = 40,
            packetLossRatio = 0.0,
            streamId = "same-ssrc-after-ice-restart",
            timestampUs = timestampUs
        )

    @Test fun reconnectCannotBlendPreAndPostReconnectSenderCadence() {
        val tracker = VideoHealthWindowTracker()
        assertNull(tracker.sample(snapshot(1_000_000.0, 100L)).recent)
        assertEquals(
            30,
            checkNotNull(tracker.sample(snapshot(2_000_000.0, 130L)).recent).frames
        )

        // ICE disconnect/reconnect with same SSRC must seed a new epoch.
        tracker.reset()
        assertNull(tracker.sample(snapshot(2_600_000.0, 132L)).recent)
        val newEpoch = checkNotNull(
            tracker.sample(snapshot(3_600_000.0, 162L)).recent
        )
        assertEquals(30, newEpoch.frames)
        assertEquals(1_000, newEpoch.intervalMs)
    }
}
