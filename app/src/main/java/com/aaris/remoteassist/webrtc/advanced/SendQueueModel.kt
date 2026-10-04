package com.aaris.remoteassist.webrtc.advanced

/**
 * Low-cost leaky-bucket model for instantaneous encoder send pressure.
 *
 * This is telemetry first: it estimates how long the currently encoded bytes
 * would take to drain at the encoder's target rate. It does not replace GCC,
 * the pacer, retransmission, or libwebrtc bandwidth estimation.
 */
class LeakyBucketSendModel(
    initialTargetBps: Long = DEFAULT_TARGET_BPS
) {
    private var targetBps = initialTargetBps.coerceAtLeast(MIN_TARGET_BPS)
    private var bufferedBits = 0.0
    private var lastNs = 0L
    private var rateObserved = false

    @Synchronized
    fun setTargetBps(nowNs: Long, bps: Long) {
        drain(nowNs)
        targetBps = bps.coerceAtLeast(MIN_TARGET_BPS)
        rateObserved = true
    }

    /** Returns predicted drain time after adding this encoded frame. */
    @Synchronized
    fun onFrameEncoded(nowNs: Long, frameBytes: Int): Double? {
        if (frameBytes < 0) return null
        drain(nowNs)
        if (!rateObserved) return null
        val frameBits = frameBytes.toDouble() * 8.0
        val delayMs = (bufferedBits + frameBits) / targetBps.toDouble() * 1_000.0
        bufferedBits += frameBits
        return delayMs.takeIf { it.isFinite() && it >= 0.0 }
    }

    /** Current predicted sender residence without adding a frame. */
    @Synchronized
    fun queueDelayMs(nowNs: Long): Double? {
        drain(nowNs)
        if (!rateObserved) return null
        return (bufferedBits / targetBps.toDouble() * 1_000.0)
            .takeIf { it.isFinite() && it >= 0.0 }
    }

    @Synchronized
    fun reset(nowNs: Long = 0L) {
        bufferedBits = 0.0
        lastNs = nowNs
        rateObserved = false
    }

    private fun drain(nowNs: Long) {
        if (lastNs != 0L && nowNs >= lastNs) {
            val elapsedSeconds = (nowNs - lastNs).toDouble() / 1_000_000_000.0
            bufferedBits =
                (bufferedBits - targetBps.toDouble() * elapsedSeconds)
                    .coerceAtLeast(0.0)
        }
        lastNs = nowNs
    }

    private companion object {
        const val MIN_TARGET_BPS = 50_000L
        const val DEFAULT_TARGET_BPS = 1_000_000L
    }
}

/**
 * Hysteresis policy for latest-frame admission under proven queue pressure.
 *
 * Aaris initially runs this in SHADOW mode in ScreenCaptureTrack: decisions are
 * counted but frames are still forwarded. This makes the thresholds measurable
 * on real devices before any capture behaviour changes.
 */
class BoundedStalenessGate(
    private val engageMs: Double = 90.0,
    private val releaseMs: Double = 45.0,
    private val maxStarveMs: Long = 250L
) {
    private var dropping = false
    private var lastAdmitMs = 0L

    init {
        require(engageMs > releaseMs && releaseMs >= 0.0)
        require(maxStarveMs > 0L)
    }

    @Synchronized
    fun admit(nowMs: Long, queueDelayMs: Double): Boolean {
        if (!queueDelayMs.isFinite() || queueDelayMs < 0.0) return true

        if (!dropping && queueDelayMs >= engageMs) {
            dropping = true
        } else if (dropping && queueDelayMs <= releaseMs) {
            dropping = false
        }

        val starving =
            lastAdmitMs != 0L &&
                nowMs >= lastAdmitMs &&
                nowMs - lastAdmitMs >= maxStarveMs
        val admit = !dropping || starving
        if (admit) lastAdmitMs = nowMs
        return admit
    }

    @Synchronized
    fun reset() {
        dropping = false
        lastAdmitMs = 0L
    }
}
