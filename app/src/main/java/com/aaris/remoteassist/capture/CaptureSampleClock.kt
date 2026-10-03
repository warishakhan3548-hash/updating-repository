package com.aaris.remoteassist.capture

/** A requested repeat samples the current texture even when no display buffer changed. */
internal class CaptureSampleClock {
    private var previous = Long.MIN_VALUE
    fun timestamp(sourceNs: Long, sampledAtNs: Long): Long {
        val next = if (sourceNs > previous) sourceNs else maxOf(previous + 1, sampledAtNs)
        previous = next
        return next
    }
}
