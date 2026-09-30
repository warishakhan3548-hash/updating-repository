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
    fun sendDescription(description: SignalDescription)
    fun sendCandidate(candidate: SignalCandidate)
    fun setPresence(online: Boolean)
}
