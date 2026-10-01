package com.aaris.remoteassist.webrtc

import java.io.Closeable

interface SignalingClient : Closeable {
    interface Listener {
        fun onRemoteDescription(description: SignalDescription)
        fun onRemoteCandidate(candidate: SignalCandidate)
        fun onRemotePresence(online: Boolean)
        fun onError(error: Throwable)
    }

    fun start(listener: Listener)
    fun beginLocalDescription(): Long
    fun sendDescription(
        description: SignalDescription,
        negotiationEpoch: Long
    )
    fun sendCandidate(candidate: SignalCandidate)
    fun requestRemoteIceRestart()
    fun setPresence(online: Boolean)
}
