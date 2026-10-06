package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class RealtimeMediaPolicyTest {
    @Test
    fun remoteControlUsesBoundedLowLatencyPlayout() {
        assertEquals(0, RealtimeMediaPolicy.PLAYOUT_DELAY_MIN_MS)
        assertTrue(
            RealtimeMediaPolicy.PLAYOUT_DELAY_MAX_MS in 1..500
        )
        assertEquals(
            "WebRTC-ForceSendPlayoutDelay/min_ms:0,max_ms:100/",
            RealtimeMediaPolicy.FIELD_TRIALS
        )
    }

    @Test
    fun activeInteractionGetsHigherSchedulingPriorityThanIdle() {
        assertTrue(
            RealtimeMediaPolicy.threadPriority(true) <
                RealtimeMediaPolicy.threadPriority(false)
        )
    }

    @Test
    fun realtimeVideoHealthSamplingIsFasterThanIdleSampling() {
        assertEquals(
            500L,
            RealtimeMediaPolicy.videoStatsIntervalMs(true)
        )
        assertEquals(
            1_500L,
            RealtimeMediaPolicy.videoStatsIntervalMs(false)
        )
        assertTrue(
            RealtimeMediaPolicy.VIDEO_STATS_FAST_KICK_MS <
                RealtimeMediaPolicy.videoStatsIntervalMs(true)
        )
    }

    @Test
    fun initialHealthProbeArrivesBeforeLegacyOneSecondWindow() {
        assertTrue(
            RealtimeMediaPolicy.VIDEO_STATS_INITIAL_DELAY_MS in 250L..999L
        )
    }
}
