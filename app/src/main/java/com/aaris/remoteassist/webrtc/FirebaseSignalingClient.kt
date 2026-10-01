package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.backend.FirebaseBackend
import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.ChildEventListener
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
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
    private val candidateGate =
        CandidatePublishGate<SignalCandidate>(MAX_CANDIDATE_SLOTS)
    private val root = database.getReference("sessions").child(sessionId)

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
    private var lastRemoteDescription: String? = null

    override fun start(listener: SignalingClient.Listener) {
        check(!closed.get()) { "Signaling client is closed" }
        check(this.listener == null) { "Signaling client already started" }
        this.listener = listener

        val descriptionListener = object : ValueEventListener {
            override fun onDataChange(snapshot: DataSnapshot) {
                val raw = snapshot.getValue(String::class.java) ?: return
                if (raw == lastRemoteDescription) return
                lastRemoteDescription = raw

                runCatching {
                    val json = JSONObject(raw)
                    SignalDescription(
                        type = json.getString("type"),
                        sdp = json.getString("sdp")
                    )
                }.onSuccess(listener::onRemoteDescription)
                    .onFailure(listener::onError)
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
                            listener.onError(error.toException())
                        }
                    }

                    remotePresenceReference = remoteRef
                    remotePresenceListener = remoteListener
                    remoteRef.addValueEventListener(remoteListener)
                }

                override fun onCancelled(error: DatabaseError) {
                    listener.onError(error.toException())
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
        if (closed.get() || negotiationEpoch < 0L) return
        val payload = JSONObject()
            .put("type", description.type)
            .put("sdp", description.sdp)
            .toString()

        localSignal.setValue(payload)
            .addOnSuccessListener {
                if (closed.get()) {
                    return@addOnSuccessListener
                }

                candidateGate
                    .markDescriptionPublished(negotiationEpoch)
                    .forEach(::publishCandidate)
            }
            .addOnFailureListener { listener?.onError(it) }
    }

    override fun sendCandidate(candidate: SignalCandidate) {
        if (closed.get()) return

        candidateGate.offer(candidate)
            ?.let(::publishCandidate)
    }

    override fun setPresence(online: Boolean) {
        if (closed.get()) return
        val uid = auth.currentUser?.uid ?: return
        val ref = root.child("presence").child(uid)

        if (online) {
            ref.onDisconnect().setValue(false)
            ref.setValue(true)
                .addOnFailureListener { listener?.onError(it) }
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

        val remoteRef = remotePresenceReference
        val remoteListener = remotePresenceListener
        if (remoteRef != null && remoteListener != null) {
            remoteRef.removeEventListener(remoteListener)
        }
        remotePresenceReference = null
        remotePresenceListener = null
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

    private fun publishCandidate(
        candidate: SignalCandidate
    ) {
        if (closed.get()) return

        val payload = JSONObject()
            .put("mid", candidate.sdpMid)
            .put("mLine", candidate.sdpMLineIndex)
            .put("sdp", candidate.sdp)
            .toString()

        val sequence = candidateSequence.getAndIncrement()
        val slot = Math.floorMod(
            sequence,
            MAX_CANDIDATE_SLOTS.toLong()
        ).toString().padStart(CANDIDATE_SLOT_WIDTH, '0')

        localCandidates.child(slot)
            .setValue(payload)
            .addOnFailureListener { listener?.onError(it) }
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
                sdp = json.getString("sdp")
            )
        }.onSuccess(listener::onRemoteCandidate)
            .onFailure(listener::onError)
    }

    companion object {
        private const val MAX_CANDIDATE_SLOTS = 96
        private const val CANDIDATE_SLOT_WIDTH = 3
    }
}
