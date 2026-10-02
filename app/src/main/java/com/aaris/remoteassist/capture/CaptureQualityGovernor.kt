package com.aaris.remoteassist.capture

/**
 * Slow-moving capture governor.
 *
 * WebRTC's own congestion controller remains authoritative for packet pacing
 * and bitrate. This governor only changes capture cost after persistent
 * encoder/network pressure, then waits much longer before restoring quality.
 * That hysteresis avoids resolution "ping-pong" on mobile networks.
 */
class CaptureQualityGovernor(
    initialTier: CaptureTier,
    private val maxTier: CaptureTier = initialTier
) {
    private var currentTier = initialTier
    private var constrainedSamples = 0
    private var healthySamples = 0

    fun currentTier(): CaptureTier = currentTier

    fun observeQualityLimitation(reason: String?): CaptureTier? {
        return when (reason?.trim()?.lowercase()) {
            "bandwidth",
            "cpu" -> {
                healthySamples = 0
                constrainedSamples += 1

                if (constrainedSamples < DOWNGRADE_SAMPLE_COUNT) {
                    null
                } else {
                    constrainedSamples = 0
                    currentTier.lower()?.let { next ->
                        currentTier = next
                        next
                    }
                }
            }

            "none" -> {
                constrainedSamples = 0
                healthySamples += 1

                if (healthySamples < UPGRADE_SAMPLE_COUNT) {
                    null
                } else {
                    healthySamples = 0
                    currentTier.higher()
                        ?.takeIf { it.ordinal <= maxTier.ordinal }
                        ?.let { next ->
                            currentTier = next
                            next
                        }
                }
            }

            else -> {
                // Missing/unknown stats are not evidence of either pressure or
                // recovery. Reset streaks instead of making a blind change.
                constrainedSamples = 0
                healthySamples = 0
                null
            }
        }
    }

    companion object {
        internal const val DOWNGRADE_SAMPLE_COUNT = 2
        internal const val UPGRADE_SAMPLE_COUNT = 8
    }
}
