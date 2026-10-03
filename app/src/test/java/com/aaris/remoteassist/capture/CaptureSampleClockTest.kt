package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Test

class CaptureSampleClockTest {
    @Test fun staticTextureRequestsDoNotReuseAnOldAdaptationTimestamp() {
        val clock = CaptureSampleClock()
        assertEquals(100L, clock.timestamp(100, 120))
        assertEquals(500L, clock.timestamp(100, 500))
        assertEquals(540L, clock.timestamp(540, 550))
        assertEquals(700L, clock.timestamp(700, 720))
    }
}
