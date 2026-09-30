package com.aaris.remoteassist.webrtc

internal class PeerConnectivityTracker {
    private val lock = Any()
    private var everConnected = false
    private var lastReported: Boolean? = null

    fun onConnected(): Boolean = synchronized(lock) {
        everConnected = true
        if (lastReported == true) {
            false
        } else {
            lastReported = true
            true
        }
    }

    fun onDisconnected(): Boolean = synchronized(lock) {
        if (!everConnected || lastReported == false) {
            false
        } else {
            lastReported = false
            true
        }
    }

    fun hasEverConnected(): Boolean = synchronized(lock) {
        everConnected
    }
}
