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

    private fun StableCaptureGeometry.applyUpdate(
        profile: CaptureProfile,
        allowAdaptiveResize: Boolean
    ): Boolean {
        val plan = planUpdate(profile, allowAdaptiveResize)
        commit(plan)
        return plan.changed
    }

    @Test
    fun preAndroidTwelveKeepsProjectionStableAcrossAdaptiveVideoChanges() {
        val source = StableCaptureGeometry(native)
        repeat(30) {
            assertFalse(
                source.applyUpdate(
                    native.copy(fps = 60),
                    allowAdaptiveResize = false
                )
            )
            assertFalse(
                source.applyUpdate(
                    native.copy(
                        captureWidthPx = 324,
                        captureHeightPx = 720,
                        fps = 15
                    ),
                    allowAdaptiveResize = false
                )
            )
            assertFalse(
                source.applyUpdate(
                    native,
                    allowAdaptiveResize = false
                )
            )
            assertEquals(1080, source.width)
            assertEquals(2400, source.height)
        }
    }

    @Test
    fun legacyCadenceAndQualityUpdatesPreserveRoundedInitialDimensions() {
        val initial = CaptureProfile.forDisplay(1080, 2340, CaptureTier.BALANCED)
        val source = StableCaptureGeometry(initial)
        assertEquals(554, source.width)
        assertEquals(1200, source.height)

        repeat(3) {
            assertFalse(source.applyUpdate(initial.copy(fps = 30), allowAdaptiveResize = false))
            assertFalse(
                source.applyUpdate(
                    CaptureProfile.forDisplay(1080, 2340, CaptureTier.LOW),
                    allowAdaptiveResize = false
                )
            )
            assertFalse(source.applyUpdate(initial, allowAdaptiveResize = false))
            assertEquals(554, source.width)
            assertEquals(1200, source.height)
        }
    }

    @Test
    fun legacyRealDisplayResizeStillUsesTheOriginalProducerEnvelope() {
        val initial = CaptureProfile.forDisplay(1080, 2340, CaptureTier.BALANCED)
        val source = StableCaptureGeometry(initial)
        val resized = CaptureProfile.forDisplay(1440, 2560, CaptureTier.STANDARD)

        assertTrue(source.applyUpdate(resized, allowAdaptiveResize = false))
        assertEquals(674, source.width)
        assertEquals(1200, source.height)
        assertFalse(source.applyUpdate(resized.copy(fps = 60), allowAdaptiveResize = false))
        assertEquals(674, source.width)
        assertEquals(1200, source.height)
    }

    @Test
    fun androidTwelveAdaptiveEnvelopeTracksSpatialReliefButNotFpsOnlyChanges() {
        val source = StableCaptureGeometry(native)

        assertFalse(
            source.applyUpdate(
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
            source.applyUpdate(
                reduced,
                allowAdaptiveResize = true
            )
        )
        assertEquals(360, source.width)
        assertEquals(800, source.height)

        assertFalse(
            source.applyUpdate(
                reduced.copy(fps = 60),
                allowAdaptiveResize = true
            )
        )

        assertTrue(
            source.applyUpdate(
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
            source.applyUpdate(
                landscape,
                allowAdaptiveResize = false
            )
        )
        assertEquals(2400, source.width)
        assertEquals(1080, source.height)

        assertFalse(
            source.applyUpdate(
                landscape,
                allowAdaptiveResize = false
            )
        )

        assertTrue(
            source.applyUpdate(
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
            source.applyUpdate(
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
            source.applyUpdate(
                native,
                allowAdaptiveResize = true
            )
        )
        assertEquals(324, source.width)
        assertEquals(720, source.height)
    }
    @Test
    fun plannedResizeDoesNotMutateCommittedProducerUntilCommit() {
        val source = StableCaptureGeometry(native)
        val reduced =
            native.copy(
                captureWidthPx = 360,
                captureHeightPx = 800,
                fps = 30
            )

        val first = source.planUpdate(reduced, allowAdaptiveResize = true)

        assertTrue(first.changed)
        assertFalse(first.producerBeforeOutput)
        assertEquals(1080, source.width)
        assertEquals(2400, source.height)

        // Leaving a failed vendor transition uncommitted must make the exact
        // producer resize visible and retryable on the next policy pass.
        val retry = source.planUpdate(reduced, allowAdaptiveResize = true)
        assertTrue(retry.changed)
        assertEquals(first.width, retry.width)
        assertEquals(first.height, retry.height)

        source.commit(retry)
        assertEquals(360, source.width)
        assertEquals(800, source.height)
        assertFalse(
            source.planUpdate(reduced, allowAdaptiveResize = true).changed
        )
    }

    @Test
    fun spatialRecoverySuppliesProducerBeforeLargerOutputDemand() {
        val source = StableCaptureGeometry(native)
        source.applyUpdate(
            native.copy(
                captureWidthPx = 720,
                captureHeightPx = 1600
            ),
            allowAdaptiveResize = true
        )

        val recovery =
            source.planUpdate(
                native.copy(
                    captureWidthPx = 900,
                    captureHeightPx = 2000
                ),
                allowAdaptiveResize = true
            )

        assertTrue(recovery.changed)
        assertTrue(recovery.producerBeforeOutput)
        assertEquals(900, recovery.width)
        assertEquals(2000, recovery.height)
    }

    @Test
    fun equalAreaRotationSuppliesNewProducerGeometryBeforeOutputReshape() {
        val source = StableCaptureGeometry(native)
        val landscape =
            native.copy(
                displayWidthPx = 2400,
                displayHeightPx = 1080,
                captureWidthPx = 2400,
                captureHeightPx = 1080
            )

        val rotation =
            source.planUpdate(
                landscape,
                allowAdaptiveResize = true
            )

        assertTrue(rotation.changed)
        assertTrue(rotation.producerBeforeOutput)
        assertEquals(2400, rotation.width)
        assertEquals(1080, rotation.height)
    }

    @Test(expected = IllegalArgumentException::class)
    fun staleGeometryPlanCannotOverwriteANewerCommittedTransition() {
        val source = StableCaptureGeometry(native)
        val first =
            source.planUpdate(
                native.copy(
                    captureWidthPx = 720,
                    captureHeightPx = 1600
                ),
                allowAdaptiveResize = true
            )
        val stale =
            source.planUpdate(
                native.copy(
                    captureWidthPx = 900,
                    captureHeightPx = 2000
                ),
                allowAdaptiveResize = true
            )

        source.commit(first)
        source.commit(stale)
    }

}
