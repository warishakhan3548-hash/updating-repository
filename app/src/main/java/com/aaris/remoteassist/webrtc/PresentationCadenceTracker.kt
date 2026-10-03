package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

/** Actual controller-side EGL presentation cadence, not decoder/RTP cadence. */
data class PresentationCadenceWindow(
    val intervalMs: Int,
    val renderedFrames: Int,
    val maxGapMs: Int
) {
    init {
        require(intervalMs in 1..6_000)
        require(renderedFrames in 1..2_048)
        require(maxGapMs in 0..6_000)
    }

    val fps: Double
        get() = renderedFrames * 1000.0 / intervalMs

    fun compact(): String =
        "present=${fps.roundToInt()}fps maxGap=${maxGapMs}ms"
}

/**
 * Converts real EGL swaps into bounded one-second-ish windows. The tracker is
 * synchronized because EglRenderer invokes its render listener on a render
 * thread while session lifecycle/reset may run on Android's main thread.
 */
class PresentationCadenceTracker(
    private val minWindowMs: Long = 850L,
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
            frames = 1
            largestGapMs = 0L
            return null
        }

        largestGapMs = maxOf(largestGapMs, nowMs - lastFrameMs)
        lastFrameMs = nowMs
        frames += 1

        val elapsed = nowMs - windowStartMs
        if (elapsed < minWindowMs) return null

        val sample = PresentationCadenceWindow(
            intervalMs = elapsed.coerceIn(1L, 6_000L).toInt(),
            renderedFrames = frames.coerceIn(1, 2_048),
            maxGapMs = largestGapMs.coerceIn(0L, 6_000L).toInt()
        )

        // The current frame closes the old window. The next frame starts the
        // new count, preventing one EGL swap from being counted twice.
        windowStartMs = nowMs
        frames = 0
        largestGapMs = 0L
        return sample
    }

    @Synchronized
    fun reset() {
        windowStartMs = -1L
        lastFrameMs = -1L
        frames = 0
        largestGapMs = 0L
    }
}
