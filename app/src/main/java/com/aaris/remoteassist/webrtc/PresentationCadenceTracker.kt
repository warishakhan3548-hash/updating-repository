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
    private var lastDecodedSequence: Long? = null

    // A long interval with no intermediate decoded frames is source/transport
    // silence, not a renderer service-time measurement. Keep the next actual
    // EGL swap as a new anchor rather than reporting a fake multi-second
    // maxGap/FPS drop to the host governor.
    private val sourceQuietGapMs = 750L

    @Synchronized
    fun onPresented(
        nowMs: Long,
        decodedSequence: Long? = null
    ): PresentationCadenceWindow? {
        if (nowMs < 0L) return null

        // Decoder callbacks and real EGL swaps are independent clocks.
        // Use the number of decoder callbacks since the previous swap to
        // distinguish a quiet/static producer from an EGL queue/render stall.
        // The optional argument preserves the old cadence-only behavior for
        // callers without decoded-frame evidence.
        val previousDecoded = lastDecodedSequence
        val decodedSinceLastSwap =
            if (
                decodedSequence != null &&
                previousDecoded != null &&
                decodedSequence >= previousDecoded
            ) {
                decodedSequence - previousDecoded
            } else {
                null
            }
        val quietSourceGap =
            lastFrameMs >= 0L &&
                nowMs >= lastFrameMs &&
                nowMs - lastFrameMs >= sourceQuietGapMs &&
                decodedSinceLastSwap != null &&
                decodedSinceLastSwap <= 1L
        lastDecodedSequence = decodedSequence

        if (
            quietSourceGap ||
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
        lastDecodedSequence = null
    }
}
