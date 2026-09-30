package com.aaris.remoteassist.pairing

import com.aaris.remoteassist.session.SessionState
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import com.google.firebase.functions.FirebaseFunctions
import kotlinx.coroutines.tasks.await

class FirebasePairingGateway(
    private val auth: FirebaseAuth = FirebaseAuth.getInstance(),
    private val functions: FirebaseFunctions = FirebaseFunctions.getInstance(),
    private val database: FirebaseDatabase = FirebaseDatabase.getInstance()
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

    override suspend fun beginConnecting(sessionId: String) {
        ensureSignedIn()
        functions.getHttpsCallable("beginHostConnection")
            .call(mapOf("sessionId" to sessionId))
            .await()
    }

    override suspend fun close(sessionId: String) {
        ensureSignedIn()
        functions.getHttpsCallable("closePairingSession")
            .call(mapOf("sessionId" to sessionId))
            .await()
    }

    override fun watchSession(
        sessionId: String,
        onUpdate: (RemoteSessionView) -> Unit,
        onError: (Throwable) -> Unit
    ): AutoCloseable {
        val ref = database.getReference("sessions").child(sessionId)
        val listener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                runCatching {
                    val hostUid = snapshot.child("hostUid").getValue(String::class.java)
                        ?: error("Missing host")
                    val controllerUid = snapshot.child("controllerUid").getValue(String::class.java)
                    val stateRaw = snapshot.child("state").getValue(String::class.java)
                        ?: error("Missing state")
                    val expiresAt = snapshot.child("expiresAt").getValue(Long::class.java) ?: 0L
                    RemoteSessionView(
                        sessionId = sessionId,
                        hostUid = hostUid,
                        controllerUid = controllerUid,
                        state = SessionState.valueOf(stateRaw),
                        expiresAtEpochMs = expiresAt
                    )
                }.onSuccess(onUpdate).onFailure(onError)
            }

            override fun onCancelled(error: DatabaseError) {
                onError(error.toException())
            }
        }
        ref.addValueEventListener(listener)
        return AutoCloseable { ref.removeEventListener(listener) }
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
