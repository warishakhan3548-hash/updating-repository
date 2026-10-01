package com.aaris.remoteassist.webrtc

import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.backend.FirebaseBackend
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.ChildEventListener
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.json.JSONObject

class FirebaseSignalingClient(
    private val sessionId: String,
    private val role: PeerRole,
    private val database: FirebaseDatabase = FirebaseBackend.database(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
) : SignalingClient {
    private val closed = AtomicBoolean(false)
    private val candidateSequence = AtomicLong(0L)
    private val restartRequestSequence = AtomicLong(0L)
    private val descriptionDeliverySequence = AtomicLong(0L)
    private val descriptionRetryHandler =
        Handler(Looper.getMainLooper())
    private val candidateRetryHandler =
        Handler(Looper.getMainLooper())
    private val candidateWriteToken = AtomicLong(0L)
    private val candidateSlotOwners =
        ConcurrentHashMap<String, Long>()
    @Volatile
    private var clientInstanceId =
        java.util.UUID.randomUUID().toString()
    private val candidateGate =
        CandidatePublishGate<SignalCandidate>(MAX_CANDIDATE_SLOTS)
    private val remoteNegotiationGuard =
        NegotiationOrderGuard()
    private val root = database.getReference("sessions").child(sessionId)

    private data class LocalDescriptionRecord(
        val description: SignalDescription,
        val negotiationEpoch: Long,
        val negotiationId: String
    )

    @Volatile
    private var lastLocalDescription: LocalDescriptionRecord? = null

    private val localSignal: DatabaseReference
        get() = root.child(
            if (role == PeerRole.HOST) "hostSignal" else "controllerSignal"
        )

    private val remoteSignal: DatabaseReference
        get() = root.child(
            if (role == PeerRole.HOST) "controllerSignal" else "hostSignal"
        )

    private val localCandidates: DatabaseReference
        get() = root.child(
            if (role == PeerRole.HOST) "hostCandidates" else "controllerCandidates"
        )

    private val remoteCandidates: DatabaseReference
        get() = root.child(
            if (role == PeerRole.HOST) "controllerCandidates" else "hostCandidates"
        )

    private var listener: SignalingClient.Listener? = null
    private var descriptionListener: ValueEventListener? = null
    private var candidateListener: ChildEventListener? = null
    private var presenceListener: ValueEventListener? = null
    private var remotePresenceReference: DatabaseReference? = null
    private var remotePresenceListener: ValueEventListener? = null
    private var lastRemoteSignal: String? = null
    private var lastAcceptedRemoteDescription: SignalDescription? = null

    override fun start(listener: SignalingClient.Listener) {
        check(!closed.get()) { "Signaling client is closed" }
        check(this.listener == null) { "Signaling client already started" }
        this.listener = listener

        val descriptionListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val raw = snapshot.getValue(String::class.java) ?: return
                if (raw == lastRemoteSignal) return

                runCatching {
                    val json = JSONObject(raw)
                    if (
                        json.optString("kind") ==
                        ICE_RESTART_REQUEST_KIND
                    ) {
                        Pair<SignalDescription?, Boolean>(
                            null,
                            false
                        )
                    } else {
                        Pair(
                            SignalDescription(
                                type = json.getString("type"),
                                sdp = json.getString("sdp"),
                                negotiationId = json.optString(
                                    "negotiationId",
                                    LEGACY_NEGOTIATION_ID
                                ),
                                replyToNegotiationId = json
                                    .optString(
                                        "replyToNegotiationId"
                                    )
                                    .takeIf {
                                        it.isNotBlank()
                                    }
                            ),
                            json.optBoolean(
                                "redelivery",
                                false
                            )
                        )
                    }
                }.onSuccess { (description, redelivery) ->
                    if (description == null) {
                        lastRemoteSignal = raw
                        listener.onRemoteIceRestartRequested()
                        return@onSuccess
                    }

                    val duplicateCurrent =
                        redelivery &&
                            remoteNegotiationGuard.isCurrent(
                                description.negotiationId
                            )
                    val previous =
                        lastAcceptedRemoteDescription

                    if (
                        duplicateCurrent &&
                        previous != null &&
                        (
                            previous.negotiationId !=
                                description.negotiationId ||
                                previous.replyToNegotiationId !=
                                    description.replyToNegotiationId ||
                                previous.type != description.type ||
                                previous.sdp != description.sdp
                            )
                    ) {
                        // A retry is allowed to change only its delivery
                        // marker. Same negotiation ID with different SDP is
                        // not idempotent and must fail closed.
                        return@onSuccess
                    }

                    if (
                        role == PeerRole.HOST &&
                        description.type.equals(
                            "answer",
                            ignoreCase = true
                        )
                    ) {
                        val replyTo =
                            description.replyToNegotiationId
                        val currentOfferId =
                            lastLocalDescription?.negotiationId

                        /*
                         * New clients bind every answer to the exact host
                         * offer they answered. A late answer from an older
                         * generation must never be applied to a newer
                         * HAVE_LOCAL_OFFER state. Null stays accepted only for
                         * backward compatibility with pre-1.7.22 peers.
                         */
                        if (
                            !replyTo.isNullOrBlank() &&
                            currentOfferId != null &&
                            replyTo != currentOfferId
                        ) {
                            lastRemoteSignal = raw
                            return@onSuccess
                        }
                    }

                    if (
                        remoteNegotiationGuard.accept(
                            negotiationId =
                                description.negotiationId,
                            allowCurrentDuplicate =
                                redelivery
                        )
                    ) {
                        lastAcceptedRemoteDescription =
                            description
                        lastRemoteSignal = raw

                        if (duplicateCurrent) {
                            listener
                                .onRemoteDescriptionRedelivery(
                                    description
                                )
                        } else {
                            listener.onRemoteDescription(
                                description
                            )
                        }
                    }
                }.onFailure(listener::onError)
            }

            override fun onCancelled(error: DatabaseError) {
                listener.onError(error.toException())
            }
        }
        this.descriptionListener = descriptionListener
        remoteSignal.addValueEventListener(descriptionListener)

        val candidateListener = object : ChildEventListener {
            override fun onChildAdded(
                snapshot: DataSnapshot,
                previousChildName: String?
            ) {
                dispatchRemoteCandidate(snapshot, listener)
            }

            override fun onChildChanged(
                snapshot: DataSnapshot,
                previousChildName: String?
            ) {
                dispatchRemoteCandidate(snapshot, listener)
            }

            override fun onChildRemoved(snapshot: DataSnapshot) = Unit
            override fun onChildMoved(
                snapshot: DataSnapshot,
                previousChildName: String?
            ) = Unit

            override fun onCancelled(error: DatabaseError) {
                listener.onError(error.toException())
            }
        }
        this.candidateListener = candidateListener
        remoteCandidates.addChildEventListener(candidateListener)

        val uid = auth.currentUser?.uid
        if (uid != null) {
            val remoteUidField =
                if (role == PeerRole.HOST) "controllerUid" else "hostUid"

            val presenceListener = object : ValueEventListener {
                override fun onDataChange(snapshot: DataSnapshot) {
                    val previousRef = remotePresenceReference
                    val previousListener = remotePresenceListener
                    if (previousRef != null && previousListener != null) {
                        previousRef.removeEventListener(previousListener)
                    }
                    remotePresenceReference = null
                    remotePresenceListener = null

                    val remoteUid = snapshot.getValue(String::class.java)
                    if (remoteUid.isNullOrBlank()) {
                        listener.onRemotePresence(false)
                        return
                    }

                    val remoteRef = root.child("presence").child(remoteUid)
                    val remoteListener = object : ValueEventListener {
                        override fun onDataChange(presence: DataSnapshot) {
                            listener.onRemotePresence(
                                presence.getValue(Boolean::class.java) == true
                            )
                        }

                        override fun onCancelled(error: DatabaseError) {
                            // Presence is advisory. Signaling/media may remain
                            // healthy even when this observer is unavailable.
                        }
                    }

                    remotePresenceReference = remoteRef
                    remotePresenceListener = remoteListener
                    remoteRef.addValueEventListener(remoteListener)
                }

                override fun onCancelled(error: DatabaseError) {
                    // Participant lookup is advisory presence telemetry only.
                }
            }
            this.presenceListener = presenceListener
            root.child(remoteUidField).addValueEventListener(presenceListener)
        }

        setPresence(true)
    }

    override fun beginLocalDescription(): Long {
        if (closed.get()) return -1L
        return candidateGate.beginNegotiation()
    }

    override fun sendDescription(
        description: SignalDescription,
        negotiationEpoch: Long
    ) {
        if (
            closed.get() ||
            negotiationEpoch < 0L ||
            negotiationEpoch != candidateGate.currentEpoch()
        ) {
            return
        }

        val record = LocalDescriptionRecord(
            description = description,
            negotiationEpoch = negotiationEpoch,
            negotiationId =
                negotiationIdFor(negotiationEpoch)
        )
        lastLocalDescription = record

        publishLocalDescription(
            record = record,
            redelivery = false,
            failSessionOnError = true
        )
    }

    override fun retryLocalDescription(): Boolean {
        if (closed.get()) return false

        val record = lastLocalDescription ?: return false
        if (
            record.negotiationEpoch !=
            candidateGate.currentEpoch()
        ) {
            return false
        }

        publishLocalDescription(
            record = record,
            redelivery = true,
            failSessionOnError = false
        )
        return true
    }

    override fun sendCandidate(candidate: SignalCandidate) {
        if (closed.get()) return

        val tagged = candidate.copy(
            negotiationId = negotiationIdFor(
                candidateGate.currentEpoch()
            )
        )
        candidateGate.offer(tagged)
            ?.let(::publishCandidate)
    }

    override fun requestRemoteIceRestart() {
        if (closed.get() || role != PeerRole.CONTROLLER) return

        /*
         * A restart request is control-plane signaling, not an SDP answer.
         * Re-publishing an old answer can race a newly-created host offer and
         * make that stale answer look like the answer for the new ICE
         * generation. Use an explicit envelope instead so offer/answer state
         * remains strictly owned by WebRTC.
         */
        val requestId =
            "$clientInstanceId:" +
                restartRequestSequence.incrementAndGet()
        val payload = JSONObject()
            .put("kind", ICE_RESTART_REQUEST_KIND)
            .put("requestId", requestId)
            .toString()

        // Advisory only: Firebase can queue this write across the exact
        // Wi-Fi/mobile handoff. If an offer is already in flight, the host
        // simply ignores this request and that offer remains authoritative.
        localSignal.setValue(payload)
    }

    override fun setPresence(online: Boolean) {
        if (closed.get()) return
        val uid = auth.currentUser?.uid ?: return
        val ref = root.child("presence").child(uid)

        if (online) {
            ref.onDisconnect().setValue(false)
            ref.setValue(true)
        } else {
            ref.setValue(false)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        val descriptionListener = descriptionListener
        if (descriptionListener != null) {
            remoteSignal.removeEventListener(descriptionListener)
        }

        val candidateListener = candidateListener
        if (candidateListener != null) {
            remoteCandidates.removeEventListener(candidateListener)
        }

        val presenceListener = presenceListener
        if (presenceListener != null) {
            val remoteUidField =
                if (role == PeerRole.HOST) "controllerUid" else "hostUid"
            root.child(remoteUidField).removeEventListener(presenceListener)
        }

        descriptionRetryHandler.removeCallbacksAndMessages(null)
        candidateRetryHandler.removeCallbacksAndMessages(null)
        candidateSlotOwners.clear()

        val remoteRef = remotePresenceReference
        val remoteListener = remotePresenceListener
        if (remoteRef != null && remoteListener != null) {
            remoteRef.removeEventListener(remoteListener)
        }

        remotePresenceReference = null
        remotePresenceListener = null
        lastAcceptedRemoteDescription = null
        lastLocalDescription = null
        candidateGate.reset()

        val uid = auth.currentUser?.uid
        if (uid != null) {
            root.child("presence").child(uid).setValue(false)
        }

        listener = null
        this.descriptionListener = null
        this.candidateListener = null
        this.presenceListener = null
    }

    private fun publishLocalDescription(
        record: LocalDescriptionRecord,
        redelivery: Boolean,
        failSessionOnError: Boolean,
        attempt: Int = 1
    ) {
        if (closed.get()) return

        val payloadBuilder = JSONObject()
            .put("type", record.description.type)
            .put("sdp", record.description.sdp)
            .put("negotiationId", record.negotiationId)

        record.description.replyToNegotiationId
            ?.takeIf { it.isNotBlank() }
            ?.let {
                payloadBuilder.put(
                    "replyToNegotiationId",
                    it
                )
            }

        if (redelivery) {
            payloadBuilder
                .put("redelivery", true)
                .put(
                    "deliveryAttempt",
                    descriptionDeliverySequence
                        .incrementAndGet()
                )
        }

        val task = localSignal.setValue(
            payloadBuilder.toString()
        )
        task.addOnSuccessListener {
            if (closed.get()) {
                return@addOnSuccessListener
            }

            // A successful redelivery is also sufficient proof that the
            // description reached RTDB. Open the candidate gate if the
            // original write was still pending or was transiently lost.
            candidateGate
                .markDescriptionPublished(
                    record.negotiationEpoch
                )
                .forEach(::publishCandidate)
        }

        if (failSessionOnError) {
            task.addOnFailureListener { error ->
                if (closed.get()) {
                    return@addOnFailureListener
                }

                val stillAuthoritative =
                    record.negotiationEpoch ==
                        candidateGate.currentEpoch() &&
                        lastLocalDescription
                            ?.negotiationId ==
                            record.negotiationId

                if (!stillAuthoritative) {
                    return@addOnFailureListener
                }

                if (
                    attempt >=
                    MAX_DESCRIPTION_WRITE_ATTEMPTS
                ) {
                    listener?.onError(error)
                    return@addOnFailureListener
                }

                val exponent =
                    (attempt - 1).coerceIn(0, 3)
                val backoffMs =
                    (
                        DESCRIPTION_WRITE_RETRY_BASE_MS *
                            (1L shl exponent)
                    ).coerceAtMost(
                        DESCRIPTION_WRITE_RETRY_MAX_MS
                    )

                /*
                 * Firebase write completion can be ambiguous across a short
                 * network handoff: the server may have committed the SDP even
                 * when the client sees a failure. Retry the exact same
                 * generation and mark it as redelivery so the receiver treats
                 * it idempotently instead of creating a second negotiation.
                 */
                descriptionRetryHandler.postDelayed(
                    {
                        if (
                            !closed.get() &&
                            record.negotiationEpoch ==
                                candidateGate.currentEpoch() &&
                            lastLocalDescription
                                ?.negotiationId ==
                                record.negotiationId
                        ) {
                            publishLocalDescription(
                                record = record,
                                redelivery = true,
                                failSessionOnError = true,
                                attempt = attempt + 1
                            )
                        }
                    },
                    backoffMs
                )
            }
        }
    }

    private fun publishCandidate(
        candidate: SignalCandidate
    ) {
        if (closed.get()) return

        val sequence = candidateSequence.getAndIncrement()
        val slot = Math.floorMod(
            sequence,
            MAX_CANDIDATE_SLOTS.toLong()
        ).toString().padStart(CANDIDATE_SLOT_WIDTH, '0')
        val writeToken = candidateWriteToken.incrementAndGet()

        /*
         * A slot can be reused after the bounded ring wraps. Bind retries to
         * the exact slot owner so a delayed failure callback from an older
         * candidate can never overwrite a newer candidate in that slot.
         */
        candidateSlotOwners[slot] = writeToken

        publishCandidateAttempt(
            candidate = candidate,
            slot = slot,
            writeToken = writeToken,
            attempt = 1
        )
    }

    private fun publishCandidateAttempt(
        candidate: SignalCandidate,
        slot: String,
        writeToken: Long,
        attempt: Int
    ) {
        if (
            closed.get() ||
            candidateSlotOwners[slot] != writeToken ||
            candidate.negotiationId !=
                negotiationIdFor(candidateGate.currentEpoch())
        ) {
            return
        }

        val payload = JSONObject()
            .put("mid", candidate.sdpMid)
            .put("mLine", candidate.sdpMLineIndex)
            .put("sdp", candidate.sdp)
            .put("negotiationId", candidate.negotiationId)
            .toString()

        val task = localCandidates.child(slot).setValue(payload)

        task.addOnSuccessListener {
            candidateSlotOwners.remove(slot, writeToken)
        }

        task.addOnFailureListener {
            if (
                closed.get() ||
                candidateSlotOwners[slot] != writeToken ||
                candidate.negotiationId !=
                    negotiationIdFor(candidateGate.currentEpoch())
            ) {
                return@addOnFailureListener
            }

            if (attempt >= MAX_CANDIDATE_WRITE_ATTEMPTS) {
                /*
                 * Candidate loss is not session-fatal. A different candidate
                 * or the bounded host ICE-restart path can still establish a
                 * route. Drop only this candidate after its retry budget.
                 */
                candidateSlotOwners.remove(slot, writeToken)
                return@addOnFailureListener
            }

            val exponent = (attempt - 1).coerceIn(0, 3)
            val backoffMs =
                (
                    CANDIDATE_WRITE_RETRY_BASE_MS *
                        (1L shl exponent)
                ).coerceAtMost(CANDIDATE_WRITE_RETRY_MAX_MS)

            candidateRetryHandler.postDelayed(
                {
                    publishCandidateAttempt(
                        candidate = candidate,
                        slot = slot,
                        writeToken = writeToken,
                        attempt = attempt + 1
                    )
                },
                backoffMs
            )
        }
    }

    private fun dispatchRemoteCandidate(
        snapshot: DataSnapshot,
        listener: SignalingClient.Listener
    ) {
        val raw = snapshot.getValue(String::class.java) ?: return
        runCatching {
            val json = JSONObject(raw)
            SignalCandidate(
                sdpMid = if (json.isNull("mid")) {
                    null
                } else {
                    json.getString("mid")
                },
                sdpMLineIndex = json.getInt("mLine"),
                sdp = json.getString("sdp"),
                negotiationId = json.optString(
                    "negotiationId",
                    LEGACY_NEGOTIATION_ID
                )
            )
        }.onSuccess(listener::onRemoteCandidate)
            .onFailure(listener::onError)
    }

    private fun negotiationIdFor(epoch: Long): String {
        return if (epoch <= 0L) {
            LEGACY_NEGOTIATION_ID
        } else {
            "$clientInstanceId:$epoch"
        }
    }


    companion object {
        private const val ICE_RESTART_REQUEST_KIND =
            "ice_restart_request"
        private const val MAX_CANDIDATE_SLOTS = 96
        private const val CANDIDATE_SLOT_WIDTH = 3
        private const val MAX_DESCRIPTION_WRITE_ATTEMPTS = 7
        private const val DESCRIPTION_WRITE_RETRY_BASE_MS = 250L
        private const val DESCRIPTION_WRITE_RETRY_MAX_MS = 4_000L
        private const val MAX_CANDIDATE_WRITE_ATTEMPTS = 4
        private const val CANDIDATE_WRITE_RETRY_BASE_MS = 200L
        private const val CANDIDATE_WRITE_RETRY_MAX_MS = 1_500L
    }
}
