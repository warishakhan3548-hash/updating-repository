package com.aaris.remoteassist.ui

/**
 * Computes remote gesture durations only from MotionEvent.eventTime values.
 *
 * MotionEvent.eventTime uses the uptime clock. Mixing it with
 * SystemClock.elapsedRealtime includes time spent in deep sleep and can turn a
 * short physical tap into an apparent multi-second press. Keeping both ends in
 * the same clock domain preserves the user's real touch duration.
 */
internal object RemoteGestureTiming {
    fun durationMs(
        startEventTimeMs: Long,
        endEventTimeMs: Long,
        minMs: Int,
        maxMs: Int
    ): Int {
        require(minMs >= 0)
        require(maxMs >= minMs)

        val elapsed =
            (endEventTimeMs - startEventTimeMs)
                .coerceAtLeast(0L)
                .coerceAtMost(Int.MAX_VALUE.toLong())

        return elapsed.toInt().coerceIn(minMs, maxMs)
    }
}
