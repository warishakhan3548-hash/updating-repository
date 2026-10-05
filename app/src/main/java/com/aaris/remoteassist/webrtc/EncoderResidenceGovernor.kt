package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.StalenessShadowSnapshot

/**
 * Fast protective cadence guard driven by the encoder-side residence shadow.
 *
 * libwebrtc remains authoritative for bandwidth estimation, pacing and bitrate.
 * This governor only limits capture cadence when the already-instrumented
 * encoder model shows fresh frames are starting to queue behind old ones.
 *
 * Unlike dropping captured frames, reducing the source cadence keeps the native
 * adaptation pipeline intact and is safe to roll back immediately. Hysteresis
 * prevents one large keyframe or transient rate-allocation change from causing
 * a visible cadence collapse.
 */
internal class EncoderResidenceGovernor(
    private val maxFps: Int,
    initialCap: Int = maxFps
) {
    @Volatile
    var cap: Int = initialCap.coerceIn(MIN_CAP_FPS, maxFps)
        private set

    private var pressureWindows = 0
    private var healthyWindows = 0
    private var changedAtMs = Long.MIN_VALUE / 2

    fun observe(
        snapshot: StalenessShadowSnapshot,
        requestedFps: Int,
        nowMs: Long
    ): Boolean {
        if (snapshot.evaluatedFrames < MIN_EVALUATED_FRAMES) {
            pressureWindows = 0
            return false
        }

        val desired = requestedFps.coerceIn(MIN_CAP_FPS, maxFps)
        val expected = minOf(desired, cap).coerceAtLeast(MIN_CAP_FPS)
        val frameBudgetMs = 1_000.0 / expected.toDouble()
        val latestMs = snapshot.latestQueueDelayMs ?: return false
        val maxMs = snapshot.maxQueueDelayMs ?: latestMs
        val dropRatio = snapshot.wouldDropRatio

        val pressureThresholdMs =
            maxOf(MIN_PRESSURE_MS, frameBudgetMs * PRESSURE_FRAME_BUDGETS)
        val severeThresholdMs =
            maxOf(MIN_SEVERE_MS, frameBudgetMs * SEVERE_FRAME_BUDGETS)

        val severe =
            maxMs >= severeThresholdMs ||
                dropRatio >= SEVERE_SHADOW_DROP_RATIO
        val pressured =
            severe ||
                latestMs >= pressureThresholdMs ||
                maxMs >= pressureThresholdMs * MAX_WINDOW_PRESSURE_MULTIPLIER ||
                dropRatio >= SHADOW_DROP_RATIO

        if (pressured) {
            healthyWindows = 0
            pressureWindows =
                (pressureWindows + if (severe) 2 else 1)
                    .coerceAtMost(PRESSURE_WINDOWS_TO_REDUCE)

            val interval =
                if (severe) SEVERE_CHANGE_INTERVAL_MS
                else CHANGE_INTERVAL_MS
            if (
                pressureWindows < PRESSURE_WINDOWS_TO_REDUCE ||
                nowMs - changedAtMs < interval
            ) {
                return false
            }

            val ceiling = minOf(cap, desired)
            val next = DESCENDING_CAPS.firstOrNull { candidate ->
                candidate < ceiling &&
                    (!severe || candidate <= STRONG_RELIEF_MAX_FPS)
            } ?: return false

            cap = next
            changedAtMs = nowMs
            pressureWindows = 0
            return true
        }

        pressureWindows = 0

        val healthyThresholdMs =
            maxOf(MIN_HEALTHY_MS, frameBudgetMs * HEALTHY_FRAME_BUDGETS)
        val healthy =
            latestMs <= healthyThresholdMs &&
                maxMs <= healthyThresholdMs * HEALTHY_MAX_MULTIPLIER &&
                dropRatio <= HEALTHY_SHADOW_DROP_RATIO

        healthyWindows = if (healthy) healthyWindows + 1 else 0
        if (
            healthyWindows < HEALTHY_WINDOWS_TO_RAISE ||
            cap >= desired ||
            nowMs - changedAtMs < RECOVERY_INTERVAL_MS
        ) {
            return false
        }

        val next = ASCENDING_CAPS.firstOrNull {
            it > cap && it <= desired && it <= maxFps
        } ?: return false

        cap = next
        changedAtMs = nowMs
        healthyWindows = 0
        return true
    }

    private companion object {
        val DESCENDING_CAPS = listOf(60, 45, 30, 24, 20, 15)
        val ASCENDING_CAPS = listOf(15, 20, 24, 30, 45, 60)

        const val MIN_CAP_FPS = 15
        const val MIN_EVALUATED_FRAMES = 3L

        // Queue residence is intentionally judged in frame budgets as well as
        // absolute milliseconds so 60 Hz interaction reacts sooner than 30 Hz.
        const val MIN_PRESSURE_MS = 70.0
        const val PRESSURE_FRAME_BUDGETS = 4.0
        const val MIN_SEVERE_MS = 140.0
        const val SEVERE_FRAME_BUDGETS = 7.0
        const val MAX_WINDOW_PRESSURE_MULTIPLIER = 1.35

        const val SHADOW_DROP_RATIO = 0.30
        const val SEVERE_SHADOW_DROP_RATIO = 0.65
        const val HEALTHY_SHADOW_DROP_RATIO = 0.05

        const val MIN_HEALTHY_MS = 24.0
        const val HEALTHY_FRAME_BUDGETS = 1.5
        const val HEALTHY_MAX_MULTIPLIER = 1.7

        const val PRESSURE_WINDOWS_TO_REDUCE = 2
        const val HEALTHY_WINDOWS_TO_RAISE = 8
        const val CHANGE_INTERVAL_MS = 750L
        const val SEVERE_CHANGE_INTERVAL_MS = 500L
        const val RECOVERY_INTERVAL_MS = 5_000L
        const val STRONG_RELIEF_MAX_FPS = 30
    }
}
