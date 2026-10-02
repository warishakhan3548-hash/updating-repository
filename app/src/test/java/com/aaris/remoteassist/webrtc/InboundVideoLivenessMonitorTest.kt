package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Test

class InboundVideoLivenessMonitorTest {
    @Test
    fun healthyDecodedProgressNeverRequestsRecovery() {
        val monitor = InboundVideoLivenessMonitor()

        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(100, 100)
        )
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(120, 120)
        )
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(140, 140)
        )
    }

    @Test
    fun decoderStallRecoversFasterWhenPacketsStillAdvance() {
        val monitor = InboundVideoLivenessMonitor(
            stagnantScoreBeforeRecovery = 4
        )

        monitor.observe(100, 100)
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(120, 100)
        )
        assertEquals(
            InboundVideoLivenessAction.REQUEST_RECOVERY,
            monitor.observe(140, 100)
        )
    }

    @Test
    fun fullMediaStallUsesLongerHysteresis() {
        val monitor = InboundVideoLivenessMonitor(
            stagnantScoreBeforeRecovery = 4
        )

        monitor.observe(100, 100)
        repeat(3) {
            assertEquals(
                InboundVideoLivenessAction.NONE,
                monitor.observe(100, 100)
            )
        }
        assertEquals(
            InboundVideoLivenessAction.REQUEST_RECOVERY,
            monitor.observe(100, 100)
        )
    }

    @Test
    fun resumedDecodeRequestsPrimaryConfirmationUntilConfirmed() {
        val monitor = InboundVideoLivenessMonitor(
            stagnantScoreBeforeRecovery = 2
        )

        monitor.observe(100, 100)
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(100, 100)
        )
        assertEquals(
            InboundVideoLivenessAction.REQUEST_RECOVERY,
            monitor.observe(100, 100)
        )
        assertEquals(
            InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED,
            monitor.observe(101, 101)
        )
        assertEquals(
            InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED,
            monitor.observe(102, 102)
        )

        monitor.markPrimaryRecoveredConfirmed()
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(103, 103)
        )
    }

    @Test
    fun failedRecoveryRequestCanRetry() {
        val monitor = InboundVideoLivenessMonitor(
            stagnantScoreBeforeRecovery = 2
        )

        monitor.observe(100, 100)
        monitor.observe(100, 100)
        assertEquals(
            InboundVideoLivenessAction.REQUEST_RECOVERY,
            monitor.observe(100, 100)
        )
        monitor.markRecoveryRequestFailed()

        assertEquals(
            InboundVideoLivenessAction.REQUEST_RECOVERY,
            monitor.observe(100, 100)
        )
    }

    @Test
    fun counterResetStartsANewGenerationWithoutFalseRecovery() {
        val monitor = InboundVideoLivenessMonitor(
            stagnantScoreBeforeRecovery = 2
        )

        monitor.observe(100, 100)
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(3, 2)
        )
        assertEquals(
            InboundVideoLivenessAction.NONE,
            monitor.observe(4, 3)
        )
    }
}
