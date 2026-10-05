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
 * Converts real EGL swaps into short bounded feedback windows. A 300 ms default
 * exposes visible 60/45 fps compositor stalls materially sooner than the slower
 * RTC stats loop, while a 15 fps receiver still accumulates enough swaps for the
 * host governor once the elapsed window crosses the threshold.
 *
 * ReceiverVideoFeedback aggregates consecutive windows until the host consumes
 * them. That preserves a stable cadence estimate and the worst observed swap
 * gap without increasing libwebrtc getStats() polling or JNI churn.
 *
 * The tracker is synchronized because EglRenderer invokes its render listener
 * on a render thread while session lifecycle/reset may run on Android's main
 * thread.
 */
class PresentationCadenceTracker(
    private val minWindowMs: Long = 160L,
    private val minRenderedFrames: Int = 5,
    private val maxGapMs: Long = 6_000L
) {
    init {
        require(minWindowMs in 120L..3_000L)
        require(minRenderedFrames in 2..120)
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
            /*
             * This frame is the timing anchor, not a completed presentation
             * interval. Counting it would overstate FPS in the first window
             * because elapsed time starts at this exact swap.
             */
            frames = 0
            largestGapMs = 0L
            return null
        }

        largestGapMs = maxOf(largestGapMs, nowMs - lastFrameMs)
        lastFrameMs = nowMs
        frames += 1

        val elapsed = nowMs - windowStartMs
        /*
         * Use a hybrid time + evidence window. Fast 45/60 Hz rendering reports
         * in ~160 ms, while low-cadence paths wait until enough real swap
         * intervals exist to make the FPS estimate trustworthy. This avoids both
         * slow hitch detection and tiny-sample false alarms.
         */
        if (elapsed < minWindowMs || frames < minRenderedFrames) return null

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
