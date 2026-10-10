package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ScreenEncoderPerformanceTest {
    @Test
    fun reportedCodecRateIsQuantizedConservatively() {
        assertEquals(
            60,
            ScreenEncoderPerformance.cadenceAtOrBelow(60.0)
        )
        assertEquals(
            58,
            ScreenEncoderPerformance.cadenceAtOrBelow(59.94)
        )
        assertEquals(
            45,
            ScreenEncoderPerformance.cadenceAtOrBelow(47.9)
        )
        assertEquals(
            30,
            ScreenEncoderPerformance.cadenceAtOrBelow(32.8)
        )
        assertEquals(
            15,
            ScreenEncoderPerformance.cadenceAtOrBelow(15.9)
        )
    }

    @Test
    fun malformedOrMissingCodecRateDoesNotInventACeiling() {
        assertNull(
            ScreenEncoderPerformance.cadenceAtOrBelow(null)
        )
        assertNull(
            ScreenEncoderPerformance.cadenceAtOrBelow(Double.NaN)
        )
        assertNull(
            ScreenEncoderPerformance.cadenceAtOrBelow(Double.POSITIVE_INFINITY)
        )
        assertNull(
            ScreenEncoderPerformance.cadenceAtOrBelow(0.0)
        )
    }

    @Test
    fun subRealtimeVendorEstimateIsPreservedInsteadOfRoundedUp() {
        assertEquals(
            12,
            ScreenEncoderPerformance.cadenceAtOrBelow(12.9)
        )
    }
}
