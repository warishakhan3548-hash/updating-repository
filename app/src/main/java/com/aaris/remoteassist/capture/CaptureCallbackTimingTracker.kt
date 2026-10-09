package com.aaris.remoteassist.capture

/** Per-stage callback service times on the producer's monotonic clock. */
internal data class CaptureCallbackTimingSummary(
    val samples: Int,
    val ingressP95Us: Long,
    val ingressP99Us: Long,
    val auxiliaryP95Us: Long,
    val auxiliaryP99Us: Long
) {
    fun compact(): String =
        "captureCallback n=$samples ingressP95=${ingressP95Us}us " +
            "ingressP99=${ingressP99Us}us auxP95=${auxiliaryP95Us}us " +
            "auxP99=${auxiliaryP99Us}us"
}

/**
 * Bounded, allocation-free on the per-frame path. This measures how long the
 * Java capture callback spends handing a frame into the primary WebRTC source
 * and then delivering it to auxiliary snapshot/fallback sinks. It does NOT
 * claim to measure native encoding, RTP transit or true capture-to-glass age.
 *
 * Called exclusively by the SurfaceTextureHelper capture thread.
 */
internal class CaptureCallbackTimingTracker(
    private val reportWindowMs: Long = 10_000L,
    private val minSamples: Int = 24,
    private val sampleCapacity: Int = 512
) {
    init {
        require(reportWindowMs > 0)
        require(sampleCapacity in 1..4096)
        require(minSamples in 1..sampleCapacity)
    }

    private val ingressUs = LongArray(sampleCapacity)
    private val auxiliaryUs = LongArray(sampleCapacity)
    private var next = 0
    private var samples = 0
    private var windowStartedMs = Long.MIN_VALUE

    fun record(
        nowMs: Long,
        primaryIngressNs: Long,
        auxiliarySinksNs: Long
    ): CaptureCallbackTimingSummary? {
        if (nowMs < 0L) return null
        if (windowStartedMs == Long.MIN_VALUE || nowMs < windowStartedMs) {
            next = 0
            samples = 0
            windowStartedMs = nowMs
        }

        ingressUs[next] = toMicros(primaryIngressNs)
        auxiliaryUs[next] = toMicros(auxiliarySinksNs)
        next = (next + 1) % sampleCapacity
        samples = (samples + 1).coerceAtMost(sampleCapacity)
        if (samples < minSamples || nowMs - windowStartedMs < reportWindowMs) {
            return null
        }

        val sortedIngress = ingressUs.copyOf(samples).apply { sort() }
        val sortedAuxiliary = auxiliaryUs.copyOf(samples).apply { sort() }
        val result = CaptureCallbackTimingSummary(
            samples = samples,
            ingressP95Us = percentile(sortedIngress, 95),
            ingressP99Us = percentile(sortedIngress, 99),
            auxiliaryP95Us = percentile(sortedAuxiliary, 95),
            auxiliaryP99Us = percentile(sortedAuxiliary, 99)
        )
        next = 0
        samples = 0
        windowStartedMs = nowMs
        return result
    }

    private fun toMicros(ns: Long): Long =
        ns.coerceAtLeast(0L).div(1_000L).coerceAtMost(10_000_000L)

    private fun percentile(sorted: LongArray, percent: Int): Long {
        val index = ((sorted.size * percent + 99) / 100 - 1)
            .coerceIn(0, sorted.lastIndex)
        return sorted[index]
    }
}
