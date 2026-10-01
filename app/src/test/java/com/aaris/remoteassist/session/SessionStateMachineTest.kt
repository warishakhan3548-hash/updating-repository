package com.aaris.remoteassist.session

import org.junit.Assert.assertEquals
import org.junit.Test

class SessionStateMachineTest {
    @Test fun happyPathReachesLive() {
        val machine = SessionStateMachine()
        machine.transition(null, SessionState.READY, 1)
        machine.transition("s1", SessionState.CODE_ACTIVE, 2)
        machine.transition("s1", SessionState.PAIR_PENDING, 3)
        machine.transition("s1", SessionState.HOST_APPROVED, 4)
        machine.transition("s1", SessionState.SCREEN_CONSENT, 5)
        machine.transition("s1", SessionState.CONNECTING, 6)
        machine.transition("s1", SessionState.LIVE, 7)
        assertEquals(SessionState.LIVE, machine.snapshot().state)
    }

    @Test(expected = IllegalArgumentException::class)
    fun illegalJumpFailsClosed() {
        val machine = SessionStateMachine()
        machine.transition("s1", SessionState.LIVE, 1)
    }

    @Test(expected = IllegalArgumentException::class)
    fun closedSessionCannotBeRevived() {
        val machine = SessionStateMachine()
        machine.transition(null, SessionState.READY, 1)
        machine.transition("s1", SessionState.CODE_ACTIVE, 2)
        machine.transition("s1", SessionState.CLOSED, 3)
        machine.transition("s1", SessionState.READY, 4)
    }

    @Test(expected = IllegalArgumentException::class)
    fun sessionIdentityCannotChangeMidFlow() {
        val machine = SessionStateMachine()
        machine.transition(null, SessionState.READY, 1)
        machine.transition("s1", SessionState.CODE_ACTIVE, 2)
        machine.transition("s2", SessionState.PAIR_PENDING, 3)
    }
}
