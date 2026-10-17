package com.aaris.remoteassist.ui

/**
 * Paces freshness-only remote drag updates independently of the video cadence.
 *
 * Healthy sessions target a 60 Hz-class input loop so the remote pointer starts
 * and follows the controller finger promptly even when video itself is encoded
 * at 30 fps. When the unreliable DataChannel reports backpressure, the pacer
 * backs off aggressively instead of repeatedly encoding/sending stale motion.
 * One pressure signal moves 16 -> 32 ms and a second reaches the bounded 48 ms
 * ceiling; this gives SCTP/network queues room to drain before old finger
 * positions accumulate. Successful sends then converge gradually back toward
 * the low-latency floor so a transient spike cannot cause oscillation.
 *
 * Healthy deadlines retain their phase instead of restarting at each sampled
 * event. A 90 Hz touch stream would otherwise round every 16 ms interval up to
 * two events and reduce input delivery to 45 Hz. The interval is an average
 * deadline target: sampled events may be closer together than that target.
 * Missed intervals are discarded, so a resumed event never creates a backlog
 * of catch-up sends.
 *
 * START/END packets are authoritative and never pass through this pacer.
 */
internal class GestureStreamPacer(
    private val minIntervalMs: Long = 16L,
    private val maxIntervalMs: Long = 48L,
    private val pressureStepMs: Long = 16L,
    private val recoveryStepMs: Long = 4L
) {
    init {
        require(minIntervalMs > 0L)
        require(maxIntervalMs >= minIntervalMs)
        require(pressureStepMs > 0L)
        require(recoveryStepMs > 0L)
    }

    private var intervalMs = minIntervalMs
    private var nextAttemptAtMs: Long? = null
    private var lastEventTimeMs: Long? = null
    private var deadlineOverflowed = false

    fun shouldAttempt(eventTimeMs: Long): Boolean {
        if (observeEventTime(eventTimeMs)) {
            // Rebase a changed clock without releasing the cooldown early.
            scheduleFrom(eventTimeMs)
        }
        return !deadlineOverflowed &&
            (nextAttemptAtMs?.let { eventTimeMs >= it } ?: true)
    }

    fun onSent(eventTimeMs: Long) {
        val clockMovedBackwards = observeEventTime(eventTimeMs)
        intervalMs =
            intervalMs - minOf(recoveryStepMs, intervalMs - minIntervalMs)

        val previousDeadline = nextAttemptAtMs
        val phaseBase = previousDeadline?.takeIf {
            !clockMovedBackwards && eventTimeMs >= it &&
                safeAdd(it, intervalMs) > eventTimeMs
        }
        scheduleFrom(phaseBase ?: eventTimeMs)
    }

    fun onBackpressure(eventTimeMs: Long) {
        observeEventTime(eventTimeMs)
        intervalMs =
            intervalMs + minOf(pressureStepMs, maxIntervalMs - intervalMs)
        // Pressure always gets a full cooldown from the actual failed send.
        scheduleFrom(eventTimeMs)
    }

    fun reset() {
        intervalMs = minIntervalMs
        nextAttemptAtMs = null
        lastEventTimeMs = null
        deadlineOverflowed = false
    }

    internal fun currentIntervalMs(): Long = intervalMs

    private fun observeEventTime(eventTimeMs: Long): Boolean {
        val previous = lastEventTimeMs
        lastEventTimeMs = eventTimeMs
        return previous != null && eventTimeMs < previous
    }

    private fun scheduleFrom(baseMs: Long) {
        // No representable future deadline means wait for a reset/clock rebase,
        // rather than repeatedly admitting the saturated maximum timestamp.
        deadlineOverflowed = baseMs > Long.MAX_VALUE - intervalMs
        nextAttemptAtMs = safeAdd(baseMs, intervalMs)
    }

    private fun safeAdd(base: Long, delta: Long): Long =
        if (base > Long.MAX_VALUE - delta) {
            Long.MAX_VALUE
        } else {
            base + delta
        }
}
