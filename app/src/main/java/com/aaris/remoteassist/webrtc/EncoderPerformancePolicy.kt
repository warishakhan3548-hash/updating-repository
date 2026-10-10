package com.aaris.remoteassist.webrtc

/**
 * Pure policy for translating positive codec throughput evidence into a source
 * cadence ceiling.
 *
 * The ladder mirrors the app's established adaptation rates. We never invent a
 * new cadence here, and absence of manufacturer evidence never means "slow".
 */
internal object EncoderPerformancePolicy {
    private val descendingCandidates =
        listOf(60, 55, 50, 45, 40, 36, 33, 30, 24, 20, 15)

    fun highestGuaranteedFps(
        maximumFps: Int,
        covers: (Int) -> Boolean
    ): Int? {
        val ceiling = maximumFps.coerceAtLeast(1)
        return descendingCandidates.firstOrNull { fps ->
            fps <= ceiling && covers(fps)
        }
    }

    fun effectiveLimit(
        deviceLimitFps: Int,
        guaranteedCodecFps: Int?
    ): Int {
        val device = deviceLimitFps.coerceAtLeast(1)
        val codec =
            guaranteedCodecFps
                ?.takeIf { it > 0 }
                ?.coerceAtMost(device)
                ?: device
        return minOf(device, codec)
    }
}
