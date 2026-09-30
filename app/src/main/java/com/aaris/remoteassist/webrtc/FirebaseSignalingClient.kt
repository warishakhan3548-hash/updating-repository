package com.aaris.remoteassist.webrtc

import com.google.firebase.auth.FirebaseAuth
import com.google.firebase.database.ChildEventListener
import com.google.firebase.database.DataSnapshot
import com.google.firebase.database.DatabaseError
import com.google.firebase.database.DatabaseReference
import com.google.firebase.database.FirebaseDatabase
import com.google.firebase.database.ValueEventListener
import org.json.JSONObject
import java.util.concurrent.atomic.AtomicBoolean

class FirebaseSignalingClient(
    private val sessionId: String,
    private val role: PeerRole,
    private val database: FirebaseDatabase = FirebaseDatabase.getInstance(),
    private val auth: FirebaseAuth = FirebaseAuth.getInstance()
) : SignalingClient {
    private val closed = AtomicBoolean(false)
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
                val raw = snapshot.getValue(String::class.java) ?: return
                runCatching {
                    val json = JSONObject(raw)
                    SignalCandidate(
                        sdpMid = if (json.isNull("mid")) null else json.getString("mid"),
                        sdpMLineIndex = json.getInt("mLine"),
                        sdp = json.getString("sdp")
                    )
                }.onSuccess(listener::onRemoteCandidate)
                    .onFailure(listener::onError)
            }

            override fun onChildChanged(
                snapshot: DataSnapshot,
                previousChildName: String?
            ) = Unit

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
                    val remoteUid = snapshot.getValue(String::class.java)
                    if (remoteUid.isNullOrBlank()) {
                        listener.onRemotePresence(false)
                        return
                    }

                    root.child("presence")
                        .child(remoteUid)
                        .get()
                        .addOnSuccessListener { presence ->
                            listener.onRemotePresence(
                                presence.getValue(Boolean::class.java) == true
                            )
                        }
                        .addOnFailureListener(listener::onError)
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

    override fun sendDescription(description: SignalDescription) {
        if (closed.get()) return
        val payload = JSONObject()
            .put("type", description.type)
            .put("sdp", description.sdp)
            .toString()

        localSignal.setValue(payload)
            .addOnFailureListener { listener?.onError(it) }
    }

    override fun sendCandidate(candidate: SignalCandidate) {
        if (closed.get()) return
        val payload = JSONObject()
            .put("mid", candidate.sdpMid)
            .put("mLine", candidate.sdpMLineIndex)
            .put("sdp", candidate.sdp)
            .toString()

        localCandidates.push()
            .setValue(payload)
            .addOnFailureListener { listener?.onError(it) }
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

        val uid = auth.currentUser?.uid
        if (uid != null) {
            root.child("presence").child(uid).setValue(false)
        }

        listener = null
        this.descriptionListener = null
        this.candidateListener = null
        this.presenceListener = null
    }
}
