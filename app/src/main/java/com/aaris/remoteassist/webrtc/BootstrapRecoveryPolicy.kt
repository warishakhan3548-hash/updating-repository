package com.aaris.remoteassist.webrtc

/**
 * Keeps startup recovery from racing a healthy ICE check.
 *
 * SDP becoming STABLE only proves that offer/answer negotiation finished.
 * Connectivity can still need a few seconds on cellular, carrier-NAT or TURN.
 */
internal object BootstrapRecoveryPolicy {
    fun shouldWaitAfterRemoteAnswer(
        lastRemoteAnswerAppliedAtMs: Long,
        nowMs: Long,
        settleWindowMs: Long
    ): Boolean {
        require(settleWindowMs > 0L)
        if (lastRemoteAnswerAppliedAtMs <= 0L) return false

        val elapsedMs =
            (nowMs - lastRemoteAnswerAppliedAtMs)
                .coerceAtLeast(0L)
        return elapsedMs < settleWindowMs
    }
}
