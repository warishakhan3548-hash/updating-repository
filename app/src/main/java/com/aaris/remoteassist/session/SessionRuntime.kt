package com.aaris.remoteassist.session

import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicReference

data class LiveLease(
    val sessionId: String,
    val leaseSecret: Long,
    val displayGeneration: Int
)

object SessionRuntime {
    private val random = SecureRandom()
    private val liveLease = AtomicReference<LiveLease?>(null)

    fun activate(sessionId: String, displayGeneration: Int): LiveLease {
        require(sessionId.isNotBlank())
        val lease = LiveLease(
            sessionId = sessionId,
            leaseSecret = random.nextLong(),
            displayGeneration = displayGeneration
        )
        liveLease.set(lease)
        return lease
    }

    fun currentLease(): LiveLease? = liveLease.get()

    fun isAuthorized(sessionId: String, leaseSecret: Long, generation: Int): Boolean {
        val current = liveLease.get() ?: return false
        return current.sessionId == sessionId &&
            current.leaseSecret == leaseSecret &&
            current.displayGeneration == generation
    }

    fun rotateDisplayGeneration(sessionId: String, leaseSecret: Long, generation: Int): LiveLease? {
        while (true) {
            val current = liveLease.get() ?: return null
            if (current.sessionId != sessionId || current.leaseSecret != leaseSecret) return null
            val updated = current.copy(displayGeneration = generation)
            if (liveLease.compareAndSet(current, updated)) return updated
        }
    }

    fun reset() {
        liveLease.set(null)
    }
}
