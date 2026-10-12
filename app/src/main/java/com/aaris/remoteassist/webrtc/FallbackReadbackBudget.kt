package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureVideoContract
import kotlin.math.ceil

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

    @Volatile
    private var lastCopyCostMs = 0L

    /**
     * Returns the fallback readback long-side envelope without ever violating
     * the product's 360 px short-edge readability floor.
     *
     * The pressure ladder is intentionally allowed to reduce only excess pixels.
     * Once the readable floor is reached, minimumIntervalMs() spends fallback
     * cadence instead. This prevents recovery work from solving capture-thread
     * pressure by making the emergency image unreadable.
     */
    fun maxSidePx(
        baseSidePx: Int,
        sourceWidthPx: Int,
        sourceHeightPx: Int
    ): Int {
        val base = baseSidePx.coerceAtLeast(2)
        val percent = when (pressureLevel) {
            1 -> 75L
            2 -> 50L
            else -> 100L
        }
        val pressureSide =
            ((base.toLong() * percent / 100L).toInt() / 2 * 2)
                .coerceAtLeast(2)

        if (sourceWidthPx <= 0 || sourceHeightPx <= 0) {
            return pressureSide
        }

        val sourceLong = maxOf(sourceWidthPx, sourceHeightPx)
        val sourceShort = minOf(sourceWidthPx, sourceHeightPx)
        if (sourceShort <= 0) return pressureSide

        val readabilityFloor =
            CaptureVideoContract.MIN_FALLBACK_READABLE_SHORT_SIDE_PX
        val readableLong =
            if (sourceShort <= readabilityFloor) {
                /*
                 * The producer is already at/below the contract. Do not
                 * downscale it (and never invent an upscale).
                 */
                sourceLong
            } else {
                /*
                 * CpuFrameCopy rounds scaled dimensions DOWN to an even value.
                 * Budget one pre-rounding pixel above the 360px contract so an
                 * odd source geometry cannot turn a mathematically exact 360.0
                 * into 359 -> 358 after integer/even rounding.
                 */
                val preEvenShort = readabilityFloor + 1
                ceil(
                    sourceLong.toDouble() *
                        preEvenShort.toDouble() /
                        sourceShort.toDouble()
                ).toInt()
            }
                .let { if (it % 2 == 0) it else it + 1 }
                .coerceAtMost(sourceLong)

        return maxOf(pressureSide, readableLong)
    }

    /**
     * Fast temporal safety valve for synchronous GPU -> I420 readback.
     *
     * SurfaceTextureHelper permits only one texture frame in flight. A fallback
     * copy that consumes a full 60 Hz frame period can therefore withhold the
     * next primary capture frame even though RTP received the current frame
     * first. React after the FIRST measured over-budget copy by spacing future
     * fallback samples far enough that recovery readback cannot monopolize the
     * producer callback. Pixel downshift still requires two votes.
     *
     * Returning zero means no extra readback-derived cadence floor.
     */
    fun minimumIntervalMs(): Long {
        val costMs = lastCopyCostMs
        if (costMs < OVERLOAD_COPY_MS) return 0L
        return (costMs * READBACK_INTERVAL_MULTIPLIER)
            .coerceIn(
                MIN_PRESSURED_INTERVAL_MS,
                MAX_PRESSURED_INTERVAL_MS
            )
    }

    /**
     * Observe only successful copy operations. Return the new pressure tier
     * on a transition, or null when the image envelope remains unchanged.
     * Sampling gaps cannot be accumulated into false consecutive evidence.
     */
    @Synchronized
    fun observe(copyCostMs: Long, nowMs: Long): Int? {
        if (copyCostMs < 0L || nowMs < 0L) return null
        lastCopyCostMs = copyCostMs
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
        lastCopyCostMs = 0L
    }

    private companion object {
        /*
         * A synchronous copy at or above one 60 Hz frame period is already
         * capable of withholding a producer frame. The old 30 ms threshold
         * left a 17..29 ms blind band that could visibly hitch 60 fps capture.
         */
        const val OVERLOAD_COPY_MS = 17L
        const val HEALTHY_COPY_MS = 8L

        /*
         * Keep measured fallback readback below roughly 25% capture-thread duty
         * cycle while it is expensive. This is a recovery lane, so protecting
         * primary RTP freshness takes precedence over fallback FPS.
         */
        const val READBACK_INTERVAL_MULTIPLIER = 4L
        const val MIN_PRESSURED_INTERVAL_MS = 68L
        const val MAX_PRESSURED_INTERVAL_MS = 300L
        const val OVERLOAD_VOTES = 2
        const val RECOVERY_VOTES = 10
        const val MAX_LEVEL = 2
        const val MAX_EVIDENCE_GAP_MS = 2_000L
        const val DOWNSHIFT_HOLD_MS = 2_000L
        const val RECOVERY_HOLD_MS = 15_000L
    }
}
