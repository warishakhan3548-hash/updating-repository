package com.aaris.remoteassist.webrtc

/**
 * Bounded experiments above 30 fps, never a bandwidth estimator. Promotion
 * needs fresh decode AND EGL-swap feedback at the current rate; demanding the
 * proposed rate before sending it would deadlock every promotion. The raw
 * producer is measured before VideoSource's FPS adapter.
 *
 * Codec stats are interval averages, not p95 or a serial throughput limit.
 * They conservatively gate experiments; actual delivery validates the trial.
 * EGL swaps are a presentation proxy, not a physical scanout measurement.
 */
internal class HighCadenceProbe {
    private var previousCap = 0
    private var lastSampleAtMs = Long.MIN_VALUE / 2
    private var candidateSinceMs = 0L
    private var healthyWindows = 0
    private var blockedUntilMs = 0L

    /*
     * Failed >30-fps experiments are capability evidence, not just transient
     * congestion. Some Android hardware/driver paths repeatedly fall back to
     * ~30-fps delivery even when capture can produce 45/60 fps. Re-running the
     * same doomed trial every few seconds wastes encoder/pacer work and creates
     * the exact micro-stutter this governor is meant to avoid.
     *
     * Keep the two experimental rungs independent: a failed 60-fps trial must
     * not make a later 45-fps recovery sluggish, and a proven rung immediately
     * clears its own learned penalty.
     */
    private var failed45Trials = 0
    private var failed60Trials = 0
    private var retry45AtMs = 0L
    private var retry60AtMs = 0L

    private var trialFrom: Int? = null
    private var trialAtMs = 0L
    private var trialGood = 0
    private var trialBad = 0
    private var lastProofAtMs: Long? = null

