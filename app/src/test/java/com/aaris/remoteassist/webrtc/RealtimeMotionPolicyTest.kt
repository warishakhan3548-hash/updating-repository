package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import org.junit.Assert.assertEquals
import org.junit.Test

class RealtimeMotionPolicyTest {
    private fun profile(
        width: Int,
        height: Int,
        fps: Int,
        motionFps: Int,
        tier: CaptureTier
    ) = CaptureProfile(
        displayWidthPx = width,
        displayHeightPx = height,
        captureWidthPx = width,
        captureHeightPx = height,
        fps = fps,
        maxVideoBitrateBps = 10_000_000,
        tier = tier,
        motionFps = motionFps
    )

    @Test
    fun standardInteractionReducesPixelBudgetButKeepsAspectAndMotionCadence() {
        val result = RealtimeMotionPolicy.apply(
            base = profile(1080, 2400, 45, 60, CaptureTier.STANDARD),
            interactionActive = true,
            cadenceCap = 60
        )

        assertEquals(864, result.captureWidthPx)
        assertEquals(1920, result.captureHeightPx)
        assertEquals(60, result.fps)
    }

    @Test
    fun idleImmediatelyRestoresClarityProfile() {
        val base = profile(1080, 2400, 45, 60, CaptureTier.STANDARD)
        val result = RealtimeMotionPolicy.apply(
            base = base,
            interactionActive = false,
            cadenceCap = 60
        )

        assertEquals(base, result)
    }

    @Test
    fun cadenceCapWinsOverMotionTarget() {
        val result = RealtimeMotionPolicy.apply(
            base = profile(1080, 2400, 45, 60, CaptureTier.STANDARD),
            interactionActive = true,
            cadenceCap = 45
        )

        assertEquals(45, result.fps)
        assertEquals(1920, result.captureHeightPx)
    }

    @Test
    fun balancedTierDoesNotLoseExtraResolution() {
        val result = RealtimeMotionPolicy.apply(
            base = profile(540, 1200, 24, 30, CaptureTier.BALANCED),
            interactionActive = true,
            cadenceCap = 30
        )

        assertEquals(540, result.captureWidthPx)
        assertEquals(1200, result.captureHeightPx)
        assertEquals(30, result.fps)
    }
}
