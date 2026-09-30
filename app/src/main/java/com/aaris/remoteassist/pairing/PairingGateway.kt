package com.aaris.remoteassist.pairing

interface PairingGateway {
    suspend fun createShareTicket(): ShareTicket
    suspend fun redeemCode(code: String): PairRequest
    suspend fun approve(sessionId: String)
    suspend fun close(sessionId: String)
}
