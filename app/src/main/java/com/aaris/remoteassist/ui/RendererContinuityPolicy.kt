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
