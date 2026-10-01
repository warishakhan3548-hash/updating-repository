package com.aaris.remoteassist.session

import org.junit.Assert.assertEquals
import org.junit.Test

class HostBackendStateSyncTest {
    @Test
    fun hostApprovedCallbackAdvancesPendingLocalState() {
        assertEquals(
            listOf(SessionState.HOST_APPROVED),
            HostBackendStateSync.forwardTransitions(
                SessionState.PAIR_PENDING,
                "HOST_APPROVED"
            )
        )
    }

    @Test
    fun hostApprovedCallbackCanCatchUpFromCodeActive() {
        assertEquals(
            listOf(
                SessionState.PAIR_PENDING,
                SessionState.HOST_APPROVED
            ),
            HostBackendStateSync.forwardTransitions(
                SessionState.CODE_ACTIVE,
                "HOST_APPROVED"
            )
        )
    }

    @Test
    fun duplicateOrOlderCallbacksDoNotRegressLocalState() {
        assertEquals(
            emptyList<SessionState>(),
            HostBackendStateSync.forwardTransitions(
                SessionState.HOST_APPROVED,
                "PAIR_PENDING"
            )
        )
        assertEquals(
            emptyList<SessionState>(),
            HostBackendStateSync.forwardTransitions(
                SessionState.HOST_APPROVED,
                "HOST_APPROVED"
            )
        )
    }
}
