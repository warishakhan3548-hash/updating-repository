package com.aaris.remoteassist.pairing

import android.content.Context
import com.google.firebase.FirebaseApp
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.MutableData
import com.google.firebase.database.Transaction
import com.google.firebase.database.ValueEventListener
import java.io.Closeable
import java.security.MessageDigest
import java.security.SecureRandom
import java.util.UUID
import kotlinx.coroutines.CompletableDeferred
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

        repeat(CODE_ALLOCATION_ATTEMPTS) { attempt ->
            val code = generateCode()
            val codeHash = hashCode(code)
            val sessionId = UUID.randomUUID().toString()
            val now = System.currentTimeMillis()
            val expiresAtMs = now + CODE_TTL_MS

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

            val updates = mapOf<String, Any?>(
                "pairingCodes/$codeHash" to codeRecord,
                "sessions/$sessionId" to session
            )

            try {
                withTimeout(DATABASE_TIMEOUT_MS) {
                    database.reference
                        .updateChildren(updates)
                        .await()
                }

                return ShareTicket(
                    sessionId = sessionId,
                    code = code,
                    expiresAtEpochMs = expiresAtMs
                )
            } catch (error: Throwable) {
                if (attempt == CODE_ALLOCATION_ATTEMPTS - 1) {
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
        val codeRef = database
            .getReference("pairingCodes")
            .child(codeHash)

        val codeSnapshot = withTimeout(DATABASE_TIMEOUT_MS) {
            codeRef.get().await()
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

        val now = System.currentTimeMillis()
        val sessionRef = database
            .getReference("sessions")
            .child(sessionId)

        runTransaction(
            reference = sessionRef,
            abortMessage = "That code is already being used or expired."
        ) { current ->
            val state = current.child("state").value as? String
            val currentHostUid =
                current.child("hostUid").value as? String
            val currentController =
                current.child("controllerUid").value
            val currentExpiry =
                (current.child("expiresAtMs").value as? Number)
                    ?.toLong()
                    ?: 0L

            if (
                current.value == null ||
                state != "CODE_ACTIVE" ||
                currentHostUid != hostUid ||
                currentController != null ||
                currentExpiry <= now
            ) {
                return@runTransaction false
            }

            current.child("controllerUid").value = uid
            current.child("state").value = "PAIR_PENDING"
            current.child("pairedAtMs").value = now
            current.child("approvalExpiresAtMs").value =
                now + PAIR_APPROVAL_TTL_MS
            true
        }

        runCatching {
            withTimeout(DATABASE_TIMEOUT_MS) {
                codeRef.removeValue().await()
            }
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
        val now = System.currentTimeMillis()

        runTransaction(
            reference = sessionRef(sessionId),
            abortMessage = "No valid connection request."
        ) { current ->
            val hostUid = current.child("hostUid").value as? String
            val state = current.child("state").value as? String
            val approvalDeadline =
                (current.child("approvalExpiresAtMs").value as? Number)
                    ?.toLong()
                    ?: 0L

            if (
                hostUid != uid ||
                state != "PAIR_PENDING" ||
                approvalDeadline <= now
            ) {
                return@runTransaction false
            }

            current.child("state").value = "HOST_APPROVED"
            current.child("approvedAtMs").value = now
            current.child("connectExpiresAtMs").value =
                now + CONNECT_SETUP_TTL_MS
            true
        }
    }

    override suspend fun markScreenReady(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val now = System.currentTimeMillis()

        val snapshot = runTransaction(
            reference = sessionRef(sessionId),
            abortMessage = "Session was not approved or setup expired."
        ) { current ->
            val hostUid = current.child("hostUid").value as? String
            val state = current.child("state").value as? String
            val connectDeadline =
                (current.child("connectExpiresAtMs").value as? Number)
                    ?.toLong()
                    ?: 0L

            if (
                hostUid != uid ||
                state != "HOST_APPROVED" ||
                connectDeadline <= now
            ) {
                return@runTransaction false
            }

            current.child("state").value = "SCREEN_READY"
            current.child("screenReadyAtMs").value = now
            true
        }

        val pairingHash = snapshot
            .child("pairingHash")
            .getValue(String::class.java)

        if (!pairingHash.isNullOrBlank()) {
            runCatching {
                withTimeout(DATABASE_TIMEOUT_MS) {
                    database()
                        .getReference("pairingCodes")
                        .child(pairingHash)
                        .removeValue()
                        .await()
                }
            }
        }
    }

    override suspend fun markLive(sessionId: String) {
        ensureSignedIn()
        val uid = requireNotNull(auth().currentUser?.uid)
        val now = System.currentTimeMillis()

        runTransaction(
            reference = sessionRef(sessionId),
            abortMessage = "Session is not ready for live transport."
        ) { current ->
            val hostUid = current.child("hostUid").value as? String
            val state = current.child("state").value as? String
            val connectDeadline =
                (current.child("connectExpiresAtMs").value as? Number)
                    ?.toLong()
                    ?: 0L

            if (
                hostUid != uid ||
                state != "SCREEN_READY" ||
                connectDeadline <= now
            ) {
                return@runTransaction false
            }

            current.child("state").value = "LIVE"
            current.child("liveAtMs").value = now
            true
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

    private suspend fun runTransaction(
        reference: DatabaseReference,
        abortMessage: String,
        mutation: (MutableData) -> Boolean
    ): DataSnapshot {
        val result = CompletableDeferred<DataSnapshot>()

        reference.runTransaction(
            object : Transaction.Handler {
                override fun doTransaction(
                    currentData: MutableData
                ): Transaction.Result {
                    return if (mutation(currentData)) {
                        Transaction.success(currentData)
                    } else {
                        Transaction.abort()
                    }
                }

                override fun onComplete(
                    error: DatabaseError?,
                    committed: Boolean,
                    currentData: DataSnapshot?
                ) {
                    when {
                        error != null ->
                            result.completeExceptionally(
                                error.toException()
                            )

                        !committed || currentData == null ->
                            result.completeExceptionally(
                                IllegalStateException(abortMessage)
                            )

                        else ->
                            result.complete(currentData)
                    }
                }
            },
            false
        )

        return withTimeout(DATABASE_TIMEOUT_MS) {
            result.await()
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
