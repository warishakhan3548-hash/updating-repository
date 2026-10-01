package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class BootstrapRecoveryPolicyTest {
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
