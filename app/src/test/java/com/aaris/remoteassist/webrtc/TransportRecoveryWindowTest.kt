package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.session.SessionRuntime
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class TransportRecoveryWindowTest {
    @After fun cleanUp() { SessionRuntime.reset() }

    @Test fun aTwentySecondHandoffKeepsItsRecoveryBudget() {
        val window = TransportRecoveryWindow()
        assertTrue(window.begin(1_000))
        assertEquals(40_000L, window.remainingMs(6_000))
        assertEquals(25_000L, window.remainingMs(21_000))
        window.recovered()
        assertNull(window.remainingMs(21_001))
    }

    @Test fun repeatedDisconnectCallbacksCannotKeepADeadPeerAliveForever() {
        val window = TransportRecoveryWindow()
        window.begin(0)
        for (now in 1L..44_000L step 1_000) assertFalse(window.begin(now))
        assertEquals(0L, window.remainingMs(45_000))
        assertFalse(window.begin(46_000))
        assertEquals(0L, window.remainingMs(60_000))
    }

    @Test fun aRecoveredSessionGetsAFreshBudgetForALaterHandoff() {
        val window = TransportRecoveryWindow()
        window.begin(0)
        window.recovered()
        assertTrue(window.begin(100_000))
        assertEquals(45_000L, window.remainingMs(100_000))
    }

    @Test fun keepingMediaAliveDoesNotRestoreAnExpiredInputLease() {
        val lease = SessionRuntime.activate("host", 7)
        SessionRuntime.reset()
        val window = TransportRecoveryWindow()
        window.begin(0)
        assertEquals(25_000L, window.remainingMs(20_000))
        assertFalse(SessionRuntime.isAuthorized("host", lease.leaseSecret, 7))
        assertNull(SessionRuntime.renew("host", lease.leaseSecret))
        val fresh = SessionRuntime.activate("host", 7)
        window.recovered()
        assertTrue(SessionRuntime.isAuthorized("host", fresh.leaseSecret, 7))
        assertFalse(SessionRuntime.isAuthorized("host", lease.leaseSecret, 7))
    }
}
