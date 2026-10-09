package com.aaris.remoteassist.webrtc

/**
 * Keeps compatibility-video GPU readback from monopolizing the primary RTP
 * capture callback when a device's texture-to-I420 conversion is expensive.
 *
 * This is deliberately a tiny controller for the fallback path only. It never
 * changes MediaProjection, native WebRTC adaptation, the wire format or FPS.
 * Sustained slow copies reduce the readback pixel envelope; recovery is slow
 * and requires fresh, consecutive healthy samples to avoid quality oscillation.
 */
internal class FallbackReadbackBudget {
    @Volatile private var pressureLevel = 0
    private var overloadVotes = 0
    private var healthyVotes = 0
    private var lastSampleAtMs = -1L
    private var lastTransitionAtMs = Long.MIN_VALUE / 2

    /** Returns an even, bounded long-side limit for CpuFrameCopy.capture(). */
    fun maxSidePx(baseSidePx: Int): Int {
        val base = baseSidePx.coerceAtLeast(2)
        val percent = when (pressureLevel) {
            1 -> 75L
            2 -> 50L
            else -> 100L
        }
        return ((base.toLong() * percent / 100L).toInt() / 2 * 2)
            .coerceAtLeast(2)
    }

    /**
     * Observe only successful copy operations. Return the new pressure tier
     * on a transition, or null when the image envelope remains unchanged.
     * Sampling gaps cannot be accumulated into false consecutive evidence.
     */
    @Synchronized
    fun observe(copyCostMs: Long, nowMs: Long): Int? {
        if (copyCostMs < 0L || nowMs < 0L) return null
        if (lastSampleAtMs >= 0L &&
            nowMs - lastSampleAtMs !in 0L..MAX_EVIDENCE_GAP_MS
        ) {
            overloadVotes = 0
            healthyVotes = 0
        }
        lastSampleAtMs = nowMs

        when {
            copyCostMs >= OVERLOAD_COPY_MS -> {
                overloadVotes = (overloadVotes + 1).coerceAtMost(OVERLOAD_VOTES)
                healthyVotes = 0
                if (overloadVotes >= OVERLOAD_VOTES &&
                    pressureLevel < MAX_LEVEL &&
                    nowMs - lastTransitionAtMs >= DOWNSHIFT_HOLD_MS
                ) {
                    pressureLevel++
                    overloadVotes = 0
                    lastTransitionAtMs = nowMs
                    return pressureLevel
                }
            }
            copyCostMs <= HEALTHY_COPY_MS -> {
                healthyVotes = (healthyVotes + 1).coerceAtMost(RECOVERY_VOTES)
                overloadVotes = 0
                if (healthyVotes >= RECOVERY_VOTES &&
                    pressureLevel > 0 &&
                    nowMs - lastTransitionAtMs >= RECOVERY_HOLD_MS
                ) {
                    pressureLevel--
                    healthyVotes = 0
                    lastTransitionAtMs = nowMs
                    return pressureLevel
                }
            }
            else -> {
                overloadVotes = 0
                healthyVotes = 0
            }
        }
        return null
    }

    @Synchronized
    fun reset() {
        pressureLevel = 0
        overloadVotes = 0
        healthyVotes = 0
        lastSampleAtMs = -1L
        lastTransitionAtMs = Long.MIN_VALUE / 2
    }

    private companion object {
        const val OVERLOAD_COPY_MS = 30L
        const val HEALTHY_COPY_MS = 16L
        const val OVERLOAD_VOTES = 2
        const val RECOVERY_VOTES = 10
        const val MAX_LEVEL = 2
        const val MAX_EVIDENCE_GAP_MS = 2_000L
        const val DOWNSHIFT_HOLD_MS = 2_000L
        const val RECOVERY_HOLD_MS = 15_000L
    }
}
