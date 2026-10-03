package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class CaptureProfileTest {
    @Test
    fun lowRamFlagAlwaysProtectsDevice() {
        assertEquals(
            CaptureTier.LOW,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = true,
                totalMemoryBytes = 8L * GIB
            )
        )
    }

    @Test
    fun twoAndThreeGigabyteDevicesStayLow() {
        assertEquals(CaptureTier.LOW, CaptureProfile.recommendedTierForDevice(false, 2L * GIB))
        assertEquals(CaptureTier.LOW, CaptureProfile.recommendedTierForDevice(false, 3L * GIB))
    }

    @Test
    fun fourGigabyteClassUsesNativeDetailStandardTier() {
        assertEquals(CaptureTier.STANDARD, CaptureProfile.recommendedTierForDevice(false, 4L * GIB))
    }

    @Test
    fun sixGigabyteAndAboveUsesHighTier() {
        assertEquals(CaptureTier.HIGH, CaptureProfile.recommendedTierForDevice(false, 6L * GIB))
    }

    @Test
    fun unknownMemoryFailsSafeToBalanced() {
        assertEquals(CaptureTier.BALANCED, CaptureProfile.recommendedTierForDevice(false, 0L))
    }

    @Test
    fun standardKeepsNativeModernTallPhoneDetailAndCanBurstTo60fps() {
        val profile = CaptureProfile.forDisplay(1080, 2400, CaptureTier.STANDARD)
        assertEquals(1080, profile.captureWidthPx)
        assertEquals(2400, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(60, profile.motionFps)
        assertEquals(10_000_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun balancedTierKeepsConservativeRealtimeBudget() {
        val profile = CaptureProfile.forDisplay(1080, 2400, CaptureTier.BALANCED)
        assertEquals(540, profile.captureWidthPx)
        assertEquals(1200, profile.captureHeightPx)
        assertEquals(24, profile.fps)
        assertEquals(30, profile.motionFps)
        assertEquals(3_000_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun highTierKeepsExtraDetailAnd60fpsMotionHeadroom() {
        val profile = CaptureProfile.forDisplay(1440, 3200, CaptureTier.HIGH)
        assertEquals(1152, profile.captureWidthPx)
        assertEquals(2560, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(60, profile.motionFps)
        assertEquals(12_000_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun lowTierProtectsLowRamDevicesWhileImprovingMotionModestly() {
        val profile = CaptureProfile.forDisplay(720, 1600, CaptureTier.LOW)
        assertEquals(324, profile.captureWidthPx)
        assertEquals(720, profile.captureHeightPx)
        assertEquals(15, profile.fps)
        assertEquals(20, profile.motionFps)
        assertEquals(1_200_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun everyTierMotionBudgetIsNeverBelowIdleBudget() {
        CaptureTier.entries.forEach { tier ->
            val profile = CaptureProfile.forDisplay(1080, 2400, tier)
            assertTrue(profile.motionFps >= profile.fps)
        }
    }

    companion object {
        private const val GIB = 1024L * 1024L * 1024L
    }
}
