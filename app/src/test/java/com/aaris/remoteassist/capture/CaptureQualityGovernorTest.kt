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
    fun severePacketLossDowngradesImmediately() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 180,
                packetLossRatio = 0.14
            )
        )
    }

    @Test
    fun severeRttDowngradesImmediately() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 950,
                packetLossRatio = 0.0
            )
        )
    }

    @Test
    fun moderateNetworkPressureStillUsesHysteresis() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 700,
                packetLossRatio = 0.01
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 700,
                packetLossRatio = 0.01
            )
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
                governor.observeQualityLimitation(
                    reason = "none",
                    roundTripTimeMs = 120,
                    packetLossRatio = 0.005
                )
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 120,
                packetLossRatio = 0.005
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.currentTier()
        )

        repeat(
            CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "none",
                    roundTripTimeMs = 120,
                    packetLossRatio = 0.005
                )
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 120,
                packetLossRatio = 0.005
            )
        )
        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun healthyReasonWithBadTelemetryDoesNotRecover() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.BALANCED,
                maxTier = CaptureTier.STANDARD
            )

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT) {
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 500,
                packetLossRatio = 0.03
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
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
                governor.observeQualityLimitation(
                    reason = "none",
                    roundTripTimeMs = 100,
                    packetLossRatio = 0.0
                )
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
