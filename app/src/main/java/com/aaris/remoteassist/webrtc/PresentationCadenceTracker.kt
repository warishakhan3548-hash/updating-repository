package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

/** Actual controller-side EGL presentation cadence, not decoder/RTP cadence. */
data class PresentationCadenceWindow(
    val intervalMs: Int,
    val renderedFrames: Int,
    val maxGapMs: Int,
    // Exact nearest-rank tail latency of the per-frame EGL swap gaps.
    // Local diagnostics only: preserve the existing wire protocol unchanged.
    val p95GapMs: Int? = null,
    val p99GapMs: Int? = null
) {
    init {
        require(intervalMs in 1..6_000)
        require(renderedFrames in 1..2_048)
        require(maxGapMs in 0..6_000)
        require(p95GapMs == null || p95GapMs in 0..maxGapMs)
        require(p99GapMs == null || p99GapMs in (p95GapMs ?: 0)..maxGapMs)
    }

    val fps: Double
        get() = renderedFrames * 1000.0 / intervalMs

    fun compact(): String =
        "present=${fps.roundToInt()}fps maxGap=${maxGapMs}ms" +
            (p95GapMs?.let { " p95Gap=${it}ms" } ?: "") +
            (p99GapMs?.let { " p99Gap=${it}ms" } ?: "")
}

/**
 * Converts real EGL swaps into bounded half-second feedback windows. Shorter
 * windows surface a render hitch sooner than a one-second stats cycle, while
 * ReceiverVideoFeedback aggregates consecutive windows until the host consumes
 * them. That preserves a stable cadence estimate and the worst observed swap
 * gap without increasing libwebrtc getStats() polling or JNI churn.
 *
 * The tracker is synchronized because EglRenderer invokes its render listener
 * on a render thread while session lifecycle/reset may run on Android's main
 * thread.
 */
class PresentationCadenceTracker(
    private val minWindowMs: Long = 500L,
    private val maxGapMs: Long = 6_000L
) {
    init {
        require(minWindowMs in 500L..3_000L)
        require(maxGapMs in minWindowMs..6_000L)
    }

    private var windowStartMs = -1L
    private var lastFrameMs = -1L
    private var frames = 0
    private var largestGapMs = 0L
    // Reuse a fixed primitive array: no per-frame allocation and no unbounded
    // queue. A half-second window normally contains only 15-60 swap gaps.
    private val gapSamples = IntArray(2_048)
    private var gapCount = 0

    @Synchronized
    fun onPresented(nowMs: Long): PresentationCadenceWindow? {
        if (nowMs < 0L) return null

        if (
            windowStartMs < 0L ||
            lastFrameMs < 0L ||
            nowMs < lastFrameMs ||
            nowMs - lastFrameMs > maxGapMs
        ) {
            windowStartMs = nowMs
            lastFrameMs = nowMs
            // First EGL swap is the interval anchor, not an interval arrival.
            frames = 0
            largestGapMs = 0L
            gapCount = 0
            return null
        }

        val gap = nowMs - lastFrameMs
        largestGapMs = maxOf(largestGapMs, gap)
        lastFrameMs = nowMs
        frames += 1
        if (gapCount < gapSamples.size) {
            gapSamples[gapCount++] = gap.coerceIn(0L, 6_000L).toInt()
        }

        val elapsed = nowMs - windowStartMs
        if (elapsed < minWindowMs) return null

        // Sort only at the half-second boundary, never for ordinary swaps.
        // Exact tails distinguish stable cadence from occasional large hitches
        // that average FPS can conceal, without allocating a copy per frame.
        java.util.Arrays.sort(gapSamples, 0, gapCount)
        fun percentile(percent: Int): Int? {
            if (gapCount == 0) return null
            val rank = ((percent * gapCount + 99) / 100 - 1)
                .coerceIn(0, gapCount - 1)
            return gapSamples[rank]
        }
        val sample = PresentationCadenceWindow(
            intervalMs = elapsed.coerceIn(1L, 6_000L).toInt(),
            renderedFrames = frames.coerceIn(1, 2_048),
            maxGapMs = largestGapMs.coerceIn(0L, 6_000L).toInt(),
            p95GapMs = percentile(95),
            p99GapMs = percentile(99)
        )

        // The current frame closes the old window. The next frame starts the
        // new count, preventing one EGL swap from being counted twice.
        windowStartMs = nowMs
        frames = 0
        largestGapMs = 0L
        gapCount = 0
        return sample
    }

    @Synchronized
    fun reset() {
        windowStartMs = -1L
        lastFrameMs = -1L
        frames = 0
        largestGapMs = 0L
        gapCount = 0
    }
}
