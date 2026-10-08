package com.aaris.remoteassist.webrtc

enum class InboundVideoLivenessAction {
    NONE,
    REQUEST_RECOVERY,
    CONFIRM_PRIMARY_RECOVERED
}

/**
 * Detects a stopped decoder from monotonic inbound RTP counters.
 *
 * getStats() is already sampled more frequently during interactions than while
 * idle. A sample-count threshold therefore gives wildly different recovery
 * deadlines depending on the current stats cadence. Use elapsed time instead,
 * without adding a poll, timer, frame copy, or media queue.
 *
 * Incoming RTP without decoder progress is strong stall evidence. Before
 * the first decoded frame we allow a longer bounded startup/keyframe grace
 * before requesting recovery; after startup a stalled decoder reacts faster.
 * When neither counter advances, tolerate a much longer network/quiet-screen
 * gap. Alternating packet bursts never inherit decoder-stall evidence from
 * an unrelated interval.
 */
class InboundVideoLivenessMonitor(
    private val decoderStallMs: Long = 2_500L,
    private val firstFrameDecodeStallMs: Long = 5_000L,
    private val transportStallMs: Long = 12_000L,
    private val retryCooldownMs: Long = 4_000L,
    private val maxRecoveryAttempts: Int = 2
) {
    init {
        require(decoderStallMs >= 1_000L)
        require(firstFrameDecodeStallMs > decoderStallMs)
        require(transportStallMs > firstFrameDecodeStallMs)
        require(retryCooldownMs >= 1_000L)
        require(maxRecoveryAttempts in 1..4)
    }

    private var lastFramesReceived = -1L
    private var lastFramesDecoded = -1L
    private var lastSampleAtMs = -1L
    private var decoderStallSinceMs: Long? = null
    private var transportStallSinceMs: Long? = null
    private var lastRecoveryAttemptMs: Long? = null
    private var recoveryPending = false
    private var recoveryAttempts = 0

    @Synchronized
    fun observe(
        framesReceived: Long,
        framesDecoded: Long,
        nowMs: Long
    ): InboundVideoLivenessAction {
        if (framesReceived < 0L || framesDecoded < 0L || nowMs < 0L) {
            return InboundVideoLivenessAction.NONE
        }

        if (
            lastSampleAtMs < 0L ||
            nowMs < lastSampleAtMs ||
            framesReceived < lastFramesReceived ||
            framesDecoded < lastFramesDecoded
        ) {
            // First sample, clock discontinuity, or a new RTP counter generation.
            lastFramesReceived = framesReceived
            lastFramesDecoded = framesDecoded
            lastSampleAtMs = nowMs
            decoderStallSinceMs = null
            transportStallSinceMs = null
            lastRecoveryAttemptMs = null
            recoveryPending = false
            recoveryAttempts = 0
            return InboundVideoLivenessAction.NONE
        }

        val sampleGapMs = nowMs - lastSampleAtMs
        val receivedAdvanced = framesReceived > lastFramesReceived
        val decodedAdvanced = framesDecoded > lastFramesDecoded
        lastFramesReceived = framesReceived
        lastFramesDecoded = framesDecoded
        lastSampleAtMs = nowMs

        if (decodedAdvanced) {
            decoderStallSinceMs = null
            transportStallSinceMs = null
            return if (recoveryPending) {
                InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED
            } else {
                InboundVideoLivenessAction.NONE
            }
        }

        // Without any received frame, no decoder exists to diagnose. But RTP
        // that *continues* to arrive without even one decoded picture is a real
        // first-frame black-screen failure. The viewer's first-swap watchdog
        // cannot establish decoder health from the absence of render events.
        if (framesReceived == 0L) {
            decoderStallSinceMs = null
            transportStallSinceMs = null
            return InboundVideoLivenessAction.NONE
        }

        // A long stats-report hole does not prove uninterrupted RTP supply.
        // Require contiguous evidence before diagnosing a first-frame stall.
        // Idle getStats runs every 1.5s, so 3s allows ordinary scheduling jitter.
        if (framesDecoded == 0L && sampleGapMs > 3_000L) {
            decoderStallSinceMs = null
        }

        if (receivedAdvanced) {
            transportStallSinceMs = null
            if (decoderStallSinceMs == null) decoderStallSinceMs = nowMs
        } else {
            // A brief RTP pause must not count as ongoing decoder overload.
            decoderStallSinceMs = null
            if (transportStallSinceMs == null) transportStallSinceMs = nowMs
        }

        val stalled =
            if (receivedAdvanced) {
                decoderStallSinceMs?.let {
                    nowMs - it >=
                        if (framesDecoded == 0L) firstFrameDecodeStallMs
                        else decoderStallMs
                } == true
            } else {
                transportStallSinceMs?.let { nowMs - it >= transportStallMs } == true
            }
        val retryAllowed =
            lastRecoveryAttemptMs?.let { nowMs - it >= retryCooldownMs } != false

        // A successfully sent request does not prove the codec recovered. If
        // decode remains stalled, allow one bounded follow-up after cooldown.
        // Never loop indefinitely while the same stream has no glass proof.
        if (!stalled || !retryAllowed || recoveryAttempts >= maxRecoveryAttempts) {
            return InboundVideoLivenessAction.NONE
        }

        lastRecoveryAttemptMs = nowMs
        recoveryAttempts += 1
        recoveryPending = true
        return InboundVideoLivenessAction.REQUEST_RECOVERY
    }

    @Synchronized
    fun markRecoveryRequestFailed() {
        // A failed transport request can retry after the same bounded cooldown.
        // The next getStats() must not spin recovery requests every 500 ms.
        recoveryPending = false
    }

    @Synchronized
    fun markPrimaryRecoveredConfirmed() {
        recoveryPending = false
        decoderStallSinceMs = null
        transportStallSinceMs = null
        lastRecoveryAttemptMs = null
        recoveryAttempts = 0
    }

    @Synchronized
    fun reset() {
        lastFramesReceived = -1L
        lastFramesDecoded = -1L
        lastSampleAtMs = -1L
        decoderStallSinceMs = null
        transportStallSinceMs = null
        lastRecoveryAttemptMs = null
        recoveryPending = false
        recoveryAttempts = 0
    }
}
