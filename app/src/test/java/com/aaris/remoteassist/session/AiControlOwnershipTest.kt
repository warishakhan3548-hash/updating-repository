package com.aaris.remoteassist.session

import org.junit.Assert.*
import org.junit.After
import org.junit.Test

class AiControlOwnershipTest {
    @After fun cleanup() { SessionCoordinator.releaseAi("ai:test"); SessionCoordinator.reset() }
    @Test fun humanSessionCannotOverwriteAiAuthorityOrResetItsLease() {
        SessionCoordinator.reset()
        assertTrue(SessionCoordinator.reserveAi("ai:test"))
        val lease = SessionCoordinator.activateAi("ai:test")
        SessionCoordinator.close("human:stale")
        SessionCoordinator.reset()
        assertEquals(lease.leaseSecret, SessionRuntime.currentLease()?.leaseSecret)
        assertFalse(runCatching { SessionCoordinator.transition("human:new", SessionState.CODE_ACTIVE) }.isSuccess)
        SessionCoordinator.suspendAi("ai:test")
        assertNull(SessionRuntime.currentLease())
        assertTrue(SessionCoordinator.isAiReserved())
        SessionCoordinator.releaseAi("ai:test")
        assertFalse(SessionCoordinator.isAiReserved())
    }
    @Test fun activeHumanPairingPreventsAiReservation() {
        SessionCoordinator.reset(); SessionCoordinator.prepareReady()
        SessionCoordinator.transition("human", SessionState.CODE_ACTIVE)
        assertFalse(SessionCoordinator.reserveAi("ai:test"))
    }
}
