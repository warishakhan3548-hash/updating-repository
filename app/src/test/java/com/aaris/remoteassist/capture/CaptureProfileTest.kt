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
        assertEquals(6_800_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun standardPreservesMoreDetailOnModernTallPhone() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1080,
                displayHeightPx = 2400,
                tier = CaptureTier.STANDARD
            )

        assertEquals(972, profile.captureWidthPx)
        assertEquals(2160, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(6_800_000, profile.maxVideoBitrateBps)
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
        assertEquals(3_000_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun highTierKeepsFullModernPhoneGeometryWithinWebRtcCeiling() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1080,
                displayHeightPx = 2400,
                tier = CaptureTier.HIGH
            )

        assertEquals(1080, profile.captureWidthPx)
        assertEquals(2400, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(8_000_000, profile.maxVideoBitrateBps)
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
