package com.aaris.remoteassist.webrtc

/**
 * Chooses sender cadence rungs that compose predictably on the controller's
 * active display clock.
 *
 * A short beat cycle is still judder. For example, 50 fps on a 60 Hz display
 * necessarily alternates one-vsync and two-vsync frame holds even when capture,
 * RTP, decode and EGL are otherwise perfect. Remote-control motion makes that
 * cadence error especially visible during scrolling and games.
 *
 * For the >30 fps quality ladder, keep only rates that divide the controller's
 * measured active refresh clock exactly. This gives every encoded frame a
 * stable integer number of display refreshes. 48 fps is included because it is
 * the natural high-cadence rung for common 144 Hz panels.
 *
 * <=30 fps remains the pressure/recovery safety ladder. Those rungs deliberately
 * stay available even when they are not harmonic because severe encoder/network
 * pressure values freshness and queue drainage over ideal presentation cadence.
 *
 * Missing/invalid display capability preserves the historical adaptation ladder
 * exactly, so mixed-version peers keep their previous behavior.
 */
internal object DisplayCadencePolicy {
    private val legacyDescending =
        listOf(60, 58, 55, 50, 45, 40, 36, 33, 30, 24, 20, 15)

    private val displayAlignedHighDescending =
        listOf(60, 58, 55, 50, 48, 45, 40, 36, 33)

    private val lowCadenceDescending =
        listOf(30, 24, 20, 15)

    fun descending(
        refreshRateHz: Double?,
        ceilingFps: Int = PRODUCT_MAX_FPS,
        floorFps: Int = 1
    ): List<Int> {
        val floor = floorFps.coerceAtLeast(1)
        val ceiling = ceilingFps.coerceAtLeast(floor)
        val refresh = normalizedRefresh(refreshRateHz)
            ?: return legacyDescending
                .filter { it in floor..ceiling }
                .ifEmpty { listOf(ceiling) }

        val rates = linkedSetOf<Int>()
        val firstHigh = maxOf(HIGH_CADENCE_MIN_FPS, floor)

        if (ceiling >= firstHigh) {
            displayAlignedHighDescending
                .asSequence()
                .filter { it in firstHigh..ceiling }
                .filter { harmonicOnDisplay(refresh, it) }
                .forEach(rates::add)
        }

        lowCadenceDescending
            .filterTo(rates) { it in floor..ceiling }

        if (rates.isEmpty()) {
            rates += ceiling
        }

        return rates.sortedDescending()
    }

    fun nextLower(
        currentFps: Int,
        refreshRateHz: Double?,
        floorFps: Int = 1,
        ceilingFps: Int = PRODUCT_MAX_FPS
    ): Int? =
        descending(
            refreshRateHz = refreshRateHz,
            ceilingFps = maxOf(ceilingFps, currentFps),
            floorFps = floorFps
        ).firstOrNull { it < currentFps }

    fun nextHigher(
        currentFps: Int,
        refreshRateHz: Double?,
        ceilingFps: Int = PRODUCT_MAX_FPS,
        floorFps: Int = 1
    ): Int? =
        descending(
            refreshRateHz = refreshRateHz,
            ceilingFps = ceilingFps,
            floorFps = floorFps
        ).asReversed().firstOrNull {
            it > currentFps && it <= ceilingFps
        }

    fun nearestAtOrBelow(
        limitFps: Int,
        refreshRateHz: Double?,
        ceilingFps: Int = PRODUCT_MAX_FPS,
        floorFps: Int = 1
    ): Int =
        descending(
            refreshRateHz = refreshRateHz,
            ceilingFps = maxOf(ceilingFps, limitFps),
            floorFps = floorFps
        ).firstOrNull { it <= limitFps }
            ?: minOf(limitFps.coerceAtLeast(1), HIGH_CADENCE_MIN_FPS - 1)

    private fun normalizedRefresh(value: Double?): Int? {
        if (
            value == null ||
            !value.isFinite() ||
            value < MIN_REFRESH_HZ ||
            value > MAX_REFRESH_HZ
        ) {
            return null
        }
        return kotlin.math.round(value).toInt().coerceAtLeast(1)
    }

    private fun harmonicOnDisplay(
        refreshHz: Int,
        fps: Int
    ): Boolean {
        if (fps <= 0 || fps > refreshHz) return false
        return refreshHz % fps == 0
    }

    private const val PRODUCT_MAX_FPS = 60
    private const val HIGH_CADENCE_MIN_FPS = 31
    private const val MIN_REFRESH_HZ = 30.0
    private const val MAX_REFRESH_HZ = 240.0
}
