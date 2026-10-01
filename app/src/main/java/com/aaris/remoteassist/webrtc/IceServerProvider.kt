package com.aaris.remoteassist.webrtc

import org.webrtc.PeerConnection

object IceServerProvider {
    data class IceConfig(
        val servers: List<PeerConnection.IceServer>,
        val fromBackend: Boolean
    )

    suspend fun load(
        sessionId: String
    ): List<PeerConnection.IceServer> =
        loadConfig(sessionId).servers

    suspend fun loadConfig(
        sessionId: String,
        timeoutMs: Long = LOAD_TIMEOUT_MS
    ): IceConfig {
        require(sessionId.isNotBlank())
        require(timeoutMs > 0L)

        return IceConfig(
            servers = fallbackServers(),
            fromBackend = false
        )
    }

    fun fallbackServers(): List<PeerConnection.IceServer> = listOf(
        PeerConnection.IceServer.builder(
            "stun:stun.l.google.com:19302"
        ).createIceServer(),
        PeerConnection.IceServer.builder(
            "stun:stun1.l.google.com:19302"
        ).createIceServer()
    )

    private const val LOAD_TIMEOUT_MS = 4_000L
}
