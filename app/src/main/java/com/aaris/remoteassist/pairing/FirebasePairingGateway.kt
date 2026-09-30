package com.aaris.remoteassist.pairing

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import com.google.firebase.functions.FirebaseFunctions
import kotlinx.coroutines.tasks.await
import java.io.Closeable

class FirebasePairingGateway(
    context: Context
) : PairingGateway {
    private val appContext = context.applicationContext

    override suspend fun createShareTicket(): ShareTicket {
        ensureSignedIn()
        val result = functions()
            .getHttpsCallable("createPairingSession")
            .call()
            .await()
        val map = result.data as? Map<*, *>
            ?: error("Invalid createPairingSession response")
        return ShareTicket(
            sessionId = map.string("sessionId"),
            code = map.string("code"),
            expiresAtEpochMs = map.longAny("expiresAtMs", "expiresAt")
        )
    }

    override suspend fun redeemCode(code: String): PairRequest {
        ensureSignedIn()
        val normalized = PairingCode.normalize(code)
            ?: error("Enter a valid 6-digit code")
        val result = functions()
            .getHttpsCallable("redeemPairingCode")
            .call(mapOf("code" to normalized))
            .await()
        val map = result.data as? Map<*, *>
            ?: error("Invalid redeemPairingCode response")
        return PairRequest(
            sessionId = map.string("sessionId"),
            hostUid = map.string("hostUid"),
            controllerUid = auth().currentUser?.uid
        )
    }

    override suspend fun approve(sessionId: String) {
        callSessionFunction("approvePairingSession", sessionId)
    }

    override suspend fun markScreenReady(sessionId: String) {
        callSessionFunction("markScreenReady", sessionId)
    }

    override suspend fun close(sessionId: String) {
        callSessionFunction("closePairingSession", sessionId)
    }

    override fun observeSession(
        sessionId: String,
        listener: (BackendSession) -> Unit,
        onError: (Throwable) -> Unit
    ): Closeable {
        requireConfigured()
        val reference = FirebaseDatabase.getInstance()
            .getReference("sessions")
            .child(sessionId)

        val valueListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val state = snapshot.child("state")
                    .getValue(String::class.java) ?: return
                val generation = snapshot.child("displayGeneration")
                    .getValue(Long::class.java)?.toInt() ?: 0
                listener(
                    BackendSession(
                        sessionId = sessionId,
                        state = state,
                        displayGeneration = generation
                    )
                )
            }

            override fun onCancelled(error: DatabaseError) {
                onError(error.toException())
            }
        }

        reference.addValueEventListener(valueListener)
        return Closeable { reference.removeEventListener(valueListener) }
    }

    private suspend fun callSessionFunction(name: String, sessionId: String) {
        ensureSignedIn()
        functions()
            .getHttpsCallable(name)
            .call(mapOf("sessionId" to sessionId))
            .await()
    }

    private suspend fun ensureSignedIn() {
        requireConfigured()
        val auth = auth()
        if (auth.currentUser == null) auth.signInAnonymously().await()
        checkNotNull(auth.currentUser) {
            "Firebase anonymous authentication failed"
        }
    }

    private fun requireConfigured() {
        check(FirebaseApp.getApps(appContext).isNotEmpty()) {
            "Firebase project is not configured on this build yet."
        }
    }

    private fun auth(): FirebaseAuth {
        requireConfigured()
        return FirebaseAuth.getInstance()
    }

    private fun functions(): FirebaseFunctions {
        requireConfigured()
        return FirebaseFunctions.getInstance()
    }

    private fun Map<*, *>.string(key: String): String =
        this[key] as? String ?: error("Missing " + key)

    private fun Map<*, *>.longAny(vararg keys: String): Long {
        for (key in keys) {
            val value = this[key] as? Number
            if (value != null) return value.toLong()
        }
        error("Missing numeric field")
    }
}
