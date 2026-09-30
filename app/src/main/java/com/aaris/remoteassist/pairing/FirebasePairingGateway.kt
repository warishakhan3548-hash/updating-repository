package com.aaris.remoteassist.pairing

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.functions.FirebaseFunctions
import kotlinx.coroutines.tasks.await

class FirebasePairingGateway(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val functions: FirebaseFunctions = FirebaseFunctions.getInstance()
) : PairingGateway {

    override suspend fun createShareTicket(): ShareTicket {
        ensureSignedIn()
        val result = functions.getHttpsCallable("createPairingSession").call().await()
        val map = result.data as? Map<*, *> ?: error("Invalid createPairingSession response")
        return ShareTicket(
            sessionId = map.string("sessionId"),
            code = map.string("code"),
            expiresAtEpochMs = map.long("expiresAt")
        )
    }

    override suspend fun redeemCode(code: String): PairRequest {
        ensureSignedIn()
        val normalized = PairingCode.normalize(code) ?: error("Enter a valid 6-digit code")
        val result = functions.getHttpsCallable("redeemPairingCode")
            .call(mapOf("code" to normalized))
            .await()
        val map = result.data as? Map<*, *> ?: error("Invalid redeemPairingCode response")
        return PairRequest(
            sessionId = map.string("sessionId"),
            hostUid = map.string("hostUid"),
            controllerUid = auth.currentUser?.uid
        )
    }

    override suspend fun approve(sessionId: String) {
        ensureSignedIn()
        functions.getHttpsCallable("approvePairingSession")
            .call(mapOf("sessionId" to sessionId))
            .await()
    }

    override suspend fun close(sessionId: String) {
        ensureSignedIn()
        functions.getHttpsCallable("closePairingSession")
            .call(mapOf("sessionId" to sessionId))
            .await()
    }

    private suspend fun ensureSignedIn() {
        if (auth.currentUser == null) auth.signInAnonymously().await()
        checkNotNull(auth.currentUser) { "Firebase anonymous authentication failed" }
    }

    private fun Map<*, *>.string(key: String): String =
        this[key] as? String ?: error("Missing $key")

    private fun Map<*, *>.long(key: String): Long =
        (this[key] as? Number)?.toLong() ?: error("Missing $key")
}
