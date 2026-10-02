package com.aaris.remoteassist.webrtc

import java.util.TreeSet

/**
 * Tracks signaling event delivery without assuming WebSocket messages arrive
 * in global sequence order. Every unique event is processed once, while the
 * reconnect cursor advances only across a contiguous prefix.
 */
internal class SignalingSequenceTracker {
    private val lock = Any()
    private val pending = TreeSet<Long>()
    private var contiguous = 0L

    fun accept(sequence: Long): Boolean = synchronized(lock) {
        if (sequence <= 0L) return@synchronized false
        if (sequence <= contiguous) return@synchronized false
        if (!pending.add(sequence)) return@synchronized false

        while (pending.remove(contiguous + 1L)) {
            contiguous += 1L
        }
        true
    }

    fun reconnectAfter(): Long = synchronized(lock) {
        contiguous
    }

    fun reset() = synchronized(lock) {
        pending.clear()
        contiguous = 0L
    }
}
