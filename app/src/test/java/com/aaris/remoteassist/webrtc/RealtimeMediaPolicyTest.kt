package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.CaptureVideoContract
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.Priority
import org.webrtc.RtpParameters

class RealtimeMediaPolicyTest {
    @Test
    fun remoteControlKeepsAdaptivePlayoutInsideFreshnessBudget() {
        // A positive minimum keeps M150 out of its render-ASAP path, allowing
        // native timestamp/jitter timing to smooth ordinary WAN arrival variance.
        assertEquals(20, RealtimeMediaPolicy.PLAYOUT_DELAY_MIN_MS)
        // Keep at least one 60 Hz frame of native timing reserve without
        // turning the receiver into a multi-frame playback reservoir.
        assertTrue(RealtimeMediaPolicy.PLAYOUT_DELAY_MIN_MS >= 17)
        assertTrue(RealtimeMediaPolicy.PLAYOUT_DELAY_MIN_MS < 34)
        // The native ceiling and app-level hard-pressure alarm are one invariant.
        assertEquals(160, RealtimeMediaPolicy.PLAYOUT_FRESHNESS_PRESSURE_MS)
        assertEquals(180, RealtimeMediaPolicy.PLAYOUT_DELAY_MAX_MS)
        assertTrue(
            RealtimeMediaPolicy.PLAYOUT_DELAY_MAX_MS >
                RealtimeMediaPolicy.PLAYOUT_FRESHNESS_PRESSURE_MS
        )
        assertTrue(
            RealtimeMediaPolicy.PLAYOUT_DELAY_MAX_MS -
                RealtimeMediaPolicy.PLAYOUT_FRESHNESS_PRESSURE_MS <= 20
        )
        assertEquals(
            "WebRTC-ForceSendPlayoutDelay/min_ms:20,max_ms:180/",
            RealtimeMediaPolicy.FIELD_TRIALS
        )
        assertFalse(
            RealtimeMediaPolicy.FIELD_TRIALS
                .contains("WebRTC-ZeroPlayoutDelay")
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
    fun realtimeScreenUsesHighRelativeBitratePriorityWithoutAForcedFloor() {
        assertEquals(
            4.0,
            RealtimeMediaPolicy.VIDEO_BITRATE_PRIORITY,
            0.0
        )
    }

    @Test
    fun senderAcceptsTheEntirePrimaryCaptureClarityEnvelope() {
        assertEquals(
            CaptureVideoContract.MAX_PRIMARY_VIDEO_BITRATE_BPS,
            WebRtcPeer.MAX_VIDEO_BITRATE_BPS
        )
    }

    @Test
    fun nativeOverusePolicyPreservesQuietDetailButPrioritizesFreshMotion() {
        CaptureTier.values().forEach { tier ->
            assertEquals(
                InteractiveVideoPolicy(
                    preserveResolution = true,
                    motionPriority = false
                ),
                InteractiveVideoPolicy.forState(
                    tier = tier,
                    interactionActive = false
                )
            )
            assertEquals(
                InteractiveVideoPolicy(
                    preserveResolution = false,
                    motionPriority = true
                ),
                InteractiveVideoPolicy.forState(
                    tier = tier,
                    interactionActive = true
                )
            )
        }
    }

    @Test
    fun hardwareScreenPathProtectsSevenTwentyClassMotionDetail() {
        assertEquals(
            720,
            RealtimeMediaPolicy.minimumMotionSpatialShortEdge(
                profileShortEdgePx = 1080,
                hardwareRealtimeEncoderAvailable = true
            )
        )
        assertEquals(
            720,
            RealtimeMediaPolicy.minimumMotionSpatialShortEdge(
                profileShortEdgePx = 720,
                hardwareRealtimeEncoderAvailable = true
            )
        )
        assertEquals(
            540,
            RealtimeMediaPolicy.minimumMotionSpatialShortEdge(
                profileShortEdgePx = 540,
                hardwareRealtimeEncoderAvailable = true
            )
        )
    }

    @Test
    fun softwareOrLowDetailPathKeepsCompatibilityEscape() {
        assertEquals(
            360,
            RealtimeMediaPolicy.minimumMotionSpatialShortEdge(
                profileShortEdgePx = 1080,
                hardwareRealtimeEncoderAvailable = false
            )
        )
        assertEquals(
            360,
            RealtimeMediaPolicy.minimumMotionSpatialShortEdge(
                profileShortEdgePx = 360,
                hardwareRealtimeEncoderAvailable = true
            )
        )
    }

    @Test
    fun sourceCadenceNeverEscapesTheActiveCaptureProfile() {
        assertEquals(
            20,
            RealtimeMediaPolicy.effectiveSourceFps(
                idleFps = 15,
                motionFps = 20,
                cadenceCap = 60,
                deviceFpsLimit = 60,
                freshnessActive = true
            )
        )
        assertEquals(
            30,
            RealtimeMediaPolicy.effectiveSourceFps(
                idleFps = 24,
                motionFps = 30,
                cadenceCap = 60,
                deviceFpsLimit = 60,
                freshnessActive = true
            )
        )
        assertEquals(
            24,
            RealtimeMediaPolicy.effectiveSourceFps(
                idleFps = 45,
                motionFps = 60,
                cadenceCap = 60,
                deviceFpsLimit = 24,
                freshnessActive = true
            )
        )
        assertEquals(
            45,
            RealtimeMediaPolicy.effectiveSourceFps(
                idleFps = 45,
                motionFps = 60,
                cadenceCap = 60,
                deviceFpsLimit = 60,
                freshnessActive = false
            )
        )
    }

    @Test
    fun senderFramerateCeilingDoesNotFollowDynamicCadenceRungs() {
        assertEquals(
            60,
            RealtimeMediaPolicy.senderFrameRateCeiling(
                motionFps = 60,
                deviceFpsLimit = 60,
                encoderFpsLimit = 60
            )
        )
        assertEquals(
            30,
            RealtimeMediaPolicy.senderFrameRateCeiling(
                motionFps = 60,
                deviceFpsLimit = 60,
                encoderFpsLimit = 30
            )
        )
        assertEquals(
            20,
            RealtimeMediaPolicy.senderFrameRateCeiling(
                motionFps = 20,
                deviceFpsLimit = 60,
                encoderFpsLimit = 60
            )
        )
    }

    @Test
    fun nativeOveruseNeverCreatesASecondSpatialScaler() {
        assertEquals(
            RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION,
            RealtimeMediaPolicy.videoDegradationPreference(
                motionPriority = true,
                preserveResolution = false
            )
        )
        // Active motion still uses temporal native relief even when a stale
        // caller also requests resolution preservation. MotionVideoBudget is
        // the only component allowed to change source pixels.
        assertEquals(
            RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION,
            RealtimeMediaPolicy.videoDegradationPreference(
                motionPriority = true,
                preserveResolution = true
            )
        )
        assertEquals(
            RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION,
            RealtimeMediaPolicy.videoDegradationPreference(
                motionPriority = false,
                preserveResolution = true
            )
        )
        assertEquals(
            RtpParameters.DegradationPreference.BALANCED,
            RealtimeMediaPolicy.videoDegradationPreference(
                motionPriority = false,
                preserveResolution = false
            )
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
