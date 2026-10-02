package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureProfileTest {
    @Test
    fun standardKeepsNative1600pLongSide() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 720,
                displayHeightPx = 1600,
                tier = CaptureTier.STANDARD
            )

        assertEquals(720, profile.captureWidthPx)
        assertEquals(1600, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(5_200_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun standardDownscalesLargePhoneWithoutBlurringTo960p() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1080,
                displayHeightPx = 2400,
                tier = CaptureTier.STANDARD
            )

        assertEquals(864, profile.captureWidthPx)
        assertEquals(1920, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(5_200_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun balancedTierAvoidsHarshQualityCliff() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1080,
                displayHeightPx = 2400,
                tier = CaptureTier.BALANCED
            )

        assertEquals(540, profile.captureWidthPx)
        assertEquals(1200, profile.captureHeightPx)
        assertEquals(24, profile.fps)
        assertEquals(2_800_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun lowTierProtectsLowRamDevices() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 720,
                displayHeightPx = 1600,
                tier = CaptureTier.LOW
            )

        assertEquals(324, profile.captureWidthPx)
        assertEquals(720, profile.captureHeightPx)
        assertEquals(15, profile.fps)
        assertEquals(1_200_000, profile.maxVideoBitrateBps)
    }
}
