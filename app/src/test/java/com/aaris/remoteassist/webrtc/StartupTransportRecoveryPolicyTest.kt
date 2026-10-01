package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class StartupTransportRecoveryPolicyTest {
    @Test
    fun recoversPeerConnectedWithoutControlChannel() {
        assertTrue(
            StartupTransportRecoveryPolicy.shouldAttempt(
                peerConnected = true,
                controlChannelOpen = false,
                transportReady = false,
                completedAttempts = 0,
                maxAttempts = 2
            )
        )
    }

    @Test
    fun doesNotRecoverBeforePeerConnectivity() {
        assertFalse(
            StartupTransportRecoveryPolicy.shouldAttempt(
                peerConnected = false,
                controlChannelOpen = false,
                transportReady = false,
                completedAttempts = 0,
                maxAttempts = 2
            )
        )
    }

    @Test
    fun stopsRecoveryWhenControlChannelOpens() {
        assertFalse(
            StartupTransportRecoveryPolicy.shouldAttempt(
                peerConnected = true,
                controlChannelOpen = true,
                transportReady = false,
                completedAttempts = 0,
                maxAttempts = 2
            )
        )
    }

    @Test
    fun stopsAtBoundedRetryBudget() {
        assertFalse(
            StartupTransportRecoveryPolicy.shouldAttempt(
                peerConnected = true,
                controlChannelOpen = false,
                transportReady = false,
                completedAttempts = 2,
                maxAttempts = 2
            )
        )
    }

    @Test
    fun relayEscalationStartsOnlyAfterFirstRetry() {
        assertFalse(
            StartupTransportRecoveryPolicy.shouldForceRelay(0)
        )
        assertTrue(
            StartupTransportRecoveryPolicy.shouldForceRelay(1)
        )
    }
}
