package com.aaris.remoteassist.capture

/**
 * Slow-moving capture governor.
 *
 * WebRTC's congestion controller remains authoritative for packet pacing and
 * bitrate. This governor changes capture cost only when transport telemetry
 * shows sustained pressure. It combines the sender's limitation reason with
 * remote-inbound RTT/loss, then uses asymmetric hysteresis so quality falls
 * quickly when a mobile path is genuinely unhealthy and climbs back slowly.
 */
class CaptureQualityGovernor(
    initialTier: CaptureTier,
    private val maxTier: CaptureTier = initialTier
) {
    private var currentTier = initialTier
    private var constrainedSamples = 0
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

        val severeLoss =
            normalizedLoss
                ?.let { it >= SEVERE_PACKET_LOSS_RATIO }
                ?: false
        val severeRtt =
            normalizedRtt
                ?.let { it >= SEVERE_RTT_MS }
                ?: false
        val severeNetworkPressure =
            severeLoss || severeRtt

        val senderPressure =
            normalizedReason == "bandwidth" ||
                normalizedReason == "cpu"

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

        val healthy =
            normalizedReason == "none" &&
                (
                    normalizedLoss == null ||
                        normalizedLoss <= HEALTHY_PACKET_LOSS_RATIO
                    ) &&
                (
                    normalizedRtt == null ||
                        normalizedRtt <= HEALTHY_RTT_MS
                    )

        return when {
            severeNetworkPressure -> {
                healthySamples = 0
                constrainedSamples = 0
                downgrade()
            }

            senderPressure || networkPressure -> {
                healthySamples = 0
                constrainedSamples += 1

                if (constrainedSamples < DOWNGRADE_SAMPLE_COUNT) {
                    null
                } else {
                    constrainedSamples = 0
                    downgrade()
                }
            }

            healthy -> {
                constrainedSamples = 0
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
                constrainedSamples = 0
                healthySamples = 0
                null
            }
        }
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
        internal const val UPGRADE_SAMPLE_COUNT = 8

        internal const val HEALTHY_RTT_MS = 300
        internal const val PRESSURE_RTT_MS = 650
        internal const val SEVERE_RTT_MS = 900

        internal const val HEALTHY_PACKET_LOSS_RATIO = 0.025
        internal const val PRESSURE_PACKET_LOSS_RATIO = 0.06
        internal const val SEVERE_PACKET_LOSS_RATIO = 0.12
    }
}
