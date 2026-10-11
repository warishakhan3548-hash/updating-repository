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
        floorFps: Int = 1,
        sourceRefreshRateHz: Double? = null
    ): List<Int> {
        val floor = floorFps.coerceAtLeast(1)
        val ceiling = ceilingFps.coerceAtLeast(floor)
        val refresh = normalizedRefresh(refreshRateHz)
        val sourceRefresh = normalizedRefresh(sourceRefreshRateHz)
        if (refresh == null && sourceRefresh == null) {
            return legacyDescending
                .filter { it in floor..ceiling }
                .ifEmpty { listOf(ceiling) }
        }

        val rates = linkedSetOf<Int>()
        val firstHigh = maxOf(HIGH_CADENCE_MIN_FPS, floor)

        /*
         * MediaProjection is paced by the host display clock, while
         * VideoSource.adaptOutputFormat() is our pre-encode temporal actuator.
         * A target such as 45 fps on a 60 Hz producer necessarily creates an
         * uneven 3-of-4 selection pattern even when encoder/network/controller
         * are perfect. That periodic long interval is perceived as judder.
         *
         * Once the host source clock is known, keep high-cadence rungs on an
         * integer divisor of that clock. The controller clock still applies the
         * existing short-repeat filter, so a rung must be cheap on BOTH sides.
         * <=30 fps remains the pressure safety ladder and is intentionally left
         * untouched. Unknown source cadence preserves the legacy behavior.
         */
        fun admitHigh(fps: Int): Boolean =
            fps in firstHigh..ceiling &&
                (refresh == null || shortRepeatCycle(refresh, fps)) &&
                sourceClockCompatible(sourceRefresh, fps)

        if (ceiling >= firstHigh) {
            legacyDescending
                .asSequence()
                .filter(::admitHigh)
                .forEach(rates::add)

            /*
             * Some useful source harmonics are not in the historical ladder
             * (for example 48 fps from a 144 Hz producer). Add only exact source
             * divisors that also have a short controller repeat cycle.
             */
            sourceRefresh
                ?.let { source ->
                    (minOf(PRODUCT_MAX_FPS, ceiling, source) downTo firstHigh)
                        .asSequence()
                        .filter { source % it == 0 }
                        .filter(::admitHigh)
                        .forEach(rates::add)
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
        ceilingFps: Int = PRODUCT_MAX_FPS,
        sourceRefreshRateHz: Double? = null
    ): Int? =
        descending(
            refreshRateHz = refreshRateHz,
            ceilingFps = maxOf(ceilingFps, currentFps),
            floorFps = floorFps,
            sourceRefreshRateHz = sourceRefreshRateHz
        ).firstOrNull { it < currentFps }

    fun nextHigher(
        currentFps: Int,
        refreshRateHz: Double?,
        ceilingFps: Int = PRODUCT_MAX_FPS,
        floorFps: Int = 1,
        sourceRefreshRateHz: Double? = null
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
                floorFps = floorFps,
                sourceRefreshRateHz = sourceRefreshRateHz
            ).toMutableSet()

        /*
         * Some useful exact divisors (48 on 144 Hz, 42 on 84 Hz, etc.) are not
         * part of the historical pressure ladder. Add only the single proven
         * harmonic ceiling for promotion; do not expand the relief ladder.
         */
        val sourceRefresh = normalizedRefresh(sourceRefreshRateHz)
        harmonicCeiling
            ?.takeIf {
                it in maxOf(currentFps + 1, floorFps)..boundedCeiling &&
                    sourceClockCompatible(sourceRefresh, it)
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
        floorFps: Int = 1,
        sourceRefreshRateHz: Double? = null
    ): Int =
        descending(
            refreshRateHz = refreshRateHz,
            ceilingFps = maxOf(ceilingFps, limitFps),
            floorFps = floorFps,
            sourceRefreshRateHz = sourceRefreshRateHz
        ).firstOrNull { it <= limitFps }
            ?: minOf(limitFps.coerceAtLeast(1), HIGH_CADENCE_MIN_FPS - 1)

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

    private fun sourceClockCompatible(
        sourceRefreshHz: Int?,
        fps: Int
    ): Boolean {
        if (sourceRefreshHz == null || fps <= LOW_CADENCE_MAX_FPS) return true
        if (fps <= 0 || fps > sourceRefreshHz) return false
        return sourceRefreshHz % fps == 0
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
    private const val LOW_CADENCE_MAX_FPS = 30
    private const val HIGH_CADENCE_MIN_FPS = LOW_CADENCE_MAX_FPS + 1
    private const val MAX_HIGH_CADENCE_REPEAT_VSYNCS = 6
    private const val MIN_REFRESH_HZ = 30.0
    private const val MAX_REFRESH_HZ = 240.0
}
