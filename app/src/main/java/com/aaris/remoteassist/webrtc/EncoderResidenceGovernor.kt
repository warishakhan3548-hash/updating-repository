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

    /**
     * True while measured encoder residence says stale pixels are more expensive
     * than a temporary spatial-quality trade. The host composes this with direct
     * user interaction so passive high-motion content (video/game animation) can
     * enter the same freshness-first path without pretending a finger is down.
     */
    @Volatile
    var freshnessPriority: Boolean = false
        private set

    private var pressureWindows = 0
    private var healthyWindows = 0
    private var changedAtMs = Long.MIN_VALUE / 2

    private var freshnessPressureWindows = 0
    private var freshnessHealthyWindows = 0
    private var freshnessSparseWindows = 0
    private var freshnessChangedAtMs = Long.MIN_VALUE / 2

    fun observe(
        snapshot: StalenessShadowSnapshot,
        requestedFps: Int,
        nowMs: Long
    ): Boolean {
        /*
         * A sparse/static source is not proof of encoder pressure. It must not
         * change the cadence cap, but it is useful negative evidence for the
         * short-lived freshness mode: once video motion stops, return to the
         * clarity-first policy instead of leaving MAINTAIN_FRAMERATE latched.
         */
        if (snapshot.evaluatedFrames < MIN_EVALUATED_FRAMES) {
            pressureWindows = 0
            freshnessPressureWindows = 0
            freshnessHealthyWindows = 0

            if (freshnessPriority) {
                freshnessSparseWindows += 1
                maybeReleaseFreshnessPriority(
                    nowMs = nowMs,
                    evidenceWindows = freshnessSparseWindows,
                    requiredWindows = FRESHNESS_SPARSE_WINDOWS_TO_RELEASE
                )
            } else {
                freshnessSparseWindows = 0
            }
            return false
        }

        freshnessSparseWindows = 0

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
            freshnessHealthyWindows = 0
            freshnessPressureWindows =
                (freshnessPressureWindows + if (severe) 2 else 1)
                    .coerceAtMost(FRESHNESS_PRESSURE_WINDOWS_TO_ENGAGE)

            /*
             * Enter freshness-first mode before the slower cadence governor has
             * to reduce FPS. BoundedStalenessGate still owns actual source-frame
             * rejection, so enabling this mode at the first measured pressure
             * window cannot blindly drop healthy frames: its own 90/45ms
             * hysteresis decides admission. This lets passive YouTube/game motion
             * prefer a newer sample as soon as a real encoder backlog appears.
             */
            if (
                !freshnessPriority &&
                freshnessPressureWindows >= FRESHNESS_PRESSURE_WINDOWS_TO_ENGAGE
            ) {
                freshnessPriority = true
                freshnessChangedAtMs = nowMs
            }

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
        freshnessPressureWindows = 0

        val healthyThresholdMs =
            maxOf(MIN_HEALTHY_MS, frameBudgetMs * HEALTHY_FRAME_BUDGETS)
        val healthy =
            latestMs <= healthyThresholdMs &&
                maxMs <= healthyThresholdMs * HEALTHY_MAX_MULTIPLIER &&
                dropRatio <= HEALTHY_SHADOW_DROP_RATIO

        if (freshnessPriority) {
            freshnessHealthyWindows =
                if (healthy) freshnessHealthyWindows + 1 else 0
            maybeReleaseFreshnessPriority(
                nowMs = nowMs,
                evidenceWindows = freshnessHealthyWindows,
                requiredWindows = FRESHNESS_HEALTHY_WINDOWS_TO_RELEASE
            )
        } else {
            freshnessHealthyWindows = 0
        }

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

    private fun maybeReleaseFreshnessPriority(
        nowMs: Long,
        evidenceWindows: Int,
        requiredWindows: Int
    ) {
        if (
            freshnessPriority &&
            evidenceWindows >= requiredWindows &&
            nowMs - freshnessChangedAtMs >= FRESHNESS_MIN_HOLD_MS
        ) {
            freshnessPriority = false
            freshnessChangedAtMs = nowMs
            freshnessPressureWindows = 0
            freshnessHealthyWindows = 0
            freshnessSparseWindows = 0
        }
    }

    fun resetFreshnessPriority() {
        freshnessPriority = false
        freshnessPressureWindows = 0
        freshnessHealthyWindows = 0
        freshnessSparseWindows = 0
        freshnessChangedAtMs = Long.MIN_VALUE / 2
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

        // Freshness mode reacts sooner than a cadence reduction, because it
        // merely changes degradation/admission preference. Recovery is slower
        // and evidence-based so video playback cannot flap between policies.
        const val FRESHNESS_PRESSURE_WINDOWS_TO_ENGAGE = 1
        const val FRESHNESS_HEALTHY_WINDOWS_TO_RELEASE = 4
        const val FRESHNESS_SPARSE_WINDOWS_TO_RELEASE = 4
        const val FRESHNESS_MIN_HOLD_MS = 1_500L

        const val CHANGE_INTERVAL_MS = 750L
        const val SEVERE_CHANGE_INTERVAL_MS = 500L
        const val RECOVERY_INTERVAL_MS = 5_000L
        const val STRONG_RELIEF_MAX_FPS = 30
    }
}
