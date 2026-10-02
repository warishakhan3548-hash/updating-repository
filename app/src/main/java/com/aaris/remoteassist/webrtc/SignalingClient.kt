package com.aaris.remoteassist.webrtc

import java.io.Closeable

interface SignalingClient : Closeable {
    interface Listener {
        fun onRemoteDescription(description: SignalDescription)
        fun onRemoteDescriptionRedelivery(
            description: SignalDescription
        ) {
            onRemoteDescription(description)
        }
        fun onRemoteCandidate(candidate: SignalCandidate)
        fun onRemoteIceRestartRequested()
        fun onRemotePresence(online: Boolean)
        fun onSignalingDiagnostic(message: String) = Unit
        fun onError(error: Throwable)
    }

    fun start(listener: Listener)
    fun beginLocalDescription(): Long
    fun sendDescription(
        description: SignalDescription,
        negotiationEpoch: Long
    )
    fun retryLocalDescription(): Boolean = false
    fun sendCandidate(candidate: SignalCandidate)
    fun requestRemoteIceRestart()
    fun setPresence(online: Boolean)
}
