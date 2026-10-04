package com.aaris.remoteassist.webrtc

/**
 * Fast controller-presentation loop for remote-control UX.
 *
 * This deliberately does not inspect full RTCStats and does not own bitrate.
 * It reacts only to real EGL presentation cadence arriving from the controller,
 * allowing one immediate 60 -> 45 freshness step (or <=30 on a severe stall)
 * without waiting for the host's slower stats cycle. Recovery is asymmetric and
 * requires several clean windows, so unstable Wi-Fi cannot oscillate 45/60.
 */
internal class FastPresentationGovernor(
    private val maxFps: Int,
    initialCap: Int = maxFps
) {
    @Volatile
    var cap: Int = initialCap.coerceIn(MIN_CAP_FPS, maxFps)
        private set

    private var healthyWindows = 0
    private var pressuredWindows = 0
    private var changedAtMs = Long.MIN_VALUE / 2

    fun observe(
        window: PresentationCadenceWindow,
        desiredFps: Int,
        nowMs: Long
    ): Boolean {
        val desired = desiredFps.coerceIn(MIN_CAP_FPS, maxFps)
        val expected = minOf(desired, cap)
        if (
            expected < MIN_EXPECTED_FPS ||
            window.renderedFrames < MIN_PRESENTED_FRAMES
        ) {
            healthyWindows = 0
            pressuredWindows = 0
            return false
        }

        val budgetMs = 1_000.0 / expected.toDouble()
        val deliveryRatio = window.fps / expected.toDouble()
        val softGapMs = maxOf(
            MIN_SOFT_GAP_MS,
            budgetMs * SOFT_GAP_FRAME_MULTIPLIER
        )
        val healthyGapMs = maxOf(
            MIN_HEALTHY_GAP_MS,
            budgetMs * HEALTHY_GAP_FRAME_MULTIPLIER
        )

        val severe =
            deliveryRatio < SEVERE_DELIVERY_RATIO ||
                window.maxGapMs >= SEVERE_GAP_MS
        val pressured =
            deliveryRatio < SOFT_DELIVERY_RATIO ||
                window.maxGapMs > softGapMs

        if (severe) {
            healthyWindows = 0
            pressuredWindows = 0
            if (nowMs - changedAtMs < SEVERE_CHANGE_INTERVAL_MS) return false

            val next = DESCENDING_CAPS.firstOrNull {
                it < cap && it <= STRONG_RELIEF_MAX_FPS
            } ?: return false
            cap = next
            changedAtMs = nowMs
            return true
        }

        if (pressured) {
            healthyWindows = 0
            pressuredWindows += 1

            // Full 60 fps gets one immediate soft relief step because even one
            // half-second render hitch is very visible under a moving finger.
            if (
                cap >= HIGH_CADENCE_FPS &&
                nowMs - changedAtMs >= SOFT_CHANGE_INTERVAL_MS
            ) {
                cap = SOFT_RELIEF_FPS
                changedAtMs = nowMs
                pressuredWindows = 0
                return true
            }

            // At lower cadence, require two consecutive bad EGL windows. This
            // reacts to sustained stutter without letting one GC/compositor blip
            // collapse quality from 45 to 30.
            if (
                pressuredWindows >= SUSTAINED_PRESSURE_WINDOWS_TO_REDUCE &&
                nowMs - changedAtMs >= SUSTAINED_CHANGE_INTERVAL_MS
            ) {
                val next = DESCENDING_CAPS.firstOrNull { it < cap }
                    ?: return false
                cap = next
                changedAtMs = nowMs
                pressuredWindows = 0
                return true
            }

            return false
        }

        pressuredWindows = 0
        val healthy =
            deliveryRatio >= HEALTHY_DELIVERY_RATIO &&
                window.maxGapMs < healthyGapMs
        healthyWindows = if (healthy) healthyWindows + 1 else 0

        if (
            healthyWindows < HEALTHY_WINDOWS_TO_PROBE ||
            nowMs - changedAtMs < RECOVERY_INTERVAL_MS ||
            cap >= desired
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
        const val MIN_EXPECTED_FPS = 10
        const val MIN_PRESENTED_FRAMES = 5

        const val HIGH_CADENCE_FPS = 60
        const val SOFT_RELIEF_FPS = 45
        const val STRONG_RELIEF_MAX_FPS = 30

        const val SOFT_DELIVERY_RATIO = 0.82
        const val SEVERE_DELIVERY_RATIO = 0.60
        const val HEALTHY_DELIVERY_RATIO = 0.92

        const val MIN_SOFT_GAP_MS = 55.0
        const val SOFT_GAP_FRAME_MULTIPLIER = 2.5
        const val SEVERE_GAP_MS = 150
        const val MIN_HEALTHY_GAP_MS = 45.0
        const val HEALTHY_GAP_FRAME_MULTIPLIER = 3.0

        const val SOFT_CHANGE_INTERVAL_MS = 500L
        const val SEVERE_CHANGE_INTERVAL_MS = 500L
        const val SUSTAINED_PRESSURE_WINDOWS_TO_REDUCE = 2
        const val SUSTAINED_CHANGE_INTERVAL_MS = 1_000L
        const val HEALTHY_WINDOWS_TO_PROBE = 4
        const val RECOVERY_INTERVAL_MS = 2_000L
    }
}
