package com.aaris.remoteassist.session

enum class SessionState {
    IDLE,
    SETUP_REQUIRED,
    READY,
    CODE_ACTIVE,
    PAIR_PENDING,
    HOST_APPROVED,
    SCREEN_CONSENT,
    CONNECTING,
    LIVE,
    CLOSED
}

data class SessionSnapshot(
    val sessionId: String? = null,
    val state: SessionState = SessionState.IDLE,
    val displayGeneration: Int = 0,
    val updatedAtElapsedMs: Long = 0L
)
