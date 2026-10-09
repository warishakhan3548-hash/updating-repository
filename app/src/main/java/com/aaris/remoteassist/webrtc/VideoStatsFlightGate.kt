package com.aaris.remoteassist.webrtc

/**
 * Bounds WebRTC getStats() polling independently of callback completion.
 * Callbacks can outlive an ICE epoch or arrive after a native stats timeout;
 * only the current request may publish telemetry or free its flight slot.
 *
 * This is control-plane bookkeeping; it neither buffers nor copies RTP frames.
 */
internal class VideoStatsFlightGate(
    private val timeoutMs: Long = 4_000L
) {
    init { require(timeoutMs >= 500L) }

    private var nextToken = 0L
    private var activeToken = 0L
    private var activeAtMs = 0L

    @Synchronized
    fun begin(nowMs: Long): Long? {
        if (nowMs < 0L) return null
        if (
            activeToken != 0L &&
            nowMs >= activeAtMs &&
            nowMs - activeAtMs < timeoutMs
        ) {
            return null
        }
        nextToken = if (nextToken == Long.MAX_VALUE) 1L else nextToken + 1L
        activeToken = nextToken
        activeAtMs = nowMs
        return activeToken
    }

    @Synchronized
    fun isCurrent(token: Long): Boolean =
        token != 0L && token == activeToken

    @Synchronized
    fun finish(token: Long): Boolean {
        if (!isCurrent(token)) return false
        activeToken = 0L
        return true
    }

    /** Discard ownership when ICE leaves its previous media epoch. */
    @Synchronized
    fun reset() {
        activeToken = 0L
    }
}
