package com.aaris.remoteassist.ui

/**
 * Post-start Android renderer recovery signal.
 *
 * A decoded frame is only evidence of input to the GL renderer; an actual
 * EglRenderer swap proves that it reached the Surface. On a normal static
 * screen neither may advance quickly, so only a sustained divergence is
 * actionable. No frame copies, synthetic output, or second playout queue.
 */
internal object RendererContinuityPolicy {
    private const val EGL_STALL_MS = 3_000L
    private const val RECENT_DECODE_MS = 2_000L
    // An EGL swap is not evidence of *current* presentation after the main
    // looper has queued its feedback runnable for an arbitrary period.
    // This bound is intentionally above one normal 500 ms cadence window.
    private const val MAX_FEEDBACK_DISPATCH_AGE_MS = 1_000L

    /**
     * Prevent queued, obsolete EGL swaps from refreshing host liveness, from
     * biasing the cadence governor or from confirming an already-stalled renderer.
     * Both timestamps must use SystemClock.elapsedRealtime() on the same phone.
     * Ordinary in-order callbacks are unaffected; no new queue or worker.
     */
    fun isFreshPresentationCallback(nowMs: Long, presentedAtMs: Long): Boolean =
        presentedAtMs > 0L &&
            nowMs >= presentedAtMs &&
            nowMs - presentedAtMs <= MAX_FEEDBACK_DISPATCH_AGE_MS

    fun shouldRecover(
        nowMs: Long,
        lastDecodedAtMs: Long,
        lastPresentedAtMs: Long,
        hadRendered: Boolean,
        surfaceReady: Boolean
    ): Boolean {
        if (!hadRendered || !surfaceReady ||
            nowMs <= 0L || lastDecodedAtMs <= 0L || lastPresentedAtMs <= 0L ||
            lastDecodedAtMs <= lastPresentedAtMs ||
            lastDecodedAtMs > nowMs || lastPresentedAtMs > nowMs
        ) {
            return false
        }

        return nowMs - lastPresentedAtMs >= EGL_STALL_MS &&
            nowMs - lastDecodedAtMs <= RECENT_DECODE_MS
    }
}
