package com.aaris.remoteassist.capture

/**
 * Slow-moving capture governor.
 *
 * WebRTC's congestion controller remains authoritative for packet pacing and
 * bitrate. This governor changes capture cost only when transport/encoder
 * telemetry shows meaningful pressure. Network signals use asymmetric
 * hysteresis so isolated mobile-path spikes do not blur the screen. A generic
 * WebRTC CPU limitation is deliberately temporal-only here: under this app's
 * MAINTAIN_RESOLUTION contract, VideoCadenceGovernor gets first ownership of
 * that signal. Capture pixels move only when measured encode/queue delivery
 * proves the local pipeline itself is missing deadlines.
 *
 * A bandwidth limitation by itself is deliberately treated as a weak signal.
 * libwebrtc can report "bandwidth" on a perfectly usable path simply because
 * its bitrate estimator is doing normal congestion control. Resolution is only
 * sacrificed quickly when RTT/loss corroborate that signal. When vendor builds
 * omit qualityLimitationReason, healthy transport telemetry is still enough to
 * recover quality instead of leaving the session permanently stuck on a lower
 * tier.
 */
class CaptureQualityGovernor(
    initialTier: CaptureTier,
    private val maxTier: CaptureTier = initialTier
) {
    private var currentTier = initialTier
    private var constrainedSamples = 0
    private var bandwidthOnlySamples = 0
    private var bandwidthProbeSamples = 0
    private var healthySamples = 0
    private var localPipelinePressureSamples = 0

    fun currentTier(): CaptureTier = currentTier

    fun observeQualityLimitation(
        reason: String?,
        roundTripTimeMs: Int? = null,
        packetLossRatio: Double? = null,
        encodeTimeMs: Double? = null,
        sendQueueMs: Double? = null,
        deliveredFps: Double? = null,
        requestedFps: Int = 30,
        outboundFrameCount: Int? = null
    ): CaptureTier? {
        // RTCP loss/RTT and quality-limitation labels can outlive the last
        // moving frame. A quiet source cannot prove that lowering its pixels
        // would relieve the current path, nor should stale remote-only values
        // pin it to a blurry tier. Require a populated outbound window before
        // those signals may downshift or block recovery. Null preserves the
        // behavior of callers without RTP deltas; measured local pressure
        // remains authoritative in every window.
        val networkPressureEligible =
            outboundFrameCount == null ||
                outboundFrameCount >= MIN_NETWORK_EVIDENCE_FRAMES
        val quietSourceWindow =
            outboundFrameCount != null &&
                !networkPressureEligible
        val normalizedReason =
            reason?.trim()?.lowercase()
        val normalizedRtt =
            roundTripTimeMs
                ?.takeIf { it >= 0 }
        val normalizedLoss =
            packetLossRatio
                ?.takeIf { it.isFinite() && it >= 0.0 }
                ?.coerceIn(0.0, 1.0)

        val hasTransportTelemetry =
            normalizedRtt != null ||
                normalizedLoss != null

        val severeLoss =
            networkPressureEligible &&
                normalizedLoss?.let {
                    it >= SEVERE_PACKET_LOSS_RATIO
                } == true
        val severeRtt =
            networkPressureEligible &&
                normalizedRtt?.let {
                    it >= SEVERE_RTT_MS
                } == true
        val cpuReported =
            networkPressureEligible &&
                normalizedReason == "cpu"
        val bandwidthPressure =
            normalizedReason == "bandwidth"

        /*
         * Resolution is the expensive lever, so cadence gets first chance to
         * recover freshness. Only sustained local pipeline pressure may lower
         * the capture tier: slow encode residence with under-delivery, a long
         * sender queue, or a 3-6 fps collapse corroborated by either signal.
         * Static screens with few frames and no queue/encode pressure do not
         * count as overload.
         */
        val localPipelinePressure =
            hasLocalPipelinePressure(
                encodeTimeMs = encodeTimeMs,
                sendQueueMs = sendQueueMs,
                deliveredFps = deliveredFps,
                requestedFps = requestedFps
            )

        // This is deliberately not a claim that the network is healthy. It is
        // evidence that remote-only pressure cannot be attributed to the
        // current (static) pixel workload. Slowly restore capture detail while
        // idle; the first populated interval re-enables normal RTT/loss/CPU
        // protection before it can trigger another tier decision.
        val quietSourceRecoveryEvidence =
            quietSourceWindow &&
                !localPipelinePressure &&
                when (normalizedReason) {
                    null,
                    "none",
                    "bandwidth",
                    "cpu" -> true
                    else -> false
                }

        val pressuredLoss =
            normalizedLoss
                ?.let { it >= PRESSURE_PACKET_LOSS_RATIO }
                ?: false
        val pressuredRtt =
            normalizedRtt
                ?.let { it >= PRESSURE_RTT_MS }
                ?: false
        val networkPressure =
            networkPressureEligible &&
                (pressuredLoss || pressuredRtt)

        val transportHealthy =
            (
                normalizedLoss == null ||
                    normalizedLoss <= HEALTHY_PACKET_LOSS_RATIO
                ) &&
                (
                    normalizedRtt == null ||
                        normalizedRtt <= HEALTHY_RTT_MS
                    )

        /*
         * qualityLimitationReason="cpu" is not proof that resolution is the
         * overloaded resource. libwebrtc can report CPU while its adaptation is
         * intentionally reducing cadence. If measured encode residence, sender
         * queue and delivery are healthy, treat the label as temporal pressure
         * and allow slow clarity recovery instead of pinning a previous lower
         * tier forever.
         */
        val cpuTemporalOnlyHealthy =
            cpuReported &&
                !localPipelinePressure &&
                transportHealthy

        val explicitHealthy =
            normalizedReason == "none" &&
                transportHealthy
        val inferredHealthy =
            normalizedReason == null &&
                hasTransportTelemetry &&
                transportHealthy
        val healthyBandwidth =
            networkPressureEligible &&
                bandwidthPressure &&
                hasTransportTelemetry &&
                transportHealthy

        return when {
            /*
             * Heavy packet loss means frames are actively being discarded and
             * deserves one immediate tier reduction. A bare CPU label does not:
             * cadence owns generic CPU overuse, while the measured
             * localPipelinePressure branch below remains authoritative when the
             * encoder/pacer really cannot sustain the workload.
             */
            severeLoss -> {
                localPipelinePressureSamples = 0
                resetPressureCounters()
                resetRecoveryCounters()
                downgrade()
            }

            localPipelinePressure -> {
                resetPressureCounters()
                resetRecoveryCounters()
                localPipelinePressureSamples += 1

                if (
                    localPipelinePressureSamples <
                    LOCAL_PIPELINE_PRESSURE_SAMPLE_COUNT
                ) {
                    null
                } else {
                    localPipelinePressureSamples = 0
                    downgrade()
                }
            }

            /*
             * RTT/loss are stronger evidence than the encoder's generic
             * bandwidth reason. Let them persist across multiple stats samples
             * before sacrificing capture resolution so a one-off Wi-Fi or
             * cellular spike never causes a visible clarity cliff.
             */
            severeRtt || networkPressure -> {
                localPipelinePressureSamples = 0
                bandwidthOnlySamples = 0
                resetRecoveryCounters()
                constrainedSamples += 1

                if (constrainedSamples < DOWNGRADE_SAMPLE_COUNT) {
                    null
                } else {
                    constrainedSamples = 0
                    downgrade()
                }
            }

            /*
             * A healthy path can still be reported as bandwidth-limited while
             * WebRTC is simply selecting a bitrate below the encoder ceiling.
             * Keep the current resolution in that state. If we are already on a
             * reduced tier, periodically probe one step upward after a much
             * longer healthy window so a temporary network dip never leaves the
             * remote screen blurry for the rest of the session.
             */
            healthyBandwidth -> {
                localPipelinePressureSamples = 0
                constrainedSamples = 0
                bandwidthOnlySamples = 0
                healthySamples = 0
                bandwidthProbeSamples += 1

                if (
                    bandwidthProbeSamples <
                    BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT
                ) {
                    null
                } else {
                    bandwidthProbeSamples = 0
                    upgrade()
                }
            }

            /*
             * Some vendor WebRTC builds expose the quality limitation reason but
             * omit usable remote-inbound RTT/loss. Sustained "bandwidth" still
             * gets a conservative safety fallback, just much later than real
             * corroborated congestion.
             */
            bandwidthPressure &&
                !hasTransportTelemetry &&
                networkPressureEligible -> {
                localPipelinePressureSamples = 0
                constrainedSamples = 0
                resetRecoveryCounters()
                bandwidthOnlySamples += 1

                if (
                    bandwidthOnlySamples <
                    BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT
                ) {
                    null
                } else {
                    bandwidthOnlySamples = 0
                    downgrade()
                }
            }

            quietSourceRecoveryEvidence ||
                cpuTemporalOnlyHealthy ||
                explicitHealthy ||
                inferredHealthy -> {
                localPipelinePressureSamples = 0
                resetPressureCounters()
                bandwidthProbeSamples = 0
                healthySamples += 1

                if (healthySamples < UPGRADE_SAMPLE_COUNT) {
                    null
                } else {
                    healthySamples = 0
                    upgrade()
                }
            }

            else -> {
                // Missing/ambiguous stats are not proof of congestion or health.
                localPipelinePressureSamples = 0
                resetPressureCounters()
                resetRecoveryCounters()
                null
            }
        }
    }

    internal fun hasLocalPipelinePressure(
        encodeTimeMs: Double?,
        sendQueueMs: Double?,
        deliveredFps: Double?,
        requestedFps: Int
    ): Boolean {
        val safeRequestedFps = requestedFps.coerceIn(1, 60)
        val frameBudgetMs = 1_000.0 / safeRequestedFps.toDouble()
        val normalizedEncodeMs =
            encodeTimeMs?.takeIf { it.isFinite() && it >= 0.0 }
        val normalizedQueueMs =
            sendQueueMs?.takeIf { it.isFinite() && it >= 0.0 }
        val normalizedDeliveredFps =
            deliveredFps?.takeIf { it.isFinite() && it >= 0.0 }

        val deliveryBelowTarget =
            normalizedDeliveredFps?.let {
                it < safeRequestedFps * LOCAL_DELIVERY_RATIO
            } ?: false
        val slowEncode =
            normalizedEncodeMs?.let {
                it >= maxOf(
                    LOCAL_MIN_ENCODE_MS,
                    frameBudgetMs * LOCAL_ENCODE_BUDGET_RATIO
                )
            } ?: false
        val longQueue =
            normalizedQueueMs?.let {
                it >= maxOf(
                    LOCAL_MIN_QUEUE_MS,
                    frameBudgetMs * LOCAL_QUEUE_BUDGET_MULTIPLIER
                )
            } ?: false
        val collapsedDelivery =
            normalizedDeliveredFps?.let { it <= LOCAL_COLLAPSE_FPS }
                ?: false

        return longQueue ||
            (slowEncode && deliveryBelowTarget) ||
            (
                collapsedDelivery &&
                    (
                        normalizedEncodeMs?.let {
                            it >= frameBudgetMs * LOCAL_COLLAPSE_ENCODE_RATIO
                        } == true ||
                            normalizedQueueMs?.let {
                                it >= LOCAL_COLLAPSE_QUEUE_MS
                            } == true
                        )
                )
    }

    private fun resetPressureCounters() {
        constrainedSamples = 0
        bandwidthOnlySamples = 0
    }

    private fun resetRecoveryCounters() {
        healthySamples = 0
        bandwidthProbeSamples = 0
    }

    private fun downgrade(): CaptureTier? =
        currentTier.lower()?.let { next ->
            currentTier = next
            next
        }

    private fun upgrade(): CaptureTier? =
        currentTier.higher()
            ?.takeIf { it.ordinal <= maxTier.ordinal }
            ?.let { next ->
                currentTier = next
                next
            }

    companion object {
        internal const val MIN_NETWORK_EVIDENCE_FRAMES = 2
        internal const val DOWNGRADE_SAMPLE_COUNT = 2
        internal const val BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT = 4
        internal const val UPGRADE_SAMPLE_COUNT = 6
        internal const val BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT = 10
        internal const val LOCAL_PIPELINE_PRESSURE_SAMPLE_COUNT = 2

        internal const val LOCAL_MIN_ENCODE_MS = 18.0
        internal const val LOCAL_ENCODE_BUDGET_RATIO = 0.90
        internal const val LOCAL_DELIVERY_RATIO = 0.70
        internal const val LOCAL_MIN_QUEUE_MS = 120.0
        internal const val LOCAL_QUEUE_BUDGET_MULTIPLIER = 4.0
        internal const val LOCAL_COLLAPSE_FPS = 6.0
        internal const val LOCAL_COLLAPSE_ENCODE_RATIO = 0.70
        internal const val LOCAL_COLLAPSE_QUEUE_MS = 90.0

        internal const val HEALTHY_RTT_MS = 300
        internal const val PRESSURE_RTT_MS = 650
        internal const val SEVERE_RTT_MS = 900

        internal const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        internal const val PRESSURE_PACKET_LOSS_RATIO = 0.06
        internal const val SEVERE_PACKET_LOSS_RATIO = 0.12
    }
}
