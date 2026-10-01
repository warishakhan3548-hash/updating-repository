package com.aaris.remoteassist.pairing

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import java.io.Closeable
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.tasks.await
import kotlinx.coroutines.withTimeout

class FirebasePairingGateway(
    context: Context
) : PairingGateway {
    private val appContext = context.applicationContext
    private val secureRandom = SecureRandom()

    override suspend fun createShareTicket(): ShareTicket {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val database = database()

        repeat(CODE_ALLOCATION_ATTEMPTS) {
            val code = generateCode()
            val codeHash = hashCode(code)
            val sessionId = UUID.randomUUID().toString()
            val now = System.currentTimeMillis()
            val expiresAtMs = now + CODE_TTL_MS

            val codeRef = database
                .getReference("pairingCodes")
                .child(codeHash)

            val occupied = withTimeout(DATABASE_TIMEOUT_MS) {
                codeRef.get().await().exists()
            }
            if (occupied) return@repeat

            val codeRecord = mapOf(
                "sessionId" to sessionId,
                "hostUid" to uid,
                "expiresAtMs" to expiresAtMs
            )

            val session = mapOf(
                "hostUid" to uid,
                "state" to "CODE_ACTIVE",
                "createdAtMs" to now,
                "expiresAtMs" to expiresAtMs,
                "displayGeneration" to 0,
                "pairingHash" to codeHash
            )

            try {
                withTimeout(DATABASE_TIMEOUT_MS) {
                    codeRef.setValue(codeRecord).await()
                    database
                        .getReference("sessions")
                        .child(sessionId)
                        .setValue(session)
                        .await()
                }

                return ShareTicket(
                    sessionId = sessionId,
                    code = code,
                    expiresAtEpochMs = expiresAtMs
                )
            } catch (error: Throwable) {
                runCatching {
                    codeRef.removeValue().await()
                }
                if (it == CODE_ALLOCATION_ATTEMPTS - 1) {
                    throw error
                }
            }
        }

        error("Could not allocate a pairing code. Try again.")
    }

    override suspend fun redeemCode(code: String): PairRequest {
        ensureSignedIn()
        val normalized = PairingCode.normalize(code)
            ?: error("Enter a valid 12-digit code")
        val uid = requireNotNull(auth().currentUser?.uid)
        val database = database()
        val codeHash = hashCode(normalized)

        val codeSnapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            database
                .getReference("pairingCodes")
                .child(codeHash)
                .get()
                .await()
        }

        if (!codeSnapshot.exists()) {
            error("Code expired or invalid.")
        }

        val sessionId = codeSnapshot
            .child("sessionId")
            .getValue(String::class.java)
            ?: error("Code expired or invalid.")
        val hostUid = codeSnapshot
            .child("hostUid")
            .getValue(String::class.java)
            ?: error("Code expired or invalid.")
        val expiresAtMs = codeSnapshot
            .child("expiresAtMs")
            .getValue(Long::class.java)
            ?: 0L

        if (hostUid == uid) {
            error("Use this code from the other phone.")
        }
        if (expiresAtMs <= System.currentTimeMillis()) {
            error("Code expired.")
        }

        val sessionRef = database
            .getReference("sessions")
            .child(sessionId)
        val before = withTimeout(DATABASE_TIMEOUT_MS) {
            sessionRef.get().await()
        }

        if (!before.exists()) {
            error("Session no longer exists.")
        }
        if (before.child("state").getValue(String::class.java) != "CODE_ACTIVE") {
            error("That code is already being used.")
        }

        val now = System.currentTimeMillis()
        val updates = mapOf<String, Any?>(
            "controllerUid" to uid,
            "state" to "PAIR_PENDING",
            "pairedAtMs" to now,
            "approvalExpiresAtMs" to (now + PAIR_APPROVAL_TTL_MS)
        )

        withTimeout(DATABASE_TIMEOUT_MS) {
            sessionRef.updateChildren(updates).await()
        }

        return PairRequest(
            sessionId = sessionId,
            hostUid = hostUid,
            controllerUid = uid
        )
    }

    override suspend fun approve(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val ref = sessionRef(sessionId)
        val snapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            ref.get().await()
        }

        requireHost(snapshot, uid)
        check(snapshot.child("state").getValue(String::class.java) == "PAIR_PENDING") {
            "No valid connection request."
        }

        val approvalDeadline = snapshot
            .child("approvalExpiresAtMs")
            .getValue(Long::class.java)
            ?: 0L
        check(approvalDeadline > System.currentTimeMillis()) {
            "Pairing request expired. Create a new code."
        }

        val now = System.currentTimeMillis()
        withTimeout(DATABASE_TIMEOUT_MS) {
            ref.updateChildren(
                mapOf(
                    "state" to "HOST_APPROVED",
                    "approvedAtMs" to now,
                    "connectExpiresAtMs" to (now + CONNECT_SETUP_TTL_MS)
                )
            ).await()
        }
    }

    override suspend fun markScreenReady(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val ref = sessionRef(sessionId)
        val snapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            ref.get().await()
        }

        requireHost(snapshot, uid)
        check(snapshot.child("state").getValue(String::class.java) == "HOST_APPROVED") {
            "Session was not approved."
        }

        val connectDeadline = snapshot
            .child("connectExpiresAtMs")
            .getValue(Long::class.java)
            ?: 0L
        check(connectDeadline > System.currentTimeMillis()) {
            "Connection setup expired. Create a new code."
        }

        withTimeout(DATABASE_TIMEOUT_MS) {
            ref.updateChildren(
                mapOf(
                    "state" to "SCREEN_READY",
                    "screenReadyAtMs" to System.currentTimeMillis()
                )
            ).await()
        }

        val pairingHash = snapshot
            .child("pairingHash")
            .getValue(String::class.java)
        if (!pairingHash.isNullOrBlank()) {
            runCatching {
                database()
                    .getReference("pairingCodes")
                    .child(pairingHash)
                    .removeValue()
                    .await()
            }
        }
    }

    override suspend fun markLive(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val ref = sessionRef(sessionId)
        val snapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            ref.get().await()
        }

        requireHost(snapshot, uid)
        check(snapshot.child("state").getValue(String::class.java) == "SCREEN_READY") {
            "Session is not ready for live transport."
        }

        val connectDeadline = snapshot
            .child("connectExpiresAtMs")
            .getValue(Long::class.java)
            ?: 0L
        check(connectDeadline > System.currentTimeMillis()) {
            "Connection setup expired. Create a new code."
        }

        withTimeout(DATABASE_TIMEOUT_MS) {
            ref.updateChildren(
                mapOf(
                    "state" to "LIVE",
                    "liveAtMs" to System.currentTimeMillis()
                )
            ).await()
        }
    }

    override suspend fun close(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val ref = sessionRef(sessionId)
        val snapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            ref.get().await()
        }

        if (!snapshot.exists()) return

        val hostUid = snapshot
            .child("hostUid")
            .getValue(String::class.java)
        val controllerUid = snapshot
            .child("controllerUid")
            .getValue(String::class.java)

        when (uid) {
            hostUid -> {
                withTimeout(DATABASE_TIMEOUT_MS) {
                    ref.updateChildren(
                        mapOf(
                            "state" to "CLOSED",
                            "closedAtMs" to System.currentTimeMillis(),
                            "hostSignal" to null,
                            "controllerSignal" to null,
                            "hostCandidates" to null,
                            "controllerCandidates" to null,
                            "presence" to null
                        )
                    ).await()
                }
            }

            controllerUid -> {
                withTimeout(DATABASE_TIMEOUT_MS) {
                    ref.child("state").setValue("CLOSED").await()
                }
            }

            else -> error("Not a session participant.")
        }

        val pairingHash = snapshot
            .child("pairingHash")
            .getValue(String::class.java)
        if (!pairingHash.isNullOrBlank()) {
            runCatching {
                database()
                    .getReference("pairingCodes")
                    .child(pairingHash)
                    .removeValue()
                    .await()
            }
        }
    }

    override fun observeSession(
        sessionId: String,
        listener: (BackendSession) -> Unit,
        onError: (Throwable) -> Unit
    ): Closeable {
        requireConfigured()
        val reference = sessionRef(sessionId)

        val valueListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                if (!snapshot.exists()) {
                    listener(
                        BackendSession(
                            sessionId = sessionId,
                            state = "CLOSED",
                            displayGeneration = 0
                        )
                    )
                    return
                }

                val state = snapshot.child("state")
                    .getValue(String::class.java) ?: return
                val generation = snapshot.child("displayGeneration")
                    .getValue(Long::class.java)?.toInt() ?: 0
                val deadlineAtEpochMs = when (state) {
                    "CODE_ACTIVE" ->
                        snapshot.child("expiresAtMs")
                            .getValue(Long::class.java)

                    "PAIR_PENDING" ->
                        snapshot.child("approvalExpiresAtMs")
                            .getValue(Long::class.java)
                            ?: snapshot.child("expiresAtMs")
                                .getValue(Long::class.java)

                    "HOST_APPROVED",
                    "SCREEN_READY",
                    "CONNECTING" ->
                        snapshot.child("connectExpiresAtMs")
                            .getValue(Long::class.java)

                    else -> null
                }

                listener(
                    BackendSession(
                        sessionId = sessionId,
                        state = state,
                        displayGeneration = generation,
                        deadlineAtEpochMs = deadlineAtEpochMs
                    )
                )
            }

            override fun onCancelled(error: DatabaseError) {
                onError(error.toException())
            }
        }

        reference.addValueEventListener(valueListener)
        return Closeable {
            reference.removeEventListener(valueListener)
        }
    }

    private suspend fun ensureSignedIn() {
        requireConfigured()
        val auth = auth()
        if (auth.currentUser == null) {
            withTimeout(AUTH_TIMEOUT_MS) {
                auth.signInAnonymously().await()
            }
        }
        checkNotNull(auth.currentUser) {
            "Firebase anonymous authentication failed"
        }
    }

    private fun requireHost(snapshot: DataSnapshot, uid: String) {
        check(snapshot.exists()) { "Session not found." }
        check(
            snapshot.child("hostUid").getValue(String::class.java) == uid
        ) {
            "Only the sharing phone can change this session."
        }
    }

    private fun sessionRef(sessionId: String) =
        database()
            .getReference("sessions")
            .child(sessionId)

    private fun hashCode(code: String): String {
        val digest = MessageDigest
            .getInstance("SHA-256")
            .digest(code.toByteArray(Charsets.UTF_8))
        return digest.joinToString("") {
            "%02x".format(it.toInt() and 0xff)
        }
    }

    private fun generateCode(): String = buildString(CODE_DIGITS) {
        repeat(CODE_DIGITS) {
            append(secureRandom.nextInt(10))
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

    private fun database(): FirebaseDatabase {
        requireConfigured()
        return FirebaseDatabase.getInstance()
    }

    companion object {
        private const val AUTH_TIMEOUT_MS = 12_000L
        private const val DATABASE_TIMEOUT_MS = 15_000L
        private const val CODE_TTL_MS = 5 * 60_000L
        private const val PAIR_APPROVAL_TTL_MS = 3 * 60_000L
        private const val CONNECT_SETUP_TTL_MS = 3 * 60_000L
        private const val CODE_DIGITS = 12
        private const val CODE_ALLOCATION_ATTEMPTS = 4
    }
}
