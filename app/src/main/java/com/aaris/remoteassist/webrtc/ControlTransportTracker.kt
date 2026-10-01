package com.aaris.remoteassist.webrtc

internal class ControlTransportTracker {
    private val lock = Any()
    private var peerConnected = false
    private var controlChannelOpen = false
    private var lastReportedReady = false

    fun onPeerConnected(): Boolean? =
        update(peerConnected = true)

    fun onPeerDisconnected(): Boolean? =
        update(peerConnected = false)

    fun onControlChannelOpen(): Boolean? =
        update(controlChannelOpen = true)

    fun onControlChannelClosed(): Boolean? =
        update(controlChannelOpen = false)

    private fun update(
        peerConnected: Boolean? = null,
        controlChannelOpen: Boolean? = null
    ): Boolean? = synchronized(lock) {
        peerConnected?.let {
            this.peerConnected = it
        }
        controlChannelOpen?.let {
            this.controlChannelOpen = it
        }

        val ready =
            this.peerConnected &&
                this.controlChannelOpen

        if (ready == lastReportedReady) {
            null
        } else {
            lastReportedReady = ready
            ready
        }
    }
}
