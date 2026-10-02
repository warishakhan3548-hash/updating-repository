package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CaptureQualityGovernorTest {
    @Test
    fun persistentPressureDowngradesOnlyAfterHysteresis() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation("bandwidth")
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation("bandwidth")
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.currentTier()
        )
    }

    @Test
    fun healthySamplesRestoreQualitySlowly() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.LOW,
                maxTier = CaptureTier.STANDARD
            )

        repeat(
            CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation("none")
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation("none")
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.currentTier()
        )

        repeat(
            CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation("none")
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.observeQualityLimitation("none")
        )
        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun recoveryNeverExceedsDeviceMaximum() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT) {
            assertNull(
                governor.observeQualityLimitation("none")
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun unknownReasonResetsPressureStreak() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation("cpu")
        )
        assertNull(
            governor.observeQualityLimitation("other")
        )
        assertNull(
            governor.observeQualityLimitation("cpu")
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation("cpu")
        )
    }
}
