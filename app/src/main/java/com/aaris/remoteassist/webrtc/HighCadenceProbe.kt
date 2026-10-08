package com.aaris.remoteassist.webrtc

import kotlin.math.max

/**
 * Fine-grained cadence controller for the 30..60 fps interactive range.
 *
 * This is deliberately not a bandwidth estimator. Libwebrtc still owns GCC,
 * pacing and bitrate. The controller only adjusts the sender cadence ceiling
 * using end-to-end evidence: producer headroom, encoder/decoder residence,
 * sender queue, RTT/loss and real EGL swaps from the controller.
 *
 * Promotion is additive and cautious. Relief is proportional:
 * - tiny/random misses are tolerated,
 * - sustained mild misses trim only a few fps,
 * - severe pipeline pressure can fall back aggressively.
 *
 * Each real EGL presentation sample can vote only once. Retained samples are
 * liveness/diagnostic evidence, never duplicate adaptation votes.
 */
internal class HighCadenceProbe {
    private var previousCap = 0
    private var lastSampleAtMs = Long.MIN_VALUE / 2
    private var candidateSinceMs = 0L
    private var healthyWindows = 0
    private var blockedUntilMs = 0L

    private val failedTrials = mutableMapOf<Int, Int>()
    private val retryAtMs = mutableMapOf<Int, Long>()

    private var trialFrom: Int? = null
    private var trialAtMs = 0L
    private var trialGood = 0
    private var trialBad = 0
    private var lastProofAtMs: Long? = null
    private var lastPresentationSequenceSeen = 0L

    val probing: Boolean get() = trialFrom != null

