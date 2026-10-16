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
    fun cpuLabelAloneDoesNotSacrificeCapturePixels() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.STANDARD,
                maxTier = CaptureTier.STANDARD
            )

        assertNull(
            governor.observeQualityLimitation("cpu")
        )
        assertEquals(
            CaptureTier.STANDARD,
            governor.currentTier()
        )
    }

    @Test
    fun cpuLabelWithHealthyMeasuredPipelineAllowsClarityRecovery() {
        val governor =
            CaptureQualityGovernor(
                initialTier = CaptureTier.BALANCED,
                maxTier = CaptureTier.STANDARD
            )

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(
                governor.observeQualityLimitation(
                    reason = "cpu",
                    roundTripTimeMs = 120,
                    packetLossRatio = 0.005,
                    encodeTimeMs = 5.0,
                    sendQueueMs = 2.0,
                    deliveredFps = 30.0,
                    requestedFps = 30,
                    outboundFrameCount = 30
                )
            )
        }

        assertEquals(
            CaptureTier.STANDARD,
            governor.observeQualityLimitation(
                reason = "cpu",
                roundTripTimeMs = 120,
                packetLossRatio = 0.005,
                encodeTimeMs = 5.0,
                sendQueueMs = 2.0,
                deliveredFps = 30.0,
                requestedFps = 30,
                outboundFrameCount = 30
            )
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
    fun alternatingQuietAndPopulatedHealthyBandwidthWindowsRecoverClarity() {
        val governor =
            CaptureQualityGovernor(CaptureTier.BALANCED, CaptureTier.STANDARD)

        // A 1 fps still-screen heartbeat sampled every 1.5 s alternates between
        // one quiet frame and two network-eligible frames.
        repeat(CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(observeHealthy(governor, "bandwidth", frames = 1 + it % 2))
        }
        assertEquals(CaptureTier.BALANCED, governor.currentTier())
        assertEquals(
            CaptureTier.STANDARD,
            observeHealthy(governor, "bandwidth", frames = 2)
        )
    }

    @Test
    fun alternatingHealthyLimitationLabelsShareTheLongerRecoveryWindow() {
        val governor =
            CaptureQualityGovernor(CaptureTier.BALANCED, CaptureTier.STANDARD)

        repeat(CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(
                observeHealthy(governor, if (it % 2 == 0) "none" else "bandwidth")
            )
        }
        assertEquals(CaptureTier.BALANCED, governor.currentTier())
        assertEquals(CaptureTier.STANDARD, observeHealthy(governor, "bandwidth"))
    }

    @Test
    fun sixConsecutiveStrictWindowsCanFinishAnEarlierBandwidthRecoverySequence() {
        val governor =
            CaptureQualityGovernor(CaptureTier.BALANCED, CaptureTier.STANDARD)

        assertNull(observeHealthy(governor, "bandwidth"))
        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(observeHealthy(governor))
        }
        assertEquals(CaptureTier.STANDARD, observeHealthy(governor))
    }

    @Test
    fun anUpgradeClearsBothRecoveryThresholdsBeforeTheNextTier() {
        val governor =
            CaptureQualityGovernor(CaptureTier.LOW, CaptureTier.HIGH)

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(observeHealthy(governor))
        }
        assertEquals(CaptureTier.BALANCED, observeHealthy(governor))

        repeat(CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(
                observeHealthy(governor, if (it % 2 == 0) "none" else "bandwidth")
            )
        }
        assertEquals(CaptureTier.STANDARD, observeHealthy(governor, "bandwidth"))

        repeat(CaptureQualityGovernor.UPGRADE_SAMPLE_COUNT - 1) {
            assertNull(observeHealthy(governor))
        }
        assertEquals(CaptureTier.HIGH, observeHealthy(governor))
    }

    @Test
    fun pressureAndAmbiguousWindowsRestartTheSharedRecoverySequence() {
        val interruptions: List<(CaptureQualityGovernor) -> CaptureTier?> =
            listOf(
                { it.observeQualityLimitation("none", 700, 0.01, outboundFrameCount = 30) },
                {
                    it.observeQualityLimitation(
                        "none",
                        120,
                        0.005,
                        sendQueueMs = 200.0,
                        outboundFrameCount = 30
                    )
                },
                { it.observeQualityLimitation("other", 120, 0.005, outboundFrameCount = 30) },
                { it.observeQualityLimitation(null, outboundFrameCount = 30) },
                { it.observeQualityLimitation("bandwidth", outboundFrameCount = 30) },
                { it.observeQualityLimitation("none", 500, 0.03, outboundFrameCount = 30) }
            )

        interruptions.forEachIndexed { index, interrupt ->
            val governor =
                CaptureQualityGovernor(CaptureTier.BALANCED, CaptureTier.STANDARD)
            repeat(CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1) {
                assertNull(observeHealthy(governor, if (it % 2 == 0) "none" else "bandwidth"))
            }
            assertNull("interruption $index", interrupt(governor))
            repeat(CaptureQualityGovernor.BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT - 1) {
                assertNull(
                    "recovery after interruption $index, sample $it",
                    observeHealthy(governor, if (it % 2 == 0) "none" else "bandwidth")
                )
            }
            assertEquals(
                "recovery after interruption $index",
                CaptureTier.STANDARD,
                observeHealthy(governor, "bandwidth")
            )
        }
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

    private fun observeHealthy(
        governor: CaptureQualityGovernor,
        reason: String = "none",
        frames: Int = 30
    ): CaptureTier? =
        governor.observeQualityLimitation(
            reason = reason,
            roundTripTimeMs = 120,
            packetLossRatio = 0.005,
            encodeTimeMs = 4.0,
            sendQueueMs = 2.0,
            deliveredFps = frames / 1.5,
            requestedFps = 30,
            outboundFrameCount = frames
        )
}
