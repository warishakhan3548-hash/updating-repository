package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BootstrapRecoveryPolicyTest {
    @Test
    fun offerRedeliveryUsesBoundedBackoff() {
        assertEquals(
            5_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(1)
        )
        assertEquals(
            8_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(2)
        )
        assertEquals(
            12_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(3)
        )
        assertEquals(
            20_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(4)
        )
        assertEquals(
            30_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(5)
        )
        assertEquals(
            30_000L,
            BootstrapRecoveryPolicy.offerRedeliveryDelayMs(99)
        )
    }

    @Test
    fun noAppliedAnswerDoesNotBlockRecovery() {
        assertFalse(
            BootstrapRecoveryPolicy.shouldWaitAfterRemoteAnswer(
                lastRemoteAnswerAppliedAtMs = 0L,
                nowMs = 10_000L,
                settleWindowMs = 6_000L
            )
        )
    }

    @Test
    fun freshAnswerGetsFullIceSettlingWindow() {
        assertTrue(
            BootstrapRecoveryPolicy.shouldWaitAfterRemoteAnswer(
                lastRemoteAnswerAppliedAtMs = 10_000L,
                nowMs = 15_999L,
                settleWindowMs = 6_000L
            )
        )
    }

    @Test
    fun expiredSettlingWindowAllowsRecovery() {
        assertFalse(
            BootstrapRecoveryPolicy.shouldWaitAfterRemoteAnswer(
                lastRemoteAnswerAppliedAtMs = 10_000L,
                nowMs = 16_000L,
                settleWindowMs = 6_000L
            )
        )
    }

    @Test
    fun monotonicClockRegressionWaitsConservatively() {
        assertTrue(
            BootstrapRecoveryPolicy.shouldWaitAfterRemoteAnswer(
                lastRemoteAnswerAppliedAtMs = 10_000L,
                nowMs = 9_000L,
                settleWindowMs = 6_000L
            )
        )
    }
}
