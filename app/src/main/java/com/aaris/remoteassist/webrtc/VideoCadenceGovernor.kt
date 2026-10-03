package com.aaris.remoteassist.webrtc

/**
 * Bounds capture cost while libwebrtc remains the owner of bitrate, pacing and
 * congestion control. Freshness wins over nominal FPS: a sustainable 30 fps
 * screen is better remote-control UX than a queued/stuttering 60 fps stream.
 */
class VideoCadenceGovernor(private val maxFps: Int) {
    @Volatile
    var cap = maxFps
        private set

    private var pressure = 0
    private var healthy = 0
    private var changedAt = Long.MIN_VALUE / 2

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        requestedFps: Int,
        nowMs: Long
    ): Boolean {
        val sender = outbound.recent ?: return false
        val budgetMs = 1000.0 / requestedFps.coerceAtLeast(1)

        val codecPressure =
            (
                sender.frames >= MIN_MEASURED_FRAMES &&
                    (sender.processingMs ?: 0.0) > budgetMs * CODEC_PRESSURE_BUDGET_RATIO &&
                    sender.fps < requestedFps * FPS_DELIVERY_RATIO
                ) ||
                (
                    receiver != null &&
                        receiver.frames >= MIN_MEASURED_FRAMES &&
                        (receiver.processingMs ?: 0.0) > budgetMs * CODEC_PRESSURE_BUDGET_RATIO &&
                        receiver.fps < minOf(requestedFps.toDouble(), sender.fps) * FPS_DELIVERY_RATIO
                    )

        val loss = outbound.packetLossRatio ?: 0.0
        val receiverDropped = receiver?.dropped?.coerceAtLeast(0) ?: 0
        val receiverSamples = receiver?.let { it.frames.coerceAtLeast(0) + receiverDropped } ?: 0
        val receiverDropRatio = if (receiverSamples > 0) receiverDropped.toDouble() / receiverSamples else 0.0
        val receiverDrops =
            receiverDropped >= MIN_DROPPED_FRAMES_FOR_PRESSURE &&
                receiverSamples >= MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO &&
                receiverDropRatio >= RECEIVER_DROP_PRESSURE_RATIO

        val sendQueueMs = sender.sendQueueMs
        val receiverJitterMs = receiver?.jitterMs
        val queuePressureThresholdMs = maxOf(MIN_QUEUE_PRESSURE_MS, budgetMs * QUEUE_BUDGET_MULTIPLIER)
        val jitterPressureThresholdMs = maxOf(MIN_JITTER_PRESSURE_MS, budgetMs * JITTER_BUDGET_MULTIPLIER)
        val queuePressure = sendQueueMs != null && sendQueueMs > queuePressureThresholdMs
        val receiverDelay =
            receiver != null && receiver.frames >= MIN_MEASURED_FRAMES &&
                receiverJitterMs != null && receiverJitterMs > jitterPressureThresholdMs

        /*
         * RTP/decode counters can look healthy while the controller GPU is
         * visibly hitching. Compare actual EGL swaps against the cadence that
         * made it through sender + decoder, and use long swap gaps as direct
         * motion-to-photon pressure.
         */
        val presentedFrames = receiver?.presentedFrames ?: 0
        val presentedFps = receiver?.presentedFps
        val expectedPresentationFps = if (presentedFps != null) {
            var expected = minOf(requestedFps.toDouble(), sender.fps)
            if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) {
                expected = minOf(expected, receiver.fps)
            }
            expected
        } else 0.0
        val presentationRatio =
            if (presentedFps != null && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS) {
                presentedFps / expectedPresentationFps
            } else 1.0
        val renderGapMs = receiver?.maxRenderGapMs?.toDouble() ?: 0.0
        val renderGapPressureMs = maxOf(MIN_RENDER_GAP_PRESSURE_MS, budgetMs * RENDER_GAP_BUDGET_MULTIPLIER)
        val presentationMeasured =
            presentedFrames >= MIN_PRESENTED_FRAMES && expectedPresentationFps >= MIN_PRESENTATION_EXPECTED_FPS
        val presentationPressure =
            presentationMeasured &&
                (presentationRatio < PRESENTATION_DELIVERY_RATIO || renderGapMs > renderGapPressureMs)

        val congestion =
            loss >= PACKET_LOSS_PRESSURE_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= RTT_PRESSURE_MS ||
                queuePressure || receiverDelay

        val severePresentationPressure =
            presentationMeasured &&
                (presentationRatio < SEVERE_PRESENTATION_DELIVERY_RATIO || renderGapMs >= SEVERE_RENDER_GAP_MS)
        val severePressure =
            loss >= SEVERE_PACKET_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= SEVERE_RTT_MS ||
                (sendQueueMs ?: 0.0) >= SEVERE_QUEUE_MS ||
                (receiverJitterMs ?: 0.0) >= SEVERE_JITTER_MS ||
                receiverDropRatio >= SEVERE_RECEIVER_DROP_RATIO ||
                severePresentationPressure

        val overloaded =
            codecPressure || receiverDrops || congestion || presentationPressure ||
                outbound.qualityLimitationReason == "cpu"

        if (overloaded) {
            healthy = 0
            pressure = (pressure + if (severePressure) 2 else 1).coerceAtMost(PRESSURE_SAMPLES_TO_REDUCE)
            val changeInterval = if (severePressure) SEVERE_CHANGE_INTERVAL_MS else MIN_CHANGE_INTERVAL_MS
            if (pressure < PRESSURE_SAMPLES_TO_REDUCE || nowMs - changedAt < changeInterval) return false

            val ceiling = minOf(cap, requestedFps)
            val ordinaryNext = DESCENDING_CAPS.firstOrNull { it < ceiling } ?: return false
            val next = if (severePressure) {
                val delivered = buildList {
                    if (sender.frames >= MIN_MEASURED_FRAMES) add(sender.fps)
                    if (receiver != null && receiver.frames >= MIN_MEASURED_FRAMES) add(receiver.fps)
                    if (presentationMeasured && presentedFps != null) add(presentedFps)
                }.minOrNull()
                val guarded = delivered?.times(SEVERE_OBSERVED_HEADROOM)?.toInt()
                if (guarded == null) ordinaryNext
                else DESCENDING_CAPS.firstOrNull { it < ceiling && it <= guarded } ?: ordinaryNext
            } else ordinaryNext

            cap = next
            changedAt = nowMs
            pressure = 0
            return true
        }

        pressure = 0

        val presentationHealthy =
            !presentationMeasured ||
                (presentationRatio >= HEALTHY_PRESENTATION_RATIO &&
                    renderGapMs < maxOf(HEALTHY_RENDER_GAP_MS, budgetMs * HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER))
        val receiverHealthy =
            if (receiver == null) {
                outbound.qualityLimitationReason == "none" &&
                    outbound.roundTripTimeMs != null && outbound.roundTripTimeMs < HEALTHY_RTT_MS
            } else {
                receiver.frames >= MIN_MEASURED_FRAMES &&
                    receiver.processingMs != null &&
                    receiver.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                    (receiver.jitterMs ?: 0.0) < HEALTHY_JITTER_MS &&
                    (receiver.dropped ?: 0) == 0 &&
                    (receiver.freezes ?: 0) == 0 &&
                    presentationHealthy
            }

        val headroom =
            sender.frames >= MIN_MEASURED_FRAMES &&
                sender.processingMs != null && sender.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                receiverHealthy && loss < HEALTHY_PACKET_LOSS_RATIO &&
                (sender.sendQueueMs ?: 0.0) < HEALTHY_QUEUE_MS &&
                outbound.qualityLimitationReason != "bandwidth"

        healthy = if (headroom) healthy + 1 else 0
        val healthySamplesRequired = if (receiver == null) LEGACY_HEALTHY_SAMPLES_TO_RAISE else HEALTHY_SAMPLES_TO_RAISE
        if (healthy < healthySamplesRequired || nowMs - changedAt < MIN_RECOVERY_INTERVAL_MS) return false

        val next = ASCENDING_CAPS.firstOrNull { it > cap && it <= maxFps } ?: return false
        cap = next
        changedAt = nowMs
        healthy = 0
        return true
    }

    fun mayReduceResolution(nowMs: Long): Boolean =
        cap <= RESOLUTION_REDUCTION_MAX_FPS && nowMs - changedAt >= RESOLUTION_REDUCTION_GRACE_MS

    private companion object {
        val DESCENDING_CAPS = listOf(60, 30, 24, 20, 15)
        val ASCENDING_CAPS = listOf(15, 20, 24, 30, 60)

        const val MIN_MEASURED_FRAMES = 5
        const val MIN_DROPPED_FRAMES_FOR_PRESSURE = 2
        const val MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO = 8
        const val MIN_PRESENTED_FRAMES = 5
        const val MIN_PRESENTATION_EXPECTED_FPS = 10.0

        const val CODEC_PRESSURE_BUDGET_RATIO = 0.85
        const val CODEC_HEADROOM_BUDGET_RATIO = 0.55
        const val FPS_DELIVERY_RATIO = 0.85

        const val MIN_QUEUE_PRESSURE_MS = 55.0
        const val QUEUE_BUDGET_MULTIPLIER = 2.0
        const val MIN_JITTER_PRESSURE_MS = 85.0
        const val JITTER_BUDGET_MULTIPLIER = 2.5
        const val MIN_RENDER_GAP_PRESSURE_MS = 55.0
        const val RENDER_GAP_BUDGET_MULTIPLIER = 2.5
        const val PRESENTATION_DELIVERY_RATIO = 0.82

        const val PACKET_LOSS_PRESSURE_RATIO = 0.04
        const val RTT_PRESSURE_MS = 650
        const val RECEIVER_DROP_PRESSURE_RATIO = 0.08

        const val SEVERE_PACKET_LOSS_RATIO = 0.12
        const val SEVERE_RTT_MS = 900
        const val SEVERE_QUEUE_MS = 150.0
        const val SEVERE_JITTER_MS = 180.0
        const val SEVERE_RECEIVER_DROP_RATIO = 0.25
        const val SEVERE_PRESENTATION_DELIVERY_RATIO = 0.60
        const val SEVERE_RENDER_GAP_MS = 150.0
        const val SEVERE_OBSERVED_HEADROOM = 1.10

        const val HEALTHY_RTT_MS = 300
        const val HEALTHY_JITTER_MS = 45.0
        const val HEALTHY_QUEUE_MS = 20.0
        const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        const val HEALTHY_PRESENTATION_RATIO = 0.90
        const val HEALTHY_RENDER_GAP_MS = 50.0
        const val HEALTHY_RENDER_GAP_BUDGET_MULTIPLIER = 3.0

        const val PRESSURE_SAMPLES_TO_REDUCE = 2
        const val HEALTHY_SAMPLES_TO_RAISE = 8
        const val LEGACY_HEALTHY_SAMPLES_TO_RAISE = 16
        const val MIN_CHANGE_INTERVAL_MS = 3_000L
        const val SEVERE_CHANGE_INTERVAL_MS = 1_000L
        const val MIN_RECOVERY_INTERVAL_MS = 12_000L

        const val RESOLUTION_REDUCTION_MAX_FPS = 24
        const val RESOLUTION_REDUCTION_GRACE_MS = 6_000L
    }
}
