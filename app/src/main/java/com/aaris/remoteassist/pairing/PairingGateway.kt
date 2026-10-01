package com.aaris.remoteassist.pairing

import java.io.Closeable

data class BackendSession(
    val sessionId: String,
    val state: String,
    val displayGeneration: Int,
    val deadlineAtEpochMs: Long? = null
)

interface PairingGateway {
    suspend fun createShareTicket(): ShareTicket
    suspend fun redeemCode(code: String): PairRequest
    suspend fun approve(sessionId: String)
    suspend fun markScreenReady(sessionId: String)
    suspend fun markLive(sessionId: String)
    suspend fun close(sessionId: String)

    fun observeSession(
        sessionId: String,
        listener: (BackendSession) -> Unit,
        onError: (Throwable) -> Unit = {}
    ): Closeable
}
