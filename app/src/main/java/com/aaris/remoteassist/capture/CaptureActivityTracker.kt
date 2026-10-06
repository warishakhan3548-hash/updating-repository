package com.aaris.remoteassist.capture

/** Counts fresh producer frames before RTP adaptation; never reads pixels back to the CPU. */
internal class CaptureActivityTracker {
    private var lastTimestampNs = Long.MIN_VALUE
    private var sampledAtMs: Long? = null
    private var frames = 0

    @Synchronized
    fun onFrame(timestampNs: Long) {
        // forceFrame reuses the original texture timestamp on a static screen.
        if (timestampNs <= 0 || timestampNs == lastTimestampNs) return
        lastTimestampNs = timestampNs
        frames = (frames + 1).coerceAtMost(2048)
    }

    @Synchronized
    fun sampleFps(nowMs: Long): Double? {
        val previous = sampledAtMs
        val elapsed = previous?.let { nowMs - it }
        if (elapsed != null && elapsed in 0L until 500L) return null
        val count = frames
        frames = 0
        sampledAtMs = nowMs
        return if (elapsed != null && elapsed in 500L..6000L) count * 1000.0 / elapsed else null
    }
}
