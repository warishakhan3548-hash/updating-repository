package com.aaris.remoteassist.session

import java.security.SecureRandom
import java.util.concurrent.atomic.AtomicReference

data class LiveLease(
    val sessionId: String,
    val leaseSecret: Long,
    val displayGeneration: Int,
    val expiresAtMonotonicMs: Long = Long.MAX_VALUE
)

object SessionRuntime {
    private const val DEFAULT_LEASE_MS = 30_000L

    private val random = SecureRandom()
    private val liveLease = AtomicReference<LiveLease?>(null)

    fun activate(
        sessionId: String,
        displayGeneration: Int,
        leaseMs: Long = DEFAULT_LEASE_MS
    ): LiveLease {
        require(sessionId.isNotBlank())
        val lease = LiveLease(
            sessionId = sessionId,
            leaseSecret = random.nextLong(),
            displayGeneration = displayGeneration,
            expiresAtMonotonicMs = nowMs() + leaseMs.coerceIn(3_000L, 60_000L)
        )
        liveLease.set(lease)
        return lease
    }

    fun currentLease(): LiveLease? {
        while (true) {
            val current = liveLease.get() ?: return null
            if (current.expiresAtMonotonicMs > nowMs()) return current
            if (liveLease.compareAndSet(current, null)) return null
        }
    }

    fun isAuthorized(sessionId: String, leaseSecret: Long, generation: Int): Boolean {
        val current = currentLease() ?: return false
        return current.sessionId == sessionId &&
            current.leaseSecret == leaseSecret &&
            current.displayGeneration == generation
    }

    fun renew(
        sessionId: String,
        leaseSecret: Long,
        leaseMs: Long = DEFAULT_LEASE_MS
    ): LiveLease? {
        while (true) {
            val current = currentLease() ?: return null
            if (current.sessionId != sessionId || current.leaseSecret != leaseSecret) return null
            val updated = current.copy(
                expiresAtMonotonicMs = nowMs() + leaseMs.coerceIn(3_000L, 60_000L)
            )
            if (liveLease.compareAndSet(current, updated)) return updated
        }
    }

    fun rotateDisplayGeneration(
        sessionId: String,
        leaseSecret: Long,
        generation: Int
    ): LiveLease? {
        while (true) {
            val current = currentLease() ?: return null
            if (current.sessionId != sessionId || current.leaseSecret != leaseSecret) return null
            val updated = current.copy(displayGeneration = generation)
            if (liveLease.compareAndSet(current, updated)) return updated
        }
    }

    fun reset() {
        liveLease.set(null)
    }

    private fun nowMs(): Long = System.nanoTime() / 1_000_000L
}
