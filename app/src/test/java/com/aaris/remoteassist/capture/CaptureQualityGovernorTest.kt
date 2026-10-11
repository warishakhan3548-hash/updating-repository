package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CaptureQualityGovernorTest {
    @Test
    fun healthyBandwidthReasonDoesNotSacrificeResolution() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        repeat(
            CaptureQualityGovernor.BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT + 2
        ) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "bandwidth",
                    roundTripTimeMs = 150,
                    packetLossRatio = 0.005
                )
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun bandwidthWithoutTelemetryUsesLongerFallbackHysteresis() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        repeat(
            CaptureQualityGovernor.BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "bandwidth"
                )
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "bandwidth"
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.currentTier()
        )
    }

    @Test
    fun bandwidthWithRealNetworkPressureUsesNormalHysteresis() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 700,
                packetLossRatio = 0.01
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 710,
                packetLossRatio = 0.01
            )
        )
    }

    @Test
    fun cpuPressureDowngradesImmediatelyToProtectFramePacing() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation("cpu")
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
    fun quietRtpWindowCannotRepeatStaleNetworkOrCpuDowngrades() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        repeat(6) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "cpu",
                    roundTripTimeMs = 950,
                    packetLossRatio = 0.14,
                    outboundFrameCount = it % 2
                )
            )
        }
        assertEquals(CaptureTier.STANDARD, governor.currentTier())

        // A current moving interval still receives urgent loss relief.
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 180,
                packetLossRatio = 0.14,
                outboundFrameCount = 2
            )
        )
    }

    @Test
    fun quietIntervalBreaksOldNetworkPressureStreak() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 700,
                outboundFrameCount = 2
            )
        )
        assertNull(
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 700,
                outboundFrameCount = 0
            )
        )
        assertNull(
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 700,
                outboundFrameCount = 2
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 700,
                outboundFrameCount = 2
            )
        )
    }

    @Test
    fun quietSourceRecoversClarityDespiteStaleRemotePressure() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.BALANCED,
                maxTier = CaptureTier.STANDARD
            )

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = if (it % 2 == 0) "cpu" else "bandwidth",
                    roundTripTimeMs = 950,
                    packetLossRatio = 0.14,
                    outboundFrameCount = it % 2
                )
            )
        }
        assertEquals(
            CaptureTier.STANDARD,
            governor.observeQualityLimitation(
                reason = "cpu",
                roundTripTimeMs = 950,
                packetLossRatio = 0.14,
                outboundFrameCount = 0
            )
        )
    }

    @Test
    fun quietSourceStillHonorsMeasuredLocalPipelinePressure() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "cpu",
                encodeTimeMs = 40.0,
                deliveredFps = 3.0,
                requestedFps = 30,
                outboundFrameCount = 0
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "cpu",
                encodeTimeMs = 40.0,
                deliveredFps = 3.0,
                requestedFps = 30,
                outboundFrameCount = 0
            )
        )
    }

    @Test
    fun isolatedSevereRttSpikeDoesNotBlurCaptureImmediately() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 950,
                packetLossRatio = 0.0
            )
        )
        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 140,
                packetLossRatio = 0.0
            )
        )
        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun sustainedSevereRttStillDowngradesAfterHysteresis() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 950,
                packetLossRatio = 0.0
            )
        )
        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = "none",
                roundTripTimeMs = 980,
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
    fun nullReasonWithHealthyTelemetryRestoresVendorQuality() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.LOW,
                maxTier = CaptureTier.STANDARD
            )

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = null,
                    roundTripTimeMs = 125,
                    packetLossRatio = 0.004
                )
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation(
                reason = null,
                roundTripTimeMs = 125,
                packetLossRatio = 0.004
            )
        )
    }

    @Test
    fun healthyBandwidthProbesHigherTierSlowly() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.BALANCED,
                maxTier = CaptureTier.STANDARD
            )

        repeat(
            CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "bandwidth",
                    roundTripTimeMs = 130,
                    packetLossRatio = 0.004
                )
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.observeQualityLimitation(
                reason = "bandwidth",
                roundTripTimeMs = 130,
                packetLossRatio = 0.004
            )
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
    fun unknownReasonResetsBandwidthOnlyPressureStreak() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation("bandwidth")
        )
        assertNull(
            governor.observeQualityLimitation("other")
        )

        repeat(
            CaptureQualityGovernor.BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT - 1
        ) {
            assertNull(
                governor.observeQualityLimitation("bandwidth")
            )
        }

        assertEquals(
            CaptureTier.BALANCED,
            governor.observeQualityLimitation("bandwidth")
        )
    }
}
