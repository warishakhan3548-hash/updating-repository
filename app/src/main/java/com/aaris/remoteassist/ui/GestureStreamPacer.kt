package com.aaris.remoteassist.ui

/**
 * Paces freshness-only remote drag updates independently of the video cadence.
 *
 * Healthy sessions target a 60 Hz-class input loop so the remote pointer starts
 * and follows the controller finger promptly even when video itself is encoded
 * at 30 fps. When the unreliable DataChannel reports backpressure, the pacer
 * backs off immediately instead of repeatedly encoding/sending stale motion.
 * Successful sends then converge gradually back toward the low-latency floor.
 *
 * START/END packets are authoritative and never pass through this pacer.
 */
internal class GestureStreamPacer(
    private val minIntervalMs: Long = 16L,
    private val maxIntervalMs: Long = 48L,
    private val pressureStepMs: Long = 8L,
    private val recoveryStepMs: Long = 4L
) {
    init {
        require(minIntervalMs > 0L)
        require(maxIntervalMs >= minIntervalMs)
        require(pressureStepMs > 0L)
        require(recoveryStepMs > 0L)
    }

    private var intervalMs = minIntervalMs
    private var nextAttemptAtMs = Long.MIN_VALUE

    fun shouldAttempt(eventTimeMs: Long): Boolean =
        eventTimeMs >= nextAttemptAtMs

    fun onSent(eventTimeMs: Long) {
        intervalMs =
            (intervalMs - recoveryStepMs)
                .coerceAtLeast(minIntervalMs)
        nextAttemptAtMs = safeAdd(eventTimeMs, intervalMs)
    }

    fun onBackpressure(eventTimeMs: Long) {
        intervalMs =
            (intervalMs + pressureStepMs)
                .coerceAtMost(maxIntervalMs)
        nextAttemptAtMs = safeAdd(eventTimeMs, intervalMs)
    }

    fun reset() {
        intervalMs = minIntervalMs
        nextAttemptAtMs = Long.MIN_VALUE
    }

    internal fun currentIntervalMs(): Long = intervalMs

    private fun safeAdd(base: Long, delta: Long): Long =
        if (base > Long.MAX_VALUE - delta) {
            Long.MAX_VALUE
        } else {
            base + delta
        }
}
