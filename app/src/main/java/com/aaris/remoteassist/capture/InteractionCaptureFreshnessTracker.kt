package com.aaris.remoteassist.capture

/**
 * Causal proof that applied remote input is outrunning natural MediaProjection
 * delivery.
 *
 * A low source FPS by itself is ambiguous because Android screen capture is
 * change-driven: a static form may legitimately produce no frames. The
 * post-input refresh probe is stronger evidence. It runs one display tick after
 * an Accessibility command was actually applied and forces the current texture
 * only when no newer natural producer sample arrived first.
 *
 * Consecutive forced pulls therefore mean "the controller is changing the
 * remote phone, but MediaProjection is not supplying a fresh texture by the
 * next display opportunity". Keep this state scalar-only and short-lived; no
 * frame, bitmap or second capture path is retained.
 */
internal class InteractionCaptureFreshnessTracker(
    private val missesForPressure: Int = DEFAULT_MISSES_FOR_PRESSURE,
    private val maxMissSpacingMs: Long = DEFAULT_MAX_MISS_SPACING_MS,
    private val pressureHoldMs: Long = DEFAULT_PRESSURE_HOLD_MS
) {
    private var consecutiveMisses = 0
    private var lastProbeAtMs = Long.MIN_VALUE / 2

    init {
        require(missesForPressure >= 2)
        require(maxMissSpacingMs >= 1L)
        require(pressureHoldMs >= maxMissSpacingMs)
    }

    fun observe(
        forcedRefresh: Boolean,
        nowMs: Long
    ) {
        if (nowMs < 0L) return

        if (!forcedRefresh) {
            consecutiveMisses = 0
            lastProbeAtMs = nowMs
            return
        }

        if (nowMs - lastProbeAtMs !in 0L..maxMissSpacingMs) {
            consecutiveMisses = 0
        }

        consecutiveMisses =
            (consecutiveMisses + 1)
                .coerceAtMost(missesForPressure)
        lastProbeAtMs = nowMs
    }

    fun isStarved(nowMs: Long): Boolean =
        nowMs >= 0L &&
            consecutiveMisses >= missesForPressure &&
            nowMs - lastProbeAtMs in 0L..pressureHoldMs

    fun reset() {
        consecutiveMisses = 0
        lastProbeAtMs = Long.MIN_VALUE / 2
    }

    private companion object {
        const val DEFAULT_MISSES_FOR_PRESSURE = 2
        const val DEFAULT_MAX_MISS_SPACING_MS = 250L
        const val DEFAULT_PRESSURE_HOLD_MS = 1_200L
    }
}
