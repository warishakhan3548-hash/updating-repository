package com.aaris.remoteassist.pairing

interface PairingGateway {
    suspend fun createShareTicket(): ShareTicket
    suspend fun redeemCode(code: String): PairRequest
    suspend fun approve(sessionId: String)
    suspend fun beginConnecting(sessionId: String)
    suspend fun close(sessionId: String)

    fun watchSession(
        sessionId: String,
        onUpdate: (RemoteSessionView) -> Unit,
        onError: (Throwable) -> Unit
    ): AutoCloseable
}
