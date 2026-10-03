package com.aaris.remoteassist.webrtc

/**
 * Bounds capture cost while libwebrtc remains the owner of bitrate, pacing and
 * congestion control.
 *
 * The governor is deliberately freshness-first: for remote control, a lower
 * sustainable cadence is preferable to a nominal 60 fps stream that queues old
 * frames. Sender queue residence and receiver jitter-buffer residence therefore
 * participate directly in the pressure signal instead of waiting for visible
 * freezes or large drop counters.
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

        /*
         * Hardware codecs can pipeline several frames. Codec time above one
         * frame interval is not itself proof that the pipeline is late: require
         * measured output cadence to fall behind as well.
         */
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
                        receiver.fps <
                        minOf(
                            requestedFps.toDouble(),
                            sender.fps
                        ) * FPS_DELIVERY_RATIO
                    )

        val loss = outbound.packetLossRatio ?: 0.0
        val receiverDropped = receiver?.dropped?.coerceAtLeast(0) ?: 0
        val receiverSamples =
            receiver?.let { it.frames.coerceAtLeast(0) + receiverDropped } ?: 0
        val receiverDropRatio =
            if (receiverSamples > 0) {
                receiverDropped.toDouble() / receiverSamples
            } else {
                0.0
            }
        val receiverDrops =
            receiverDropped >= MIN_DROPPED_FRAMES_FOR_PRESSURE &&
                receiverSamples >= MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO &&
                receiverDropRatio >= RECEIVER_DROP_PRESSURE_RATIO

        val sendQueueMs = sender.sendQueueMs
        val receiverJitterMs = receiver?.jitterMs

        /*
         * A remote-control stream can look "laggy" even before it freezes.
         * Queue/jitter residence is already latency paid by the user, so treat
         * it as first-class pressure. The threshold also scales modestly with
         * the current frame budget so 15/20 fps recovery modes are not punished
         * simply for having a larger natural frame interval.
         */
        val queuePressureThresholdMs =
            maxOf(MIN_QUEUE_PRESSURE_MS, budgetMs * QUEUE_BUDGET_MULTIPLIER)
        val jitterPressureThresholdMs =
            maxOf(MIN_JITTER_PRESSURE_MS, budgetMs * JITTER_BUDGET_MULTIPLIER)
        val queuePressure =
            sendQueueMs != null &&
                sendQueueMs > queuePressureThresholdMs
        val receiverDelay =
            receiver != null &&
                receiver.frames >= MIN_MEASURED_FRAMES &&
                receiverJitterMs != null &&
                receiverJitterMs > jitterPressureThresholdMs

        val congestion =
            loss >= PACKET_LOSS_PRESSURE_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= RTT_PRESSURE_MS ||
                queuePressure ||
                receiverDelay

        val severePressure =
            loss >= SEVERE_PACKET_LOSS_RATIO ||
                (outbound.roundTripTimeMs ?: 0) >= SEVERE_RTT_MS ||
                (sendQueueMs ?: 0.0) >= SEVERE_QUEUE_MS ||
                (receiverJitterMs ?: 0.0) >= SEVERE_JITTER_MS ||
                receiverDropRatio >= SEVERE_RECEIVER_DROP_RATIO

        val overloaded =
            codecPressure ||
                receiverDrops ||
                congestion ||
                outbound.qualityLimitationReason == "cpu"

        if (overloaded) {
            healthy = 0
            pressure =
                (pressure + if (severePressure) 2 else 1)
                    .coerceAtMost(PRESSURE_SAMPLES_TO_REDUCE)

            if (
                pressure < PRESSURE_SAMPLES_TO_REDUCE ||
                nowMs - changedAt < MIN_CHANGE_INTERVAL_MS
            ) {
                return false
            }

            val next =
                DESCENDING_CAPS.firstOrNull {
                    it < minOf(cap, requestedFps)
                } ?: return false

            cap = next
            changedAt = nowMs
            pressure = 0
            return true
        }

        pressure = 0

        // Missing telemetry and a static screen are not evidence of spare capacity.
        val receiverHealthy =
            if (receiver == null) {
                outbound.qualityLimitationReason == "none" &&
                    outbound.roundTripTimeMs != null &&
                    outbound.roundTripTimeMs < HEALTHY_RTT_MS
            } else {
                receiver.frames >= MIN_MEASURED_FRAMES &&
                    receiver.processingMs != null &&
                    receiver.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                    (receiver.jitterMs ?: 0.0) < HEALTHY_JITTER_MS &&
                    (receiver.dropped ?: 0) == 0 &&
                    (receiver.freezes ?: 0) == 0
            }

        val headroom =
            sender.frames >= MIN_MEASURED_FRAMES &&
                sender.processingMs != null &&
                sender.processingMs < budgetMs * CODEC_HEADROOM_BUDGET_RATIO &&
                receiverHealthy &&
                loss < HEALTHY_PACKET_LOSS_RATIO &&
                (sender.sendQueueMs ?: 0.0) < HEALTHY_QUEUE_MS &&
                outbound.qualityLimitationReason != "bandwidth"

        healthy = if (headroom) healthy + 1 else 0
        val healthySamplesRequired =
            if (receiver == null) {
                LEGACY_HEALTHY_SAMPLES_TO_RAISE
            } else {
                HEALTHY_SAMPLES_TO_RAISE
            }

        if (
            healthy < healthySamplesRequired ||
            nowMs - changedAt < MIN_RECOVERY_INTERVAL_MS
        ) {
            return false
        }

        val next =
            ASCENDING_CAPS.firstOrNull {
                it > cap && it <= maxFps
            } ?: return false

        cap = next
        changedAt = nowMs
        healthy = 0
        return true
    }

    fun mayReduceResolution(nowMs: Long): Boolean =
        cap <= RESOLUTION_REDUCTION_MAX_FPS &&
            nowMs - changedAt >= RESOLUTION_REDUCTION_GRACE_MS

    private companion object {
        val DESCENDING_CAPS = listOf(60, 30, 24, 20, 15)
        val ASCENDING_CAPS = listOf(15, 20, 24, 30, 60)

        const val MIN_MEASURED_FRAMES = 5
        const val MIN_DROPPED_FRAMES_FOR_PRESSURE = 2
        const val MIN_RECEIVER_SAMPLES_FOR_DROP_RATIO = 8

        const val CODEC_PRESSURE_BUDGET_RATIO = 0.85
        const val CODEC_HEADROOM_BUDGET_RATIO = 0.55
        const val FPS_DELIVERY_RATIO = 0.85

        const val MIN_QUEUE_PRESSURE_MS = 55.0
        const val QUEUE_BUDGET_MULTIPLIER = 2.0
        const val MIN_JITTER_PRESSURE_MS = 85.0
        const val JITTER_BUDGET_MULTIPLIER = 2.5

        const val PACKET_LOSS_PRESSURE_RATIO = 0.04
        const val RTT_PRESSURE_MS = 650
        const val RECEIVER_DROP_PRESSURE_RATIO = 0.08

        const val SEVERE_PACKET_LOSS_RATIO = 0.12
        const val SEVERE_RTT_MS = 900
        const val SEVERE_QUEUE_MS = 150.0
        const val SEVERE_JITTER_MS = 180.0
        const val SEVERE_RECEIVER_DROP_RATIO = 0.25

        const val HEALTHY_RTT_MS = 300
        const val HEALTHY_JITTER_MS = 45.0
        const val HEALTHY_QUEUE_MS = 20.0
        const val HEALTHY_PACKET_LOSS_RATIO = 0.025

        const val PRESSURE_SAMPLES_TO_REDUCE = 2
        const val HEALTHY_SAMPLES_TO_RAISE = 8
        const val LEGACY_HEALTHY_SAMPLES_TO_RAISE = 16
        const val MIN_CHANGE_INTERVAL_MS = 3_000L
        const val MIN_RECOVERY_INTERVAL_MS = 12_000L

        const val RESOLUTION_REDUCTION_MAX_FPS = 24
        const val RESOLUTION_REDUCTION_GRACE_MS = 6_000L
    }
}
