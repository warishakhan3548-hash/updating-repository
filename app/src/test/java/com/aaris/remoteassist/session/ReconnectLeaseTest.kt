package com.aaris.remoteassist.session

import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.TapCommand
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Before
import org.junit.Test

class ReconnectLeaseTest {
    @Before
    fun setUp() {
        SessionCoordinator.reset()
        SessionCoordinator.prepareReady()
        SessionCoordinator.transition(
            "s1",
            SessionState.CODE_ACTIVE
        )
        SessionCoordinator.transition(
            "s1",
            SessionState.PAIR_PENDING
        )
        SessionCoordinator.transition(
            "s1",
            SessionState.HOST_APPROVED
        )
        SessionCoordinator.transition(
            "s1",
            SessionState.SCREEN_CONSENT
        )
        SessionCoordinator.transition(
            "s1",
            SessionState.CONNECTING
        )
    }

    @After
    fun tearDown() {
        SessionCoordinator.reset()
    }

    @Test
    fun reactivatingLiveResetsReplaySequenceForNewTransport() {
        val firstLease =
            SessionCoordinator.activateLive("s1")

        assertTrue(
            CommandGate.accept(
                TapCommand(
                    sessionId = "s1",
                    leaseSecret = firstLease.leaseSecret,
                    generation = firstLease.displayGeneration,
                    sequence = 42L,
                    xPx = 1f,
                    yPx = 1f
                )
            )
        )

        val reconnectLease =
            SessionCoordinator.activateLive("s1")

        assertTrue(
            CommandGate.accept(
                TapCommand(
                    sessionId = "s1",
                    leaseSecret = reconnectLease.leaseSecret,
                    generation = reconnectLease.displayGeneration,
                    sequence = 0L,
                    xPx = 1f,
                    yPx = 1f
                )
            )
        )
    }
}
