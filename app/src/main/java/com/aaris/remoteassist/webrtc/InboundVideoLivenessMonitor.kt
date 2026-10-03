package com.aaris.remoteassist.webrtc

enum class InboundVideoLivenessAction {
    NONE,
    REQUEST_RECOVERY,
    CONFIRM_PRIMARY_RECOVERED
}

/**
 * Detects a primary-video stall from monotonic inbound RTP counters.
 *
 * The monitor deliberately reacts much faster when RTP frames continue to
 * arrive but decoding stops, because that is strong evidence of a decoder /
 * render pipeline problem. If both receive and decode counters stop, it waits
 * longer before recovery to avoid overreacting to a short network pause.
 *
 * WebRTC stats are sampled every few seconds, so this policy is intentionally
 * sample-based and deterministic rather than depending on wall-clock timers.
 */
class InboundVideoLivenessMonitor(
    private val stagnantScoreBeforeRecovery: Int = 4
) {
    init {
        require(stagnantScoreBeforeRecovery >= 2)
    }

    private var lastFramesReceived = -1L
    private var lastFramesDecoded = -1L
    private var stagnantScore = 0
    private var recoveryPending = false

    @Synchronized
    fun observe(
        framesReceived: Long,
        framesDecoded: Long
    ): InboundVideoLivenessAction {
        if (framesReceived < 0L || framesDecoded < 0L) {
            return InboundVideoLivenessAction.NONE
        }

        if (
            lastFramesReceived < 0L ||
            lastFramesDecoded < 0L ||
            framesReceived < lastFramesReceived ||
            framesDecoded < lastFramesDecoded
        ) {
            lastFramesReceived = framesReceived
            lastFramesDecoded = framesDecoded
            stagnantScore = 0
            return InboundVideoLivenessAction.NONE
        }

        val receivedAdvanced =
            framesReceived > lastFramesReceived
        val decodedAdvanced =
            framesDecoded > lastFramesDecoded

        lastFramesReceived = framesReceived
        lastFramesDecoded = framesDecoded

        if (decodedAdvanced) {
            stagnantScore = 0
            return if (recoveryPending) {
                InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED
            } else {
                InboundVideoLivenessAction.NONE
            }
        }

        /*
         * Do not diagnose a freeze until the primary path has demonstrated
         * successful receive+decode at least once in this stats generation.
         */
        if (framesReceived <= 0L || framesDecoded <= 0L) {
            stagnantScore = 0
            return InboundVideoLivenessAction.NONE
        }

        if (recoveryPending) {
            return InboundVideoLivenessAction.NONE
        }

        stagnantScore += if (receivedAdvanced) 2 else 1
        if (stagnantScore < stagnantScoreBeforeRecovery) {
            return InboundVideoLivenessAction.NONE
        }

        stagnantScore = 0
        recoveryPending = true
        return InboundVideoLivenessAction.REQUEST_RECOVERY
    }

    @Synchronized
    fun markRecoveryRequestFailed() {
        if (!recoveryPending) return
        recoveryPending = false
        stagnantScore =
            (stagnantScoreBeforeRecovery - 1)
                .coerceAtLeast(0)
    }

    @Synchronized
    fun markPrimaryRecoveredConfirmed() {
        recoveryPending = false
        stagnantScore = 0
    }

    @Synchronized
    fun reset() {
        lastFramesReceived = -1L
        lastFramesDecoded = -1L
        stagnantScore = 0
        recoveryPending = false
    }
}
