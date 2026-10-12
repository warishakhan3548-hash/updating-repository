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
 * ladder by the clock that physically PRODUCES unique frames. Once the host
 * source clock is known, source harmonics are authoritative: the controller
 * clock is only a presentation-capacity ceiling, never a phase-lock requirement.
 * Source and controller displays are independent clocks across a network; forcing
 * an exact common divisor can discard half the source motion (for example,
 * 60 Hz source -> 90 Hz controller collapsing to 30 fps). When the source clock
 * is unknown, retain the legacy controller short-repeat rule as a safe fallback.
 *
 * 60 fps remains the product ceiling even on unusual high-refresh panels.
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
         * integer divisor of that producer clock. The remote display is not
         * phase-locked to MediaProjection, so its refresh rate may cap how many
         * unique frames are useful but must not require an exact common divisor.
         * A 60 fps source on a 90 Hz controller should therefore remain 60 fps
         * (fresh 16.7 ms motion), not collapse to 30 fps (33.3 ms motion).
         *
         * The older short-repeat controller filter is retained only while source
         * clock evidence is unavailable. <=30 fps remains the pressure/recovery
         * safety ladder and is intentionally left untouched.
         */
        fun admitHigh(fps: Int): Boolean =
            fps in firstHigh..ceiling &&
                sourceClockCompatible(sourceRefresh, fps) &&
                if (sourceRefresh != null) {
                    controllerRefreshCapacityCompatible(refresh, fps)
                } else {
                    controllerClockCompatible(refresh, fps)
                }

        if (ceiling >= firstHigh) {
            legacyDescending
                .asSequence()
                .filter(::admitHigh)
                .forEach(rates::add)

            /*
             * Some useful source harmonics are not in the historical ladder
             * (for example 48 fps from a 144 Hz producer). Add exact producer
             * divisors while respecting only the controller's capacity ceiling.
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

    /**
     * Pressure relief has a different job from steady-state admission.
     *
     * Healthy capture/promotion remains source-harmonic so an unconstrained
     * stream never creates avoidable producer cadence jitter. Once measured
     * pressure says the current high cadence is too expensive, however, jumping
     * straight from 60 -> 30 can be a larger visual discontinuity than using a
     * bounded intermediate cadence.
     *
     * Admit only rungs whose repeat pattern is short on every clock we know.
     * This keeps ordinary relief such as 60 -> 50/45/40/36 on a 60 Hz pair,
     * 60 -> 45 on a 60 Hz source / 90 Hz controller, and 48 -> 36 on a
     * 144 Hz source / 60 Hz controller. Long-beat rates remain rejected.
     *
     * Exact source/controller divisors that are absent from the historical
     * ladder are also eligible (for example 48 fps on a 96 Hz controller)
     * when the other known clock has a short repeat cycle. <=30 fps remains the
     * existing emergency/recovery ladder.
     */
    fun pressureReliefDescending(
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

        fun clockCompatible(clockHz: Int?, fps: Int): Boolean =
            clockHz == null ||
                fps <= LOW_CADENCE_MAX_FPS ||
                shortRepeatCycle(clockHz, fps)

        fun admitHigh(fps: Int): Boolean =
            fps in firstHigh..ceiling &&
                clockCompatible(sourceRefresh, fps) &&
                clockCompatible(refresh, fps)

        if (ceiling >= firstHigh) {
            legacyDescending
                .asSequence()
                .filter(::admitHigh)
                .forEach(rates::add)

            /*
             * Keep useful exact harmonics even when they are not in the legacy
             * pressure ladder. The second known clock must still accept the rung
             * with a short repeat cycle, so this cannot introduce long beats.
             */
            sourceRefresh
                ?.let { source ->
                    (minOf(PRODUCT_MAX_FPS, ceiling, source) downTo firstHigh)
                        .asSequence()
                        .filter { source % it == 0 }
                        .filter(::admitHigh)
                        .forEach(rates::add)
                }
            refresh
                ?.let { display ->
                    (minOf(PRODUCT_MAX_FPS, ceiling, display) downTo firstHigh)
                        .asSequence()
                        .filter { display % it == 0 }
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
        pressureReliefDescending(
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
         * When the source clock is known, promotion follows source harmonics:
         * VideoSource can then select frames at an even producer cadence while
         * WebRTC/EGL absorb the independent receiver-vsync phase. The controller
         * refresh rate remains a hard capacity ceiling only; sending more unique
         * frames than it can present wastes encode/network work.
         *
         * When source-clock evidence is unavailable, keep the historical
         * controller-harmonic promotion rule. This preserves the established
         * fallback behavior without allowing a remote display clock to halve a
         * known-good source cadence.
         */
        val controllerCeiling =
            normalizedRefresh(refreshRateHz)
                ?.let { minOf(ceilingFps, it) }
                ?: ceilingFps
        val promotionClock =
            normalizedRefresh(sourceRefreshRateHz)
                ?: normalizedRefresh(refreshRateHz)
        val harmonicCeiling =
            promotionClock
                ?.let { clock ->
                    harmonicPromotionCeiling(
                        refreshHz = clock,
                        ceilingFps = controllerCeiling
                    )
                }
        val boundedCeiling =
            harmonicCeiling?.let { minOf(controllerCeiling, it) }
                ?: controllerCeiling

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

    /**
     * Resolve an already-proven downward ceiling without needlessly halving
     * cadence when a bounded short-cycle rung can satisfy the same pressure.
     * Unlike nearestAtOrBelow(), this is never used for startup or promotion.
     */
    fun nearestPressureReliefAtOrBelow(
        limitFps: Int,
        refreshRateHz: Double?,
        ceilingFps: Int = PRODUCT_MAX_FPS,
        floorFps: Int = 1,
        sourceRefreshRateHz: Double? = null
    ): Int =
        pressureReliefDescending(
            refreshRateHz = refreshRateHz,
            ceilingFps = maxOf(ceilingFps, limitFps),
            floorFps = floorFps,
            sourceRefreshRateHz = sourceRefreshRateHz
        ).firstOrNull { it <= limitFps }
            ?: minOf(limitFps.coerceAtLeast(1), HIGH_CADENCE_MIN_FPS - 1)

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

    /**
     * Before source-clock evidence exists, prefer controller cadences with a
     * short repeat cycle. Once the producer clock is known this is deliberately
     * no longer used: remote displays are asynchronous and are not phase-locked
     * strongly enough for nominal common-divisor gating to buy end-to-end
     * smoothness.
     */
    private fun controllerClockCompatible(
        controllerRefreshHz: Int?,
        fps: Int
    ): Boolean {
        if (controllerRefreshHz == null || fps <= LOW_CADENCE_MAX_FPS) return true
        if (fps <= 0 || fps > controllerRefreshHz) return false
        return shortRepeatCycle(controllerRefreshHz, fps)
    }

    private fun controllerRefreshCapacityCompatible(
        controllerRefreshHz: Int?,
        fps: Int
    ): Boolean =
        controllerRefreshHz == null ||
            fps <= LOW_CADENCE_MAX_FPS ||
            (fps > 0 && fps <= controllerRefreshHz)

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
