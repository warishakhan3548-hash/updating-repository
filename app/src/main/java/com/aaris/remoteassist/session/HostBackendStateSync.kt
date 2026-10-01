package com.aaris.remoteassist.session

/**
 * Backend session callbacks can arrive before the coroutine that initiated the
 * same transition resumes on the main thread. Keep the local state machine
 * monotonic so observers can safely acknowledge authoritative backend progress
 * without racing the initiating UI flow.
 */
object HostBackendStateSync {
    fun forwardTransitions(
        localState: SessionState,
        backendState: String
    ): List<SessionState> = when (backendState) {
        "PAIR_PENDING" -> when (localState) {
            SessionState.CODE_ACTIVE ->
                listOf(SessionState.PAIR_PENDING)

            else -> emptyList()
        }

        "HOST_APPROVED" -> when (localState) {
            SessionState.CODE_ACTIVE ->
                listOf(
                    SessionState.PAIR_PENDING,
                    SessionState.HOST_APPROVED
                )

            SessionState.PAIR_PENDING ->
                listOf(SessionState.HOST_APPROVED)

            else -> emptyList()
        }

        else -> emptyList()
    }
}
