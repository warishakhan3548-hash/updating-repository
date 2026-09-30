package com.aaris.remoteassist.session

class SessionStateMachine(initial: SessionSnapshot = SessionSnapshot()) {
    private val lock = Any()
    private var snapshot = initial

    fun snapshot(): SessionSnapshot = synchronized(lock) { snapshot }

    fun transition(
        sessionId: String?,
        next: SessionState,
        nowElapsedMs: Long
    ): SessionSnapshot = synchronized(lock) {
        val current = snapshot
        require(isAllowed(current.state, next)) {
            "Illegal session transition: ${current.state} -> $next"
        }
        if (current.sessionId != null && sessionId != null) {
            require(current.sessionId == sessionId) { "Session identity cannot change mid-session" }
        }
        val resolvedId = sessionId ?: current.sessionId
        snapshot = current.copy(
            sessionId = resolvedId,
            state = next,
            updatedAtElapsedMs = nowElapsedMs
        )
        snapshot
    }

    fun bumpDisplayGeneration(nowElapsedMs: Long): SessionSnapshot = synchronized(lock) {
        require(snapshot.state == SessionState.LIVE || snapshot.state == SessionState.CONNECTING)
        snapshot = snapshot.copy(
            displayGeneration = snapshot.displayGeneration + 1,
            updatedAtElapsedMs = nowElapsedMs
        )
        snapshot
    }

    private fun isAllowed(from: SessionState, to: SessionState): Boolean {
        if (to == SessionState.CLOSED) return from != SessionState.CLOSED
        return when (from) {
            SessionState.IDLE -> to == SessionState.SETUP_REQUIRED || to == SessionState.READY
            SessionState.SETUP_REQUIRED -> to == SessionState.READY
            SessionState.READY -> to == SessionState.CODE_ACTIVE || to == SessionState.PAIR_PENDING
            SessionState.CODE_ACTIVE -> to == SessionState.PAIR_PENDING
            SessionState.PAIR_PENDING -> to == SessionState.HOST_APPROVED
            SessionState.HOST_APPROVED -> to == SessionState.SCREEN_CONSENT
            SessionState.SCREEN_CONSENT -> to == SessionState.CONNECTING
            SessionState.CONNECTING -> to == SessionState.LIVE
            SessionState.LIVE -> false
            SessionState.CLOSED -> false
        }
    }
}
