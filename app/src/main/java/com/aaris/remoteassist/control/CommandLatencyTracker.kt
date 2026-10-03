package com.aaris.remoteassist.control

/** One-clock, bounded command send-to-ACK timings. This is NOT input-to-photon. */
internal class CommandLatencyTracker {
    private val pending = LinkedHashMap<Long, Long>()
    private val samples = ArrayDeque<Long>()

    @Synchronized fun sent(sequence: Long, nowMs: Long) {
        pending[sequence] = nowMs
        while (pending.size > 128) pending.remove(pending.keys.first())
    }

    @Synchronized fun acknowledged(sequence: Long, applied: Boolean, nowMs: Long) {
        val started = pending.remove(sequence) ?: return
        val elapsed = nowMs - started
        if (!applied || elapsed !in 0..30_000) return
        samples.addLast(elapsed)
        while (samples.size > 128) samples.removeFirst()
    }

    @Synchronized fun summary(): String {
        if (samples.isEmpty()) return "Command ACK: waiting for applied input"
        val sorted = samples.sorted()
        fun percentile(percent: Int) = sorted[((sorted.size * percent + 99) / 100 - 1).coerceAtLeast(0)]
        return "Command ACK p50=${percentile(50)}ms p95=${percentile(95)}ms n=${sorted.size} (not screen latency)"
    }

    @Synchronized fun reset() { pending.clear(); samples.clear() }
}
