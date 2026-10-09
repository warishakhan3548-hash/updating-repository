package com.aaris.remoteassist.capture

import java.util.Arrays
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/** Per-stage callback service times on the producer's monotonic clock. */
data class CaptureCallbackTimingSummary(
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
 * Sealed timing window handed off from the capture thread.
 *
 * Sorting is deliberately deferred until [summarizeAndRelease] runs on the
 * policy lane. The two backing arrays are then returned to the tracker for a
 * later window; no frame samples are retained.
 */
class CaptureCallbackTimingBatch internal constructor(
    private val ingressUs: LongArray,
    private val auxiliaryUs: LongArray,
    val samples: Int,
    private val onRelease: () -> Unit
) {
    private val completed = AtomicBoolean(false)

    fun summarizeAndRelease(): CaptureCallbackTimingSummary? {
        if (!completed.compareAndSet(false, true)) return null
        return try {
            Arrays.sort(ingressUs, 0, samples)
            Arrays.sort(auxiliaryUs, 0, samples)
            CaptureCallbackTimingSummary(
                samples = samples,
                ingressP95Us = percentile(ingressUs, samples, 95),
                ingressP99Us = percentile(ingressUs, samples, 99),
                auxiliaryP95Us = percentile(auxiliaryUs, samples, 95),
                auxiliaryP99Us = percentile(auxiliaryUs, samples, 99)
            )
        } finally {
            onRelease()
        }
    }

    fun release() {
        if (completed.compareAndSet(false, true)) {
            onRelease()
        }
    }

    fun compact(): String =
        summarizeAndRelease()?.compact() ?: "captureCallback unavailable"

    private fun percentile(
        sorted: LongArray,
        count: Int,
        percent: Int
    ): Long {
        val index = ((count * percent + 99) / 100 - 1)
            .coerceIn(0, count - 1)
        return sorted[index]
    }
}

/**
 * Bounded capture-callback timing tracker.
 *
 * The per-frame path only writes two longs and updates counters. When a report
 * window closes, ownership of the active fixed-size arrays is swapped with a
 * spare pair in O(1). Sorting and diagnostics happen later on the host policy
 * thread. If that consumer is delayed long enough that no spare pair is
 * available, telemetry is skipped rather than blocking or allocating on the
 * SurfaceTexture capture thread.
 *
 * This measures Java callback service time only; it does not claim to measure
 * native encoding, RTP transit or true capture-to-glass age.
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

    private data class SampleBuffers(
        val ingressUs: LongArray,
        val auxiliaryUs: LongArray
    )

    private var active =
        SampleBuffers(
            ingressUs = LongArray(sampleCapacity),
            auxiliaryUs = LongArray(sampleCapacity)
        )
    private val spare =
        AtomicReference(
            SampleBuffers(
                ingressUs = LongArray(sampleCapacity),
                auxiliaryUs = LongArray(sampleCapacity)
            )
        )

    private var next = 0
    private var samples = 0
    private var windowStartedMs = Long.MIN_VALUE

    fun record(
        nowMs: Long,
        primaryIngressNs: Long,
        auxiliarySinksNs: Long
    ): CaptureCallbackTimingBatch? {
        if (nowMs < 0L) return null
        if (windowStartedMs == Long.MIN_VALUE || nowMs < windowStartedMs) {
            next = 0
            samples = 0
            windowStartedMs = nowMs
        }

        active.ingressUs[next] = toMicros(primaryIngressNs)
        active.auxiliaryUs[next] = toMicros(auxiliarySinksNs)
        next = (next + 1) % sampleCapacity
        samples = (samples + 1).coerceAtMost(sampleCapacity)

        if (
            samples < minSamples ||
            nowMs - windowStartedMs < reportWindowMs
        ) {
            return null
        }

        val replacement = spare.getAndSet(null) ?: return null
        val sealed = active
        val sealedSamples = samples
        active = replacement
        next = 0
        samples = 0
        windowStartedMs = nowMs

        return CaptureCallbackTimingBatch(
            ingressUs = sealed.ingressUs,
            auxiliaryUs = sealed.auxiliaryUs,
            samples = sealedSamples,
            onRelease = {
                // A delayed diagnostics lane must never disturb capture. If an
                // unexpected duplicate spare exists, simply discard this reuse
                // opportunity; the fixed active buffer remains valid.
                spare.compareAndSet(null, sealed)
            }
        )
    }

    private fun toMicros(ns: Long): Long =
        ns.coerceAtLeast(0L)
            .div(1_000L)
            .coerceAtMost(10_000_000L)
}