    val probing: Boolean get() = trialFrom != null

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        producerFps: Double?,
        currentFps: Int,
        maximumFps: Int,
        allowProbe: Boolean,
        overloaded: Boolean,
        nowMs: Long
    ): Int? {
        if (currentFps != previousCap) {
            if (previousCap > currentFps) blockedUntilMs = nowMs + RETRY_COOLDOWN_MS
            previousCap = currentFps
            trialFrom = null
            healthyWindows = 0
        }
        if (nowMs - lastSampleAtMs < 500L) return null
        if (nowMs - lastSampleAtMs > 6_000L) healthyWindows = 0
        lastSampleAtMs = nowMs

        val sender = outbound.recent
        val refresh = receiver?.displayRefreshRateHz.valid()
        val displayLimit = refresh?.let { (it + 0.5).toInt() }
        val limit = minOf(maximumFps, displayLimit ?: 60)
        if (limit < currentFps) {
            val bounded = listOf(60, 45, 30, 24, 20, 15).firstOrNull { it <= limit }
                ?: limit.coerceAtLeast(1)
            return rollback(currentFps, nowMs, bounded)
        }

        val presented = receiver?.presentedFps.valid()
        val freshProof = receiver != null &&
            receiver.intervalMs in 500..6000 && receiver.frames >= 5 &&
            receiver.presentationIntervalMs?.let { it in 500..6000 } == true &&
            presented != null &&
            receiver.presentationAgeMs?.let { it in 0..1_000 } == true &&
            refresh != null
        if (freshProof) lastProofAtMs = nowMs
        if (currentFps > 30 && lastProofAtMs?.let { nowMs - it > 3_000L } == true) {
            return rollback(currentFps, nowMs, 30)
        }

        val delivered = freshProof && sender != null &&
            sender.intervalMs in 500..6000 &&
            sender.fps >= currentFps * 0.90 && receiver!!.fps >= currentFps * 0.90 &&
            presented!! >= currentFps * 0.90 &&
            receiver.maxRenderGapMs?.let { it in 0..maxOf(50, (2_200.0 / currentFps).toInt()) } == true &&
            receiver.dropped == 0 && receiver.freezes == 0

        if (trialFrom != null) {
            if (overloaded) {
                return rollback(
                    currentFps = currentFps,
                    nowMs = nowMs,
                    countTrialFailure = true
                )
            }
            // Allow one window for reports covering the previous cap to drain.
            if (nowMs - trialAtMs >= 1_000L) {
                trialGood = if (delivered) trialGood + 1 else 0
                trialBad = if (delivered) 0 else trialBad + 1
                if (trialBad >= 2 || nowMs - trialAtMs >= 6_000L) {
                    return rollback(
                        currentFps = currentFps,
                        nowMs = nowMs,
                        countTrialFailure = true
                    )
                }
                if (trialGood >= 2) {
                    clearFailedTrial(currentFps)
                    trialFrom = null
                    healthyWindows = 0
                }
            }
            return null
        }

        val next = when (currentFps) { 30 -> 45; 45 -> 60; else -> null }
        val nextBudget = next?.let { 1_000.0 / it } ?: 0.0
        val eligible = next != null && next <= limit && allowProbe && !overloaded &&
            nowMs >= blockedUntilMs &&
            !probeRetryBlocked(next, nowMs) &&
            delivered &&
            producerFps.valid()?.let { it >= next * 0.90 } == true &&
            sender?.processingMs.valid()?.let { it <= nextBudget * 0.70 } == true &&
            receiver?.processingMs.valid()?.let { it <= nextBudget * 0.70 } == true &&
            sender?.sendQueueMs.valid()?.let { it <= 20.0 } == true &&
            receiver?.jitterMs.valid()?.let { it <= 40.0 } == true &&
            outbound.qualityLimitationReason == "none" &&
            outbound.roundTripTimeMs?.let { it in 0..300 } == true &&
            outbound.packetLossRatio.valid()?.let { it < 0.025 } == true
        if (!eligible) {
            healthyWindows = 0
            return null
        }
        if (healthyWindows++ == 0) candidateSinceMs = nowMs
        /*
         * Promotion already requires end-to-end proof: producer headroom,
         * encoder + decoder budget, low sender residence, low jitter, clean
         * loss/RTT, and fresh EGL presentation. Waiting five to eight one-second
         * windows after all of that makes interaction feel artificially capped.
         *
         * Use a short bounded proof instead: two clean windows earn 45 fps and
         * three earn 60 fps. The trial path below still rolls back after two bad
         * windows, so speed-up is symmetric with fast failure recovery.
         */
        val required =
            if (next == 45) {
                PROMOTE_TO_45_HEALTHY_WINDOWS
            } else {
                PROMOTE_TO_60_HEALTHY_WINDOWS
            }
        if (
            healthyWindows < required ||
            nowMs - candidateSinceMs < (required - 1) * 1_000L
        ) {
            return null
        }

        trialFrom = currentFps
        trialAtMs = nowMs
        trialGood = 0
        trialBad = 0
        healthyWindows = 0
        previousCap = next!!
        return next
    }

    private fun rollback(
        currentFps: Int,
        nowMs: Long,
        target: Int? = null,
        countTrialFailure: Boolean = false
    ): Int {
        if (countTrialFailure && trialFrom != null) {
            recordFailedTrial(currentFps, nowMs)
        }

        val fallback = minOf(target ?: trialFrom ?: 30, currentFps)
        trialFrom = null
        healthyWindows = 0
        blockedUntilMs = nowMs + RETRY_COOLDOWN_MS
        previousCap = fallback
        return fallback
    }

    private fun probeRetryBlocked(targetFps: Int, nowMs: Long): Boolean =
        when (targetFps) {
            45 -> nowMs < retry45AtMs
            60 -> nowMs < retry60AtMs
            else -> false
        }

    private fun recordFailedTrial(targetFps: Int, nowMs: Long) {
        val failures =
            when (targetFps) {
                45 -> {
                    failed45Trials = (failed45Trials + 1).coerceAtMost(MAX_TRACKED_TRIAL_FAILURES)
                    failed45Trials
                }

                60 -> {
                    failed60Trials = (failed60Trials + 1).coerceAtMost(MAX_TRACKED_TRIAL_FAILURES)
                    failed60Trials
                }

                else -> return
            }

        val exponent = (failures - 1).coerceIn(0, MAX_PROBE_BACKOFF_EXPONENT)
        val cooldownMs =
            (RETRY_COOLDOWN_MS * (1L shl exponent))
                .coerceAtMost(MAX_RETRY_COOLDOWN_MS)
        val retryAtMs = nowMs + cooldownMs

        when (targetFps) {
            45 -> retry45AtMs = retryAtMs
            60 -> retry60AtMs = retryAtMs
        }
    }

    private fun clearFailedTrial(targetFps: Int) {
        when (targetFps) {
            45 -> {
                failed45Trials = 0
                retry45AtMs = 0L
            }

            60 -> {
                failed60Trials = 0
                retry60AtMs = 0L
            }
        }
    }

    private fun Double?.valid(): Double? = this?.takeIf { it.isFinite() && it >= 0.0 }

    private companion object {
        const val PROMOTE_TO_45_HEALTHY_WINDOWS = 2
        const val PROMOTE_TO_60_HEALTHY_WINDOWS = 3
        const val RETRY_COOLDOWN_MS = 8_000L
        const val MAX_PROBE_BACKOFF_EXPONENT = 3
        const val MAX_TRACKED_TRIAL_FAILURES = MAX_PROBE_BACKOFF_EXPONENT + 1
        const val MAX_RETRY_COOLDOWN_MS = 64_000L
    }
}
