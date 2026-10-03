package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
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
        assertEquals(
            CaptureTier.LOW,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = false,
                totalMemoryBytes = 2L * GIB
            )
        )
        assertEquals(
            CaptureTier.LOW,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = false,
                totalMemoryBytes = 3L * GIB
            )
        )
    }

    @Test
    fun fourGigabyteClassUsesNativeDetailStandardTier() {
        assertEquals(
            CaptureTier.STANDARD,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = false,
                totalMemoryBytes = 4L * GIB
            )
        )
    }

    @Test
    fun sixGigabyteAndAboveUsesHighTier() {
        assertEquals(
            CaptureTier.HIGH,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = false,
                totalMemoryBytes = 6L * GIB
            )
        )
    }

    @Test
    fun unknownMemoryFailsSafeToBalanced() {
        assertEquals(
            CaptureTier.BALANCED,
            CaptureProfile.recommendedTierForDevice(
                isLowRamDevice = false,
                totalMemoryBytes = 0L
            )
        )
    }

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
        assertEquals(7_200_000, profile.maxVideoBitrateBps)
    }

    @Test
    fun standardKeepsNativeModernTallPhoneDetail() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1080,
                displayHeightPx = 2400,
                tier = CaptureTier.STANDARD
            )

        assertEquals(1080, profile.captureWidthPx)
        assertEquals(2400, profile.captureHeightPx)
        assertEquals(30, profile.fps)
        assertEquals(7_200_000, profile.maxVideoBitrateBps)
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
    fun highTierPreservesExtraDetailOnQhdClassPhone() {
        val profile =
            CaptureProfile.forDisplay(
                displayWidthPx = 1440,
                displayHeightPx = 3200,
                tier = CaptureTier.HIGH
            )

        assertEquals(1152, profile.captureWidthPx)
        assertEquals(2560, profile.captureHeightPx)
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

    companion object {
        private const val GIB = 1024L * 1024L * 1024L
    }
}
