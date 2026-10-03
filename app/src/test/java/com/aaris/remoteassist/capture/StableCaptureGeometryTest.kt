package com.aaris.remoteassist.capture

import org.junit.Assert.*
import org.junit.Test

class StableCaptureGeometryTest {
    private val native = CaptureProfile(1080, 2400, 1080, 2400, 30, 10_000_000, CaptureTier.STANDARD, 60)

    @Test fun cadenceAndNetworkQualityNeverResizeTheProjection() {
        val source = StableCaptureGeometry(native)
        repeat(30) {
            assertFalse(source.updateDisplay(native.copy(fps = 60)))
            assertFalse(source.updateDisplay(native.copy(captureWidthPx = 324, captureHeightPx = 720, fps = 15)))
            assertFalse(source.updateDisplay(native))
            assertEquals(1080, source.width); assertEquals(2400, source.height)
        }
    }

    @Test fun realRotationResizesOnceWithoutUsingTheDegradedNetworkDimensions() {
        val source = StableCaptureGeometry(native)
        val landscape = native.copy(displayWidthPx = 2400, displayHeightPx = 1080, captureWidthPx = 720, captureHeightPx = 324)
        assertTrue(source.updateDisplay(landscape))
        assertEquals(2400, source.width); assertEquals(1080, source.height)
        assertFalse(source.updateDisplay(landscape))
        assertTrue(source.updateDisplay(native))
        assertEquals(1080, source.width); assertEquals(2400, source.height)
    }

    @Test fun lowMemorySourceKeepsItsOriginalPixelBudgetAfterRotation() {
        val source = StableCaptureGeometry(native.copy(captureWidthPx = 324, captureHeightPx = 720))
        assertTrue(source.updateDisplay(native.copy(displayWidthPx = 2400, displayHeightPx = 1080)))
        assertEquals(720, source.width); assertEquals(324, source.height)
    }
}
