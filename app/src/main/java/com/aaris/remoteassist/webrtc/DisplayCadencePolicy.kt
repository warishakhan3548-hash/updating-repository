package com.aaris.remoteassist.webrtc

/**
 * Chooses sender cadence rungs that compose predictably on the controller's
 * physical display.
 *
 * Arbitrary near-refresh rates are deceptively expensive for remote control.
 * For example, 58 fps on a 60 Hz panel repeats its frame/vsync phase only after
 * 30 refreshes, which can look like periodic micro-stutter even when RTP,
 * decode, and EGL are healthy. A 48/60 cadence repeats every five refreshes,
 * 45/60 every four, and 40/60 every three.
 *
 * We therefore keep high-cadence (>30 fps) rungs whose reduced refresh ratio
 * repeats within a short display cycle. 60 fps remains the product ceiling even
 * on unusual high-refresh panels because Android may switch the Surface to a
 * compatible mode after the existing 60 fps frame-rate hint.
 *
 * <=30 fps is the pressure/recovery safety ladder, where freshness and encoder
 * headroom matter more than perfect phase matching.
 *
 * Missing/invalid display capability preserves the previous ladder exactly.
 */
internal object DisplayCadencePolicy {
    private val legacyDescending =
        listOf(60, 58, 55, 50, 45, 40, 36, 33, 30, 24, 20, 15)
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

        if (ceiling >= PRODUCT_MAX_FPS && PRODUCT_MAX_FPS >= floor) {
            rates += PRODUCT_MAX_FPS
        }

        val firstHigh = maxOf(HIGH_CADENCE_MIN_FPS, floor)
        if (ceiling >= firstHigh) {
            for (fps in ceiling downTo firstHigh) {
                if (shortRepeatCycle(refresh, fps)) {
                    rates += fps
                }
            }
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

    private fun shortRepeatCycle(refreshHz: Int, fps: Int): Boolean {
        if (fps <= 0 || fps > refreshHz) return false
        val divisor = greatestCommonDivisor(refreshHz, fps)
        val repeatVsyncs = refreshHz / divisor
        return repeatVsyncs <= MAX_HIGH_CADENCE_REPEAT_VSYNCS
    }

    private fun greatestCommonDivisor(a: Int, b: Int): Int {
        var x = kotlin.math.abs(a)
        var y = kotlin.math.abs(b)
        while (y != 0) {
            val remainder = x % y
            x = y
            y = remainder
        }
        return x.coerceAtLeast(1)
    }

    private const val PRODUCT_MAX_FPS = 60
    private const val HIGH_CADENCE_MIN_FPS = 31
    private const val MAX_HIGH_CADENCE_REPEAT_VSYNCS = 5
    private const val MIN_REFRESH_HZ = 30.0
    private const val MAX_REFRESH_HZ = 240.0
}
