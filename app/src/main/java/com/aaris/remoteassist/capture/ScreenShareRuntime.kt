package com.aaris.remoteassist.capture

import java.util.concurrent.atomic.AtomicReference

/**
 * Process-local truth for whether this phone is actively sharing its screen.
 *
 * SessionCoordinator is used by both host and controller roles, so states such
 * as CONNECTING/LIVE alone are not enough to decide whether the Accessibility
 * STOP overlay belongs on this device.
 */
object ScreenShareRuntime {
    private val activeSession = AtomicReference<String?>(null)

    fun activate(sessionId: String) {
        require(sessionId.isNotBlank())
        activeSession.set(sessionId)
    }

    fun clear(sessionId: String? = null) {
        while (true) {
            val current = activeSession.get() ?: return
            if (sessionId != null && current != sessionId) return
            if (activeSession.compareAndSet(current, null)) return
        }
    }

    fun isActive(sessionId: String?): Boolean {
        if (sessionId.isNullOrBlank()) return false
        return activeSession.get() == sessionId
    }

    fun currentSessionId(): String? = activeSession.get()
}