    fun debugSummary(nowMs: Long): String {
        fun remainingSeconds(deadlineMs: Long): String {
            val remaining = (deadlineMs - nowMs).coerceAtLeast(0L)
            return if (remaining == 0L) "ready" else "${(remaining + 999L) / 1_000L}s"
        }

        val trial =
            trialFrom?.let {
                "$it→$previousCap good=$trialGood bad=$trialBad"
            } ?: "idle"
        val next =
            nextHigher(previousCap.coerceAtLeast(MIN_FINE_CADENCE_FPS), 60)
        val retry =
            next?.let {
                "$it=${remainingSeconds(retryAtMs[it] ?: 0L)}(${failedTrials[it] ?: 0})"
            } ?: "top"

        return "fineProbe=$trial next=$retry"
    }

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
            if (previousCap > currentFps) {
                blockedUntilMs = nowMs + RETRY_COOLDOWN_MS
            }
            previousCap = currentFps
            trialFrom = null
            healthyWindows = 0
        }

        if (nowMs - lastSampleAtMs < MIN_SAMPLE_INTERVAL_MS) return null
        if (nowMs - lastSampleAtMs > MAX_SAMPLE_GAP_MS) healthyWindows = 0
        lastSampleAtMs = nowMs

        val sender = outbound.recent
        val refresh = receiver?.displayRefreshRateHz.valid()
        val displayLimit = refresh?.let { (it + 0.5).toInt() }
        val limit = minOf(maximumFps, displayLimit ?: 60)
        if (limit < currentFps) {
            val bounded =
                nearestAtOrBelow(limit)
                    .coerceAtLeast(1)
            return rollback(currentFps, nowMs, bounded)
        }

        val presented = receiver?.presentedFps.valid()
        val freshProof =
            receiver != null &&
                receiver.intervalMs in 500..6000 &&
                receiver.frames >= MIN_MEASURED_FRAMES &&
                receiver.presentationIntervalMs?.let { it in 500..6000 } == true &&
                presented != null &&
                receiver.presentationAgeMs?.let { it in 0..MAX_GLASS_PROOF_AGE_MS } == true &&
                receiver.presentationSampleAgeMs?.let { it in 0..MAX_GLASS_PROOF_AGE_MS } != false &&
                refresh != null

        val presentationSequence =
            receiver?.presentationSampleSequence
                ?.takeIf { it > 0L }
        val newPresentationProof =
            freshProof &&
                // No-sequence legacy samples still require an actual NEW glass
                // measurement. A retained sample must never vote repeatedly.
                receiver?.presentationSampleFresh != false &&
                (
                    presentationSequence == null ||
                        presentationSequence != lastPresentationSequenceSeen
                    )

        if (newPresentationProof) {
            presentationSequence?.let { lastPresentationSequenceSeen = it }
            val sampleAge =
                receiver?.presentationSampleAgeMs
                    ?.coerceAtLeast(0)
                    ?.toLong()
                    ?: 0L
            lastProofAtMs = nowMs - sampleAge
        }

        if (
            currentFps > MIN_FINE_CADENCE_FPS &&
            lastProofAtMs?.let { nowMs - it > LOST_GLASS_PROOF_ROLLBACK_MS } == true
        ) {
            return rollback(currentFps, nowMs, MIN_FINE_CADENCE_FPS)
        }

        val delivered =
            freshProof &&
                sender != null &&
                sender.intervalMs in 500..6000 &&
                sender.fps >= currentFps * MIN_SENDER_DELIVERY_RATIO &&
                receiver!!.fps >= currentFps * MIN_DECODER_DELIVERY_RATIO &&
                presented!! >= currentFps * MIN_PRESENTATION_DELIVERY_RATIO &&
                receiver.maxRenderGapMs?.let {
                    it in 0..maxOf(
                        MIN_ACCEPTABLE_RENDER_GAP_MS,
                        (MAX_RENDER_GAP_FRAME_MULTIPLIER * 1_000.0 / currentFps)
                            .toInt()
                    )
                } == true &&
                receiver.dropped?.let {
                    it <= toleratedDrops(receiver.frames)
                } == true &&
                receiver.freezes == 0

        if (trialFrom != null) {
            if (overloaded) {
                return rollback(
                    currentFps = currentFps,
                    nowMs = nowMs,
                    countTrialFailure = true
                )
            }

            if (nowMs - trialAtMs >= TRIAL_SETTLE_MS) {
                if (newPresentationProof) {
                    trialGood =
                        if (delivered) {
                            (trialGood + 1).coerceAtMost(TRIAL_GOOD_REQUIRED)
                        } else {
                            0
                        }
                    trialBad =
                        if (delivered) {
                            0
                        } else {
                            (trialBad + 1).coerceAtMost(TRIAL_BAD_LIMIT)
                        }
                }

                if (trialBad >= TRIAL_BAD_LIMIT || nowMs - trialAtMs >= TRIAL_TIMEOUT_MS) {
                    return rollback(
                        currentFps = currentFps,
                        nowMs = nowMs,
                        countTrialFailure = true
                    )
                }

                if (trialGood >= TRIAL_GOOD_REQUIRED) {
                    clearFailedTrial(currentFps)
                    trialFrom = null
                    healthyWindows = 0
                }
            }
            return null
        }

        val next = nextHigher(currentFps, limit)
        val nextBudgetMs = next?.let { 1_000.0 / it } ?: 0.0
        val eligible =
            next != null &&
                allowProbe &&
                !overloaded &&
                nowMs >= blockedUntilMs &&
                !probeRetryBlocked(next, nowMs) &&
                delivered &&
                producerFps.valid()?.let { it >= next * MIN_PRODUCER_HEADROOM_RATIO } == true &&
                sender?.processingMs.valid()?.let {
                    it <= nextBudgetMs * MAX_CODEC_BUDGET_RATIO
                } == true &&
                receiver?.processingMs.valid()?.let {
                    it <= nextBudgetMs * MAX_CODEC_BUDGET_RATIO
                } == true &&
                sender?.sendQueueMs.valid()?.let {
                    it <= MAX_PROBE_QUEUE_MS
                } == true &&
                receiver?.jitterMs.valid()?.let {
                    it <= MAX_PROBE_JITTER_MS
                } == true &&
                outbound.qualityLimitationReason.equals("none", ignoreCase = true) &&
                outbound.roundTripTimeMs?.let { it in 0..MAX_PROBE_RTT_MS } == true &&
                outbound.packetLossRatio.valid()?.let {
                    it < MAX_PROBE_PACKET_LOSS
                } == true

        if (!eligible) {
            if (newPresentationProof || !freshProof || overloaded) {
                healthyWindows = 0
            }
            return null
        }

        if (!newPresentationProof) return null

        if (healthyWindows++ == 0) candidateSinceMs = nowMs
        val required = promotionWindows(next!!)
        if (
            healthyWindows < required ||
            nowMs - candidateSinceMs < (required - 1) * MIN_PROMOTION_WINDOW_SPACING_MS
        ) {
            return null
        }

        trialFrom = currentFps
        trialAtMs = nowMs
        trialGood = 0
        trialBad = 0
        healthyWindows = 0
        previousCap = next
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

        val trialBase = trialFrom
        val fallback =
            minOf(
                target
                    ?: trialBase
                    ?: previousLower(currentFps)
                    ?: MIN_FINE_CADENCE_FPS,
                currentFps
            )

        trialFrom = null
        healthyWindows = 0
        blockedUntilMs = nowMs + RETRY_COOLDOWN_MS
        previousCap = fallback
        return fallback
    }

    /*
     * Promotion and relief are intentionally asymmetric.
     *
     * On a proven-clean interactive path, climbing every tiny rung keeps a
     * capable 60 Hz phone visibly stuck in 30-45 fps for too long. Promotion
     * therefore uses moderately spaced evidence-backed steps.
     *
     * Relief remains finer grained: when pressure appears at 60 fps we still
     * trim to 58, then 55, etc. That preserves smoothness instead of turning a
     * small transient into a visible cliff.
     */
    private fun nextHigher(currentFps: Int, limit: Int): Int? =
        ASCENDING_CADENCE_STEPS.firstOrNull {
            it > currentFps && it <= limit
        }

    private fun previousLower(currentFps: Int): Int? =
        DESCENDING_CADENCE_STEPS
            .firstOrNull { it < currentFps }

    private fun nearestAtOrBelow(limit: Int): Int =
        DESCENDING_CADENCE_STEPS
            .firstOrNull { it <= limit }
            ?: minOf(limit, MIN_FINE_CADENCE_FPS)

    private fun toleratedDrops(frames: Int): Int =
        when {
            frames >= 50 -> 2
            frames >= 24 -> 1
            else -> 0
        }

    private fun promotionWindows(targetFps: Int): Int =
        when {
            targetFps >= 58 -> 3
            targetFps >= 50 -> 2
            else -> 2
        }

    private fun probeRetryBlocked(targetFps: Int, nowMs: Long): Boolean =
        nowMs < (retryAtMs[targetFps] ?: 0L)

    private fun recordFailedTrial(targetFps: Int, nowMs: Long) {
        if (targetFps <= MIN_FINE_CADENCE_FPS) return
        val failures =
            ((failedTrials[targetFps] ?: 0) + 1)
                .coerceAtMost(MAX_TRACKED_TRIAL_FAILURES)
        failedTrials[targetFps] = failures

        val exponent =
            (failures - 1)
                .coerceIn(0, MAX_PROBE_BACKOFF_EXPONENT)
        val cooldownMs =
            (RETRY_COOLDOWN_MS * (1L shl exponent))
                .coerceAtMost(MAX_RETRY_COOLDOWN_MS)
        retryAtMs[targetFps] = nowMs + cooldownMs
    }

    private fun clearFailedTrial(targetFps: Int) {
        failedTrials.remove(targetFps)
        retryAtMs.remove(targetFps)
    }

    private fun Double?.valid(): Double? =
        this?.takeIf { it.isFinite() && it >= 0.0 }

    private companion object {
        val ASCENDING_CADENCE_STEPS =
            listOf(30, 36, 40, 45, 50, 55, 60)
        val DESCENDING_CADENCE_STEPS =
            listOf(60, 58, 55, 50, 45, 40, 36, 33, 30)

        const val MIN_FINE_CADENCE_FPS = 30
        const val MIN_SAMPLE_INTERVAL_MS = 500L
        const val MAX_SAMPLE_GAP_MS = 6_000L
        const val MAX_GLASS_PROOF_AGE_MS = 1_000
        const val LOST_GLASS_PROOF_ROLLBACK_MS = 3_000L
        const val MIN_MEASURED_FRAMES = 5

        const val MIN_SENDER_DELIVERY_RATIO = 0.90
        const val MIN_DECODER_DELIVERY_RATIO = 0.88
        const val MIN_PRESENTATION_DELIVERY_RATIO = 0.88
        const val MIN_PRODUCER_HEADROOM_RATIO = 0.92
        const val MAX_CODEC_BUDGET_RATIO = 0.78
        const val MAX_PROBE_QUEUE_MS = 25.0
        const val MAX_PROBE_JITTER_MS = 45.0
        const val MAX_PROBE_RTT_MS = 300
        const val MAX_PROBE_PACKET_LOSS = 0.025

        const val MIN_ACCEPTABLE_RENDER_GAP_MS = 50
        const val MAX_RENDER_GAP_FRAME_MULTIPLIER = 2.5

        const val TRIAL_SETTLE_MS = 900L
        const val TRIAL_TIMEOUT_MS = 6_000L
        const val TRIAL_GOOD_REQUIRED = 2
        const val TRIAL_BAD_LIMIT = 2
        const val MIN_PROMOTION_WINDOW_SPACING_MS = 500L

        const val RETRY_COOLDOWN_MS = 4_000L
        const val MAX_PROBE_BACKOFF_EXPONENT = 4
        const val MAX_TRACKED_TRIAL_FAILURES = MAX_PROBE_BACKOFF_EXPONENT + 1
        const val MAX_RETRY_COOLDOWN_MS = 64_000L
    }
}
