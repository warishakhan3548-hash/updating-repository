package com.aaris.remoteassist.webrtc

/**
 * Converts Android thermal pressure into a bounded video cadence ceiling.
 *
 * Pressure reductions are immediate because once a device is throttling,
 * continuing to request an unsustainable cadence only creates encoder queueing
 * and visible stutter. Recovery is deliberately slow and one-rung-at-a-time so
 * a cooling device cannot bounce 30 <-> 60 fps as its thermal status fluctuates.
 */
internal class ThermalVideoGovernor(
    private val maxFps: Int
) {
    enum class Pressure {
        NORMAL,
        WARM,
        HOT,
        CRITICAL,
        EMERGENCY
    }

    @Volatile
    var cap: Int = maxFps.coerceAtLeast(MIN_CAP_FPS)
        private set

    private var recoveryEligibleAtMs = Long.MIN_VALUE

    fun observe(
        pressure: Pressure,
        nowMs: Long
    ): Boolean {
        val desiredCap =
            when (pressure) {
                Pressure.NORMAL -> maxFps
                Pressure.WARM -> minOf(maxFps, WARM_CAP_FPS)
                Pressure.HOT -> minOf(maxFps, HOT_CAP_FPS)
                Pressure.CRITICAL -> minOf(maxFps, CRITICAL_CAP_FPS)
                Pressure.EMERGENCY -> minOf(maxFps, EMERGENCY_CAP_FPS)
            }.coerceAtLeast(MIN_CAP_FPS)

        if (desiredCap < cap) {
            cap = desiredCap
            recoveryEligibleAtMs =
                safeAdd(nowMs, RECOVERY_HOLD_MS)
            return true
        }

        if (desiredCap <= cap) {
            recoveryEligibleAtMs = Long.MIN_VALUE
            return false
        }

        if (recoveryEligibleAtMs == Long.MIN_VALUE) {
            recoveryEligibleAtMs =
                safeAdd(nowMs, RECOVERY_HOLD_MS)
            return false
        }
        if (nowMs < recoveryEligibleAtMs) return false

        val next =
            ASCENDING_CAPS.firstOrNull {
                it > cap && it <= desiredCap && it <= maxFps
            } ?: desiredCap

        if (next == cap) return false

        cap = next
        recoveryEligibleAtMs =
            if (cap < desiredCap) {
                safeAdd(nowMs, RECOVERY_STEP_MS)
            } else {
                Long.MIN_VALUE
            }
        return true
    }

    private fun safeAdd(
        base: Long,
        delta: Long
    ): Long =
        if (base > Long.MAX_VALUE - delta) {
            Long.MAX_VALUE
        } else {
            base + delta
        }

    private companion object {
        val ASCENDING_CAPS =
            listOf(15, 20, 24, 30, 45, 60)

        const val MIN_CAP_FPS = 15
        const val WARM_CAP_FPS = 45
        const val HOT_CAP_FPS = 30
        const val CRITICAL_CAP_FPS = 24
        const val EMERGENCY_CAP_FPS = 15

        const val RECOVERY_HOLD_MS = 15_000L
        const val RECOVERY_STEP_MS = 10_000L
    }
}
