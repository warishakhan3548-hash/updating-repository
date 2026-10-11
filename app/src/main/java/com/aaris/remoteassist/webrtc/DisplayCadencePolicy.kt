package com.aaris.remoteassist.webrtc

/**
 * Chooses sender cadence rungs that compose predictably on the controller's
 * physical display.
 *
 * Arbitrary near-refresh rates are deceptively expensive for remote control.
 * For example, 58 fps on a 60 Hz panel repeats its frame/vsync phase only after
 * 30 refreshes, which can look like periodic micro-stutter even when RTP,
 * decode, and EGL are healthy. A 50/60 cadence repeats every six refreshes,
 * 48/60 every five, 45/60 every four, and 40/60 every three.
 *
 * We therefore FILTER the already-proven high-cadence (>30 fps) adaptation
 * ladder by display compatibility instead of inventing extra intermediate
 * rates. This preserves the governor's validated recovery timing while removing
 * rungs whose reduced refresh ratio has a long beat period. 60 fps remains the
 * product ceiling even
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
            legacyDescending
                .asSequence()
                .filter { it in firstHigh..ceiling }
                .filter { it != PRODUCT_MAX_FPS }
                .filter { shortRepeatCycle(refresh, it) }
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
    ): Int? {
        /*
         * Promotion and relief have different visual failure modes.
         *
         * Relief may still use a short-repeat non-harmonic rung to drain an
         * encoder/pacer backlog without a huge 60 -> 30 cliff. Promotion is
         * stricter: when the active display exposes an exact high-cadence
         * harmonic inside the current device/encoder ceiling, never climb past
         * that harmonic into a cadence that necessarily needs uneven pulldown.
         *
         * Examples:
         *   90 Hz  -> steady ceiling 45 fps
         *   120 Hz -> steady ceiling 60 fps
         *   144 Hz -> steady ceiling 48 fps
         *   165 Hz -> steady ceiling 55 fps
         *
         * If the encoder ceiling is below every exact harmonic (for example a
         * 45 fps codec ceiling on a 60 Hz panel), preserve the existing
         * short-repeat ladder rather than forcing a large drop to 30 fps.
         */
        val harmonicCeiling =
            normalizedRefresh(refreshRateHz)
                ?.let { refresh ->
                    harmonicPromotionCeiling(
                        refreshHz = refresh,
                        ceilingFps = ceilingFps
                    )
                }
        val boundedCeiling =
            harmonicCeiling?.let { minOf(ceilingFps, it) }
                ?: ceilingFps

        val candidates =
            descending(
                refreshRateHz = refreshRateHz,
                ceilingFps = boundedCeiling,
                floorFps = floorFps
            ).toMutableSet()

        /*
         * Some useful exact divisors (48 on 144 Hz, 42 on 84 Hz, etc.) are not
         * part of the historical pressure ladder. Add only the single proven
         * harmonic ceiling for promotion; do not expand the relief ladder.
         */
        harmonicCeiling
            ?.takeIf {
                it in maxOf(currentFps + 1, floorFps)..boundedCeiling
            }
            ?.let(candidates::add)

        return candidates
            .asSequence()
            .filter { it > currentFps && it <= boundedCeiling }
            .minOrNull()
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

    /**
     * RenderSynchronizer is a display-vsync gate, not a producer FPS request.
     *
     * Keep its target at least as fast as every refresh mode the controller can
     * enter during the session. The screen stream itself is still capped at
     * PRODUCT_MAX_FPS, while EglRenderer keeps one latest-wins pending frame.
     * This prevents a fixed 60 fps RenderSynchronizer from becoming a second,
     * independent pacing clock on 90/120/144/165 Hz panels.
     */
    fun renderSynchronizerTargetFps(
        activeRefreshRateHz: Double?,
        maximumSupportedRefreshRateHz: Double? = null
    ): Float {
        val active =
            activeRefreshRateHz
                ?.takeIf {
                    it.isFinite() &&
                        it in MIN_REFRESH_HZ..MAX_REFRESH_HZ
                }
        val supported =
            maximumSupportedRefreshRateHz
                ?.takeIf {
                    it.isFinite() &&
                        it in MIN_REFRESH_HZ..MAX_REFRESH_HZ
                }

        return maxOf(
            PRODUCT_MAX_FPS.toDouble(),
            active ?: 0.0,
            supported ?: 0.0
        )
            .coerceAtMost(MAX_REFRESH_HZ)
            .toFloat()
    }

    private fun harmonicPromotionCeiling(
        refreshHz: Int,
        ceilingFps: Int
    ): Int? {
        val ceiling =
            minOf(
                PRODUCT_MAX_FPS,
                ceilingFps,
                refreshHz
            )
        if (ceiling < HIGH_CADENCE_MIN_FPS) return null

        return (ceiling downTo HIGH_CADENCE_MIN_FPS)
            .firstOrNull { candidate ->
                refreshHz % candidate == 0
            }
    }

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
    private const val MAX_HIGH_CADENCE_REPEAT_VSYNCS = 6
    private const val MIN_REFRESH_HZ = 30.0
    private const val MAX_REFRESH_HZ = 240.0
}
