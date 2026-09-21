package com.aaris.shield.visual

import kotlin.math.ceil
import kotlin.math.max

/**
 * Admission control only. Temporal confidence aggregation belongs to Step 7.
 * This limiter adapts solely to measured classifier cost so slow devices do not
 * accumulate more work than a single on-device classifier can service.
 */
class AdaptiveInferenceLimiter(
    private val minimumIntervalMillis: Long = 80L,
    private val maximumIntervalMillis: Long = 1_000L,
    private val latencyHeadroom: Double = 2.0,
    private val smoothing: Double = 0.25,
) {
    private var lastAcceptedNanos: Long? = null
    private var latencyEwmaMillis: Double? = null

    init {
        require(minimumIntervalMillis >= 0L)
        require(maximumIntervalMillis >= minimumIntervalMillis)
        require(latencyHeadroom >= 1.0)
        require(smoothing > 0.0 && smoothing <= 1.0)
    }

    @Synchronized
    fun tryAcquire(nowNanos: Long = System.nanoTime()): Boolean {
        val previous = lastAcceptedNanos
        if (previous != null) {
            val elapsed = ((nowNanos - previous).coerceAtLeast(0L)) / 1_000_000L
            if (elapsed < currentIntervalMillisLocked()) return false
        }
        lastAcceptedNanos = nowNanos
        return true
    }

    @Synchronized
    fun recordInference(inferenceMillis: Long) {
        if (inferenceMillis < 0L) return
        val sample = inferenceMillis.toDouble()
        val previous = latencyEwmaMillis
        latencyEwmaMillis = if (previous == null) {
            sample
        } else {
            previous + smoothing * (sample - previous)
        }
    }

    @Synchronized
    fun currentIntervalMillis(): Long = currentIntervalMillisLocked()

    private fun currentIntervalMillisLocked(): Long {
        val adaptive = latencyEwmaMillis?.let { ceil(it * latencyHeadroom).toLong() } ?: 0L
        return max(minimumIntervalMillis, adaptive).coerceAtMost(maximumIntervalMillis)
    }
}
