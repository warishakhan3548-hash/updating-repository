package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Test

class InboundVideoLivenessMonitorTest {
    private val none = InboundVideoLivenessAction.NONE
    private val repair = InboundVideoLivenessAction.REQUEST_RECOVERY
    private val resumed = InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED

    @Test
    fun healthyDecodeProgressAtDifferentSamplingRatesNeverRequestsRecovery() {
        val monitor = InboundVideoLivenessMonitor()
        assertEquals(none, monitor.observe(100, 100, 0))
        assertEquals(none, monitor.observe(120, 120, 100))
        assertEquals(none, monitor.observe(140, 140, 600))
        assertEquals(none, monitor.observe(180, 180, 2_100))
        assertEquals(none, monitor.observe(200, 200, 4_100))
    }

    @Test
    fun progressingRtpWithFrozenDecoderRecoversByElapsedTime() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        assertEquals(none, monitor.observe(120, 100, 500))
        assertEquals(none, monitor.observe(140, 100, 1_000))
        assertEquals(none, monitor.observe(160, 100, 2_900))
        assertEquals(repair, monitor.observe(180, 100, 3_000))
        assertEquals(none, monitor.observe(200, 100, 3_500))
    }

    @Test
    fun veryShortStatsProbesCannotAccelerateDecoderStallTimeout() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        for (time in 100L..2_400L step 100L) {
            assertEquals(none, monitor.observe(100 + time / 100, 100, time))
        }
        assertEquals(repair, monitor.observe(130, 100, 2_600))
    }

    @Test
    fun oneNetworkGapClearsAccumulatedDecoderOnlyEvidence() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        assertEquals(none, monitor.observe(120, 100, 500))
        assertEquals(none, monitor.observe(120, 100, 1_500))
        assertEquals(none, monitor.observe(140, 100, 2_500))
        assertEquals(none, monitor.observe(160, 100, 4_900))
        assertEquals(repair, monitor.observe(180, 100, 5_000))
    }

    @Test
    fun staticOrNetworkQuietScreenUsesLongerDeadline() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        assertEquals(none, monitor.observe(100, 100, 1_000))
        assertEquals(none, monitor.observe(100, 100, 6_500))
        assertEquals(none, monitor.observe(100, 100, 12_999))
        assertEquals(repair, monitor.observe(100, 100, 13_000))
    }

    @Test
    fun noDecodedFramesAtStartupCannotTriggerFallback() {
        val monitor = InboundVideoLivenessMonitor()
        assertEquals(none, monitor.observe(0, 0, 0))
        assertEquals(none, monitor.observe(300, 0, 5_000))
        assertEquals(none, monitor.observe(400, 0, 20_000))
        assertEquals(none, monitor.observe(450, 300, 21_000))
    }

    @Test
    fun continuousStartupRtpWithZeroDecodedFramesTriggersBoundedRecovery() {
        val monitor = InboundVideoLivenessMonitor()
        assertEquals(none, monitor.observe(0, 0, 0))
        assertEquals(none, monitor.observe(10, 0, 500))
        assertEquals(none, monitor.observe(40, 0, 2_000))
        assertEquals(none, monitor.observe(70, 0, 4_000))
        assertEquals(repair, monitor.observe(90, 0, 5_500))
        // No additional repair storms after a successful request.
        assertEquals(none, monitor.observe(95, 0, 6_000))
        assertEquals(none, monitor.observe(110, 0, 9_499))
        assertEquals(repair, monitor.observe(120, 0, 9_500))
        assertEquals(none, monitor.observe(140, 0, 30_000))
        // Decoder progress is not proof of EGL: wait for glass confirmation.
        assertEquals(resumed, monitor.observe(145, 5, 30_500))
        monitor.markPrimaryRecoveredConfirmed()
        assertEquals(none, monitor.observe(150, 10, 31_000))
    }

    @Test
    fun oneStartupRtpBurstCannotFalselyDiagnoseDecoderStall() {
        val monitor = InboundVideoLivenessMonitor()
        assertEquals(none, monitor.observe(0, 0, 0))
        assertEquals(none, monitor.observe(12, 0, 500))
        // No additional RTP: the decoder's first picture cannot be expected.
        assertEquals(none, monitor.observe(12, 0, 2_000))
        assertEquals(none, monitor.observe(12, 0, 9_000))
        assertEquals(none, monitor.observe(12, 0, 25_000))
    }

    @Test
    fun missingStartupStatsWindowMustNotManufactureContinuousRtp() {
        val monitor = InboundVideoLivenessMonitor()
        assertEquals(none, monitor.observe(0, 0, 0))
        assertEquals(none, monitor.observe(5, 0, 500))
        assertEquals(none, monitor.observe(10, 0, 2_000))
        // Even growing cumulative counters cannot prove a continuous decoder
        // stall across a 12-second telemetry outage.
        assertEquals(none, monitor.observe(90, 0, 14_000))
        assertEquals(none, monitor.observe(100, 0, 15_500))
        assertEquals(none, monitor.observe(110, 0, 17_000))
        assertEquals(repair, monitor.observe(120, 0, 19_000))
    }

    @Test
    fun decoderResumeNeedsGlassConfirmationAndThenStopsRepeating() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        assertEquals(resumed, monitor.observe(150, 110, 3_500))
        assertEquals(resumed, monitor.observe(160, 120, 4_000))
        monitor.markPrimaryRecoveredConfirmed()
        assertEquals(none, monitor.observe(170, 130, 4_500))
    }

    @Test
    fun failedRecoveryRequestHasCooldownAndMayRetry() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        monitor.markRecoveryRequestFailed()
        assertEquals(none, monitor.observe(150, 100, 3_500))
        assertEquals(none, monitor.observe(160, 100, 6_999))
        assertEquals(repair, monitor.observe(180, 100, 7_000))
    }

    @Test
    fun successfulRequestWithoutDecoderProgressGetsOneBoundedRetry() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        assertEquals(none, monitor.observe(120, 100, 500))
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        // A control-channel send succeeded; the codec never recovered.
        assertEquals(none, monitor.observe(160, 100, 6_999))
        assertEquals(repair, monitor.observe(180, 100, 7_000))
        // Additional stats must not cause an unbounded restart loop.
        assertEquals(none, monitor.observe(200, 100, 11_000))
        assertEquals(none, monitor.observe(220, 100, 30_000))
    }

    @Test
    fun quietTransportAfterAcceptedRequestAlsoGetsBoundedRetry() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        assertEquals(none, monitor.observe(140, 100, 3_500))
        assertEquals(none, monitor.observe(140, 100, 15_499))
        assertEquals(repair, monitor.observe(140, 100, 15_500))
        assertEquals(none, monitor.observe(140, 100, 30_000))
    }

    @Test
    fun realGlassConfirmationRenewsRecoveryBudgetForLaterFreeze() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        assertEquals(repair, monitor.observe(160, 100, 7_000))
        monitor.markPrimaryRecoveredConfirmed()
        assertEquals(none, monitor.observe(170, 110, 8_000))
        assertEquals(none, monitor.observe(190, 110, 8_500))
        assertEquals(repair, monitor.observe(220, 110, 11_000))
    }

    @Test
    fun healthyDecoderAfterRecoveryDoesNotLoopWhileWaitingForGlass() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(repair, monitor.observe(140, 100, 3_000))
        assertEquals(resumed, monitor.observe(150, 110, 3_500))
        assertEquals(resumed, monitor.observe(200, 160, 8_000))
        assertEquals(resumed, monitor.observe(250, 210, 20_000))
    }

    @Test
    fun counterResetAndClockRollbackClearStaleEvidence() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        monitor.observe(120, 100, 500)
        assertEquals(none, monitor.observe(3, 2, 2_900))
        assertEquals(none, monitor.observe(4, 2, 3_000))
        assertEquals(none, monitor.observe(5, 2, 100))
        assertEquals(none, monitor.observe(6, 3, 500))
    }

    @Test
    fun invalidSamplesDoNotAccumulateOrDamageKnownCounterBaseline() {
        val monitor = InboundVideoLivenessMonitor()
        monitor.observe(100, 100, 0)
        assertEquals(none, monitor.observe(-1, 100, 500))
        assertEquals(none, monitor.observe(120, 100, 1_000))
        assertEquals(none, monitor.observe(130, 100, 3_000))
        assertEquals(repair, monitor.observe(140, 100, 3_500))
    }
}
