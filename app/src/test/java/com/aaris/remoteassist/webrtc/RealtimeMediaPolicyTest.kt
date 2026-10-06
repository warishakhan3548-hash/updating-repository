package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.Priority

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
    fun realtimeScreenRtpUsesHighBestEffortNetworkPriority() {
        assertTrue(RealtimeMediaPolicy.ENABLE_VIDEO_DSCP)
        assertEquals(
            Priority.HIGH,
            RealtimeMediaPolicy.VIDEO_NETWORK_PRIORITY
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
        assertTrue(
            RealtimeMediaPolicy.VIDEO_STATS_RECONFIGURE_KICK_MS <
                RealtimeMediaPolicy.videoStatsIntervalMs(true)
        )
    }

    @Test
    fun riskyProducerUpshiftRequestsOneEarlyHealthMeasurement() {
        assertTrue(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 360,
                previousHeightPx = 800,
                previousFps = 30,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 60
            )
        )
        assertTrue(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 360,
                previousHeightPx = 800,
                previousFps = 30,
                nextWidthPx = 540,
                nextHeightPx = 1_200,
                nextFps = 30
            )
        )
        // Temporal cadence is risky on its own even when fewer pixels keep the
        // aggregate pixel rate from growing.
        assertTrue(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 720,
                previousHeightPx = 1_600,
                previousFps = 30,
                nextWidthPx = 480,
                nextHeightPx = 1_066,
                nextFps = 45
            )
        )
    }

    @Test
    fun reliefUnchangedAndStartupTransitionsDoNotAddProbeWork() {
        assertFalse(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 720,
                previousHeightPx = 1_600,
                previousFps = 60,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 30
            )
        )
        assertFalse(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 360,
                previousHeightPx = 800,
                previousFps = 30,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 30
            )
        )
        assertFalse(
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = 0,
                previousHeightPx = 0,
                previousFps = 0,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 30
            )
        )
    }

    @Test
    fun initialHealthProbeArrivesBeforeLegacyOneSecondWindow() {
        assertTrue(
            RealtimeMediaPolicy.VIDEO_STATS_INITIAL_DELAY_MS in 250L..999L
        )
    }

    @Test
    fun producerUpshiftPrimesSenderBeforeCapture() {
        assertTrue(
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = 720,
                previousHeightPx = 1_600,
                previousFps = 30,
                nextWidthPx = 720,
                nextHeightPx = 1_600,
                nextFps = 60
            )
        )
        assertTrue(
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = 360,
                previousHeightPx = 800,
                previousFps = 30,
                nextWidthPx = 540,
                nextHeightPx = 1_200,
                nextFps = 30
            )
        )
    }

    @Test
    fun pressureReliefStopsProducerBeforeSenderClamp() {
        assertFalse(
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = 720,
                previousHeightPx = 1_600,
                previousFps = 60,
                nextWidthPx = 720,
                nextHeightPx = 1_600,
                nextFps = 30
            )
        )
        assertFalse(
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = 720,
                previousHeightPx = 1_600,
                previousFps = 30,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 60
            )
        )
    }

    @Test
    fun unseededTransitionSafelyPrimesSenderFirst() {
        assertTrue(
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = 0,
                previousHeightPx = 0,
                previousFps = 0,
                nextWidthPx = 360,
                nextHeightPx = 800,
                nextFps = 30
            )
        )
    }
}
