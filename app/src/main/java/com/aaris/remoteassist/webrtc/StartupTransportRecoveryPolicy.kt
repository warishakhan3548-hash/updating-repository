package com.aaris.remoteassist.webrtc

/**
 * Decides whether startup should renegotiate when WebRTC reports a peer path
 * but the ordered control channel has still not become usable.
 *
 * This keeps the host from sitting on a misleading peer-level CONNECTED state
 * until the outer 60-second session watchdog expires.
 */
internal object StartupTransportRecoveryPolicy {
    fun shouldAttempt(
        peerConnected: Boolean,
        controlChannelOpen: Boolean,
        transportReady: Boolean,
        completedAttempts: Int,
        maxAttempts: Int
    ): Boolean {
        require(completedAttempts >= 0)
        require(maxAttempts > 0)

        return peerConnected &&
            !controlChannelOpen &&
            !transportReady &&
            completedAttempts < maxAttempts
    }

    fun shouldForceRelay(
        completedAttempts: Int
    ): Boolean {
        require(completedAttempts >= 0)

        // First retry keeps all viable direct + relay paths. If that still
        // cannot establish the SCTP/DataChannel path, the second retry prefers
        // authenticated TURN when it is available.
        return completedAttempts > 0
    }
}
