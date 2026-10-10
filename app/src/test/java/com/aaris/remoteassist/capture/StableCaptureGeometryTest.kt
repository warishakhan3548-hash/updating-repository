package com.aaris.remoteassist.capture

import org.junit.Assert.*
import org.junit.Test

class StableCaptureGeometryTest {
    private val native =
        CaptureProfile(
            1080,
            2400,
            1080,
            2400,
            30,
            10_000_000,
            CaptureTier.STANDARD,
            60
        )

    @Test
    fun preAndroidTwelveKeepsProjectionStableAcrossAdaptiveVideoChanges() {
        val source = StableCaptureGeometry(native)
        repeat(30) {
            assertFalse(
                source.update(
                    native.copy(fps = 60),
                    allowAdaptiveResize = false
                )
            )
            assertFalse(
                source.update(
                    native.copy(
                        captureWidthPx = 324,
                        captureHeightPx = 720,
                        fps = 15
                    ),
                    allowAdaptiveResize = false
                )
            )
            assertFalse(
                source.update(
                    native,
                    allowAdaptiveResize = false
                )
            )
            assertEquals(1080, source.width)
            assertEquals(2400, source.height)
        }
    }

    @Test
    fun androidTwelveAdaptiveEnvelopeTracksSpatialReliefButNotFpsOnlyChanges() {
        val source = StableCaptureGeometry(native)

        assertFalse(
            source.update(
                native.copy(fps = 60),
                allowAdaptiveResize = true
            )
        )

        val reduced =
            native.copy(
                captureWidthPx = 360,
                captureHeightPx = 800,
                fps = 30
            )
        assertTrue(
            source.update(
                reduced,
                allowAdaptiveResize = true
            )
        )
        assertEquals(360, source.width)
        assertEquals(800, source.height)

        assertFalse(
            source.update(
                reduced.copy(fps = 60),
                allowAdaptiveResize = true
            )
        )

        assertTrue(
            source.update(
                native,
                allowAdaptiveResize = true
            )
        )
        assertEquals(1080, source.width)
        assertEquals(2400, source.height)
    }

    @Test
    fun realRotationResizesOnceWithoutUsingDegradedNetworkDimensionsOnLegacyPath() {
        val source = StableCaptureGeometry(native)
        val landscape =
            native.copy(
                displayWidthPx = 2400,
                displayHeightPx = 1080,
                captureWidthPx = 720,
                captureHeightPx = 324
            )

        assertTrue(
            source.update(
                landscape,
                allowAdaptiveResize = false
            )
        )
        assertEquals(2400, source.width)
        assertEquals(1080, source.height)

        assertFalse(
            source.update(
                landscape,
                allowAdaptiveResize = false
            )
        )

        assertTrue(
            source.update(
                native,
                allowAdaptiveResize = false
            )
        )
        assertEquals(1080, source.width)
        assertEquals(2400, source.height)
    }

    @Test
    fun lowMemorySourceKeepsItsOriginalPixelBudgetAfterRotation() {
        val source =
            StableCaptureGeometry(
                native.copy(
                    captureWidthPx = 324,
                    captureHeightPx = 720
                )
            )

        assertTrue(
            source.update(
                native.copy(
                    displayWidthPx = 2400,
                    displayHeightPx = 1080
                ),
                allowAdaptiveResize = false
            )
        )
        assertEquals(720, source.width)
        assertEquals(324, source.height)
    }

    @Test
    fun adaptiveResizeNeverExceedsTheOriginalProducerBudget() {
        val low =
            native.copy(
                captureWidthPx = 324,
                captureHeightPx = 720
            )
        val source = StableCaptureGeometry(low)

        assertFalse(
            source.update(
                native,
                allowAdaptiveResize = true
            )
        )
        assertEquals(324, source.width)
        assertEquals(720, source.height)
    }
}
