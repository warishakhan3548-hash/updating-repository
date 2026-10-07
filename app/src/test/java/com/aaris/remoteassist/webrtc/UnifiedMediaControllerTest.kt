package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class UnifiedMediaControllerTest {
    private val profile =
        CaptureProfile(
            displayWidthPx = 1080,
            displayHeightPx = 2400,
            captureWidthPx = 1080,
            captureHeightPx = 2400,
            fps = 45,
            maxVideoBitrateBps = 10_000_000,
            tier = CaptureTier.STANDARD,
            motionFps = 60
        )

    private fun outbound(
        fps: Int,
        encodeMs: Double = 5.0,
        residenceMs: Double = 5.0,
        loss: Double = 0.0,
        reason: String = "none",
        bweBps: Double = 10_000_000.0,
        rttMs: Int = 80
    ): VideoHealthSnapshot =
        VideoHealthSnapshot(
            direction = "outbound",
            codec = "video/H264",
            bytes = 1_000_000,
            frames = fps.toLong(),
            framesSecondary = fps.toLong(),
            packets = (fps * 3).toLong(),
            packetsLost = 0,
            frameWidth = 720,
            frameHeight = 1600,
            qualityLimitationReason = reason,
            roundTripTimeMs = rttMs,
            packetLossRatio = loss,
            codecImplementation = "c2.qti.avc.encoder",
            availableOutgoingBitrateBps = bweBps,
            recent =
                VideoHealthWindow(
                    intervalMs = 1_000,
                    frames = fps,
                    processingMs = encodeMs,
                    jitterMs = null,
                    dropped = null,
                    freezes = null,
                    bitrateBps = 3_000_000,
                    sendQueueMs = residenceMs
                )
        )

    private fun receiver(
        fps: Int,
        decodeMs: Double = 5.0,
        playoutMs: Double = 12.0,
        presentedFps: Int = fps,
        maxGapMs: Int = 20,
        refreshHz: Double = 60.0
    ): VideoHealthWindow =
        VideoHealthWindow(
            intervalMs = 1_000,
            frames = fps,
            processingMs = decodeMs,
            jitterMs = playoutMs,
            dropped = 0,
            freezes = 0,
            presentationIntervalMs = 1_000,
            presentedFrames = presentedFps,
            maxRenderGapMs = maxGapMs,
            presentationAgeMs = 50,
            displayRefreshRateHz = refreshHz,
            jitterTargetMs = playoutMs
        )

    @Test
    fun quietScreenNeverChangesOperatingPoint() {
        val controller = UnifiedMediaController(profile)

        val before =
            controller.effectiveProfile(
                profile,
                deviceFpsLimit = 60,
                displayRefreshRateHz = 60.0
            )

        repeat(10) { index ->
            assertFalse(
                controller.observe(
                    profile = profile,
                    outbound =
                        outbound(
                            fps = 1,
                            encodeMs = 5.0,
                            residenceMs = 250.0,
                            loss = 0.15,
                            reason = "bandwidth",
                            bweBps = 300_000.0
                        ),
                    receiver = null,
                    sourceFps = 1.0,
                    interactionActive = false,
                    deviceFpsLimit = 60,
                    displayRefreshRateHz = 60.0,
                    nowMs = 1_000L + index * 500L
                )
            )
        }

        val after =
            controller.effectiveProfile(
                profile,
                deviceFpsLimit = 60,
                displayRefreshRateHz = 60.0
            )
        assertEquals(before.captureWidthPx, after.captureWidthPx)
        assertEquals(before.captureHeightPx, after.captureHeightPx)
        assertEquals(before.fps, after.fps)
    }

    @Test
    fun ordinaryNetworkPressureNeedsThreeWindowsBeforeOneStep() {
        val controller = UnifiedMediaController(profile)
        val stressed =
            outbound(
                fps = 60,
                residenceMs = 70.0,
                reason = "bandwidth",
                bweBps = 5_600_000.0
            )

        assertFalse(
            controller.observe(
                profile, stressed, receiver(60), 60.0, true,
                60, 60.0, 1_000L
            )
        )
        assertFalse(
            controller.observe(
                profile, stressed, receiver(60), 60.0, true,
                60, 60.0, 1_500L
            )
        )
        assertTrue(
            controller.observe(
                profile, stressed, receiver(60), 60.0, true,
                60, 60.0, 2_000L
            )
        )

        val effective =
            controller.effectiveProfile(profile, 60, 60.0)
        assertEquals(540, minOf(effective.captureWidthPx, effective.captureHeightPx))
        assertEquals(60, effective.fps)
    }

    @Test
    fun severePressureTakesBoundedCoordinatedRelief() {
        val controller = UnifiedMediaController(profile)

        assertTrue(
            controller.observe(
                profile = profile,
                outbound =
                    outbound(
                        fps = 20,
                        encodeMs = 28.0,
                        residenceMs = 220.0,
                        loss = 0.14,
                        reason = "bandwidth",
                        bweBps = 2_000_000.0
                    ),
                receiver =
                    receiver(
                        fps = 20,
                        decodeMs = 25.0,
                        playoutMs = 190.0,
                        presentedFps = 18,
                        maxGapMs = 280
                    ),
                sourceFps = 60.0,
                interactionActive = true,
                deviceFpsLimit = 60,
                displayRefreshRateHz = 60.0,
                nowMs = 1_000L
            )
        )

        val effective =
            controller.effectiveProfile(profile, 60, 60.0)
        assertEquals(540, minOf(effective.captureWidthPx, effective.captureHeightPx))
        assertEquals(30, effective.fps)
    }

    @Test
    fun recoveryIsMuchSlowerThanRelief() {
        val controller = UnifiedMediaController(profile)
        val stressed =
            outbound(
                fps = 60,
                residenceMs = 70.0,
                reason = "bandwidth",
                bweBps = 5_600_000.0
            )

        repeat(3) { index ->
            controller.observe(
                profile, stressed, receiver(60), 60.0, true,
                60, 60.0, 1_000L + index * 500L
            )
        }

        assertEquals(
            540,
            minOf(
                controller.effectiveProfile(profile, 60, 60.0).captureWidthPx,
                controller.effectiveProfile(profile, 60, 60.0).captureHeightPx
            )
        )

        val clean = outbound(fps = 60, bweBps = 10_000_000.0)
        repeat(7) { index ->
            assertFalse(
                controller.observe(
                    profile, clean, receiver(60), 60.0, true,
                    60, 60.0, 10_000L + index * 500L
                )
            )
        }
        assertTrue(
            controller.observe(
                profile, clean, receiver(60), 60.0, true,
                60, 60.0, 13_500L
            )
        )

        val recovered =
            controller.effectiveProfile(profile, 60, 60.0)
        assertEquals(720, minOf(recovered.captureWidthPx, recovered.captureHeightPx))
        assertEquals(60, recovered.fps)
    }

    @Test
    fun cadenceMatchesControllerDisplayDivisor() {
        val controller = UnifiedMediaController(profile)

        val ninetyHz =
            controller.effectiveProfile(
                profile,
                deviceFpsLimit = 60,
                displayRefreshRateHz = 90.0
            )
        assertEquals(45, ninetyHz.fps)

        val sixtyHz =
            controller.effectiveProfile(
                profile,
                deviceFpsLimit = 60,
                displayRefreshRateHz = 60.0
            )
        assertEquals(60, sixtyHz.fps)
    }
}
