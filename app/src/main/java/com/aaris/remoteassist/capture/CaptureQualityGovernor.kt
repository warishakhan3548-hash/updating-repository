package com.aaris.remoteassist.capture

/**
 * Slow-moving capture governor.
 *
 * WebRTC's congestion controller remains authoritative for packet pacing and
 * bitrate. This governor changes capture cost only when transport/encoder
 * telemetry shows meaningful pressure. Network signals use asymmetric
 * hysteresis so isolated mobile-path spikes do not blur the screen, while an
 * explicit encoder CPU limitation steps capture cost down immediately because
 * the local device is already failing to sustain the requested workload.
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

    fun currentTier(): CaptureTier = currentTier

    fun observeQualityLimitation(
        reason: String?,
        roundTripTimeMs: Int? = null,
        packetLossRatio: Double? = null
    ): CaptureTier? {
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
            normalizedLoss
                ?.let { it >= SEVERE_PACKET_LOSS_RATIO }
                ?: false
        val severeRtt =
            normalizedRtt
                ?.let { it >= SEVERE_RTT_MS }
                ?: false
        val cpuPressure =
            normalizedReason == "cpu"
        val bandwidthPressure =
            normalizedReason == "bandwidth"

        val pressuredLoss =
            normalizedLoss
                ?.let { it >= PRESSURE_PACKET_LOSS_RATIO }
                ?: false
        val pressuredRtt =
            normalizedRtt
                ?.let { it >= PRESSURE_RTT_MS }
                ?: false
        val networkPressure =
            pressuredLoss || pressuredRtt

        val transportHealthy =
            (
                normalizedLoss == null ||
                    normalizedLoss <= HEALTHY_PACKET_LOSS_RATIO
                ) &&
                (
                    normalizedRtt == null ||
                        normalizedRtt <= HEALTHY_RTT_MS
                    )

        val explicitHealthy =
            normalizedReason == "none" &&
                transportHealthy
        val inferredHealthy =
            normalizedReason == null &&
                hasTransportTelemetry &&
                transportHealthy
        val healthyBandwidth =
            bandwidthPressure &&
                hasTransportTelemetry &&
                transportHealthy

        return when {
            /*
             * Heavy packet loss means frames are actively being discarded.
             * CPU limitation is similarly direct: libwebrtc is already telling
             * us the sender cannot sustain the requested encode workload. Both
             * deserve one immediate tier reduction; recovery remains slow.
             */
            severeLoss || cpuPressure -> {
                resetPressureCounters()
                resetRecoveryCounters()
                downgrade()
            }

            /*
             * RTT/loss are stronger evidence than the encoder's generic
             * bandwidth reason. Let them persist across multiple stats samples
             * before sacrificing capture resolution so a one-off Wi-Fi or
             * cellular spike never causes a visible clarity cliff.
             */
            severeRtt || networkPressure -> {
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
            bandwidthPressure && !hasTransportTelemetry -> {
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

            explicitHealthy || inferredHealthy -> {
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
                resetPressureCounters()
                resetRecoveryCounters()
                null
            }
        }
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
        internal const val DOWNGRADE_SAMPLE_COUNT = 2
        internal const val BANDWIDTH_ONLY_DOWNGRADE_SAMPLE_COUNT = 4
        internal const val UPGRADE_SAMPLE_COUNT = 6
        internal const val BANDWIDTH_PROBE_UPGRADE_SAMPLE_COUNT = 10

        internal const val HEALTHY_RTT_MS = 300
        internal const val PRESSURE_RTT_MS = 650
        internal const val SEVERE_RTT_MS = 900

        internal const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        internal const val PRESSURE_PACKET_LOSS_RATIO = 0.06
        internal const val SEVERE_PACKET_LOSS_RATIO = 0.12
    }
}
