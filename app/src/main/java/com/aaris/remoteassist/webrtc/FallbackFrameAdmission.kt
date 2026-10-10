package com.aaris.remoteassist.webrtc

import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

/**
 * Owns the single-flight CPU fallback frame admission deadline.
 *
 * Network backpressure and an occupied encoder must not consume a capture slot:
 * doing so delays the first fresh frame even after the path is ready again.
 * This gate does not buffer or retain source textures.
 */
internal class FallbackFrameAdmission {
    enum class Decision { ACCEPTED, THROTTLED, BACKPRESSURED, BUSY }

    private val inFlight = AtomicBoolean(false)
    private val lastAcceptedAtMs = AtomicLong(NO_SAMPLE)

    fun tryAcquire(
        nowMs: Long,
        intervalMs: Long,
        capacityReady: () -> Boolean
    ): Decision {
        require(intervalMs > 0L)
        if (nowMs < 0L) return Decision.THROTTLED

        if (withinInterval(lastAcceptedAtMs.get(), nowMs, intervalMs)) {
            return Decision.THROTTLED
        }
        if (!capacityReady()) return Decision.BACKPRESSURED
        if (!inFlight.compareAndSet(false, true)) return Decision.BUSY

        // Recheck inside the single-flight lease in case another callback
        // acquired and released while this one was inspecting the deadline.
        if (withinInterval(lastAcceptedAtMs.get(), nowMs, intervalMs)) {
            inFlight.set(false)
            return Decision.THROTTLED
        }
        lastAcceptedAtMs.set(nowMs)
        return Decision.ACCEPTED
    }

    fun finish() {
        inFlight.set(false)
    }

    /** A recovery keyframe can start immediately; an active copy cannot overlap. */
    fun resetCooldown() {
        lastAcceptedAtMs.set(NO_SAMPLE)
    }

    private fun withinInterval(
        previousMs: Long,
        nowMs: Long,
        intervalMs: Long
    ): Boolean {
        if (previousMs == NO_SAMPLE || nowMs < previousMs) return false
        return nowMs - previousMs < intervalMs
    }

    private companion object {
        const val NO_SAMPLE = Long.MIN_VALUE
    }
}
