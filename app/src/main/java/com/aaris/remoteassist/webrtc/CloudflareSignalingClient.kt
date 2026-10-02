package com.aaris.remoteassist.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.backend.CloudflareBackend
import com.aaris.remoteassist.backend.CloudflareBackendException
import java.util.UUID
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong
import okhttp3.Response
import okhttp3.WebSocket
import okhttp3.WebSocketListener
import org.json.JSONObject

class CloudflareSignalingClient(
    context: Context,
    private val sessionId: String,
    private val role: PeerRole
) : SignalingClient {
    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val mainHandler = Handler(Looper.getMainLooper())
    private val writer = ScheduledThreadPoolExecutor(1).apply {
        removeOnCancelPolicy = true
    }
    private val reconnectAttempt = AtomicInteger(0)
    private val reconnectScheduled = AtomicBoolean(false)
    private val sequenceTracker = SignalingSequenceTracker()
    private val restartRequestSequence = AtomicLong(0L)
    private val descriptionDeliverySequence = AtomicLong(0L)
    private val firstLocalCandidatePublished = AtomicBoolean(false)
    private val firstRemoteCandidateReceived = AtomicBoolean(false)
    private val candidateGate =
        CandidatePublishGate<SignalCandidate>(128)
    private val remoteNegotiationGuard = NegotiationOrderGuard()

    @Volatile
    private var clientInstanceId = UUID.randomUUID().toString()
    @Volatile
    private var listener: SignalingClient.Listener? = null
    @Volatile
    private var socket: WebSocket? = null
    @Volatile
    private var lastLocalDescription: LocalDescriptionRecord? = null
    @Volatile
    private var lastAcceptedRemoteDescription: SignalDescription? = null

    private data class LocalDescriptionRecord(
        val description: SignalDescription,
        val negotiationEpoch: Long,
        val negotiationId: String
    )

    override fun start(listener: SignalingClient.Listener) {
        check(!closed.get()) { "Signaling client is closed" }
        check(this.listener == null) { "Signaling client already started" }
        this.listener = listener
        dispatchDiagnostic("Cloudflare signaling start requested")
        openSocket()
        setPresence(true)
    }

    override fun beginLocalDescription(): Long =
        if (closed.get()) -1L else candidateGate.beginNegotiation()

    override fun sendDescription(
        description: SignalDescription,
        negotiationEpoch: Long
    ) {
        if (
            closed.get() ||
            negotiationEpoch < 0L ||
            negotiationEpoch != candidateGate.currentEpoch()
        ) return
        val record = LocalDescriptionRecord(
            description,
            negotiationEpoch,
            negotiationIdFor(negotiationEpoch)
        )
        lastLocalDescription = record
        publishDescription(record, false, true, 1)
    }

    override fun retryLocalDescription(): Boolean {
        if (closed.get()) return false
        val record = lastLocalDescription ?: return false
        if (record.negotiationEpoch != candidateGate.currentEpoch()) {
            return false
        }
        publishDescription(record, true, false, 1)
        return true
    }

    override fun sendCandidate(candidate: SignalCandidate) {
        if (closed.get()) return
        val tagged = candidate.copy(
            negotiationId =
                negotiationIdFor(candidateGate.currentEpoch())
        )
        candidateGate.offer(tagged)?.let {
            publishCandidate(it, 1)
        }
    }

    override fun requestRemoteIceRestart() {
        if (closed.get() || role != PeerRole.CONTROLLER) return
        val id =
            "$clientInstanceId:" +
                restartRequestSequence.incrementAndGet()
        writer.execute {
            runCatching {
                postEvent(
                    "ice_restart",
                    JSONObject().put("requestId", id)
                )
            }
        }
    }

    override fun setPresence(online: Boolean) {
        if (closed.get()) return
        writer.execute {
            runCatching {
                postEvent(
                    "presence",
                    JSONObject().put("online", online)
                )
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        runCatching { socket?.close(1000, "closed") }
        socket = null
        writer.shutdownNow()
        mainHandler.removeCallbacksAndMessages(null)
        candidateGate.reset()
        sequenceTracker.reset()
        lastLocalDescription = null
        lastAcceptedRemoteDescription = null
        listener = null
    }

    private fun openSocket() {
        if (closed.get()) return
        val request = runCatching {
            CloudflareBackend.socketRequest(
                appContext,
                sessionId,
                sequenceTracker.reconnectAfter()
            )
        }.getOrElse {
            dispatchError(it)
            return
        }

        socket = CloudflareBackend.httpClient.newWebSocket(
            request,
            object : WebSocketListener() {
                override fun onOpen(
                    webSocket: WebSocket,
                    response: Response
                ) {
                    reconnectAttempt.set(0)
                    reconnectScheduled.set(false)
                    dispatchDiagnostic("Cloudflare WebSocket OPEN")
                }

                override fun onMessage(
                    webSocket: WebSocket,
                    text: String
                ) {
                    runCatching {
                        handleSocketMessage(text)
                    }.onFailure(::dispatchError)
                }

                override fun onClosed(
                    webSocket: WebSocket,
                    code: Int,
                    reason: String
                ) {
                    if (!closed.get()) scheduleReconnect()
                }

                override fun onFailure(
                    webSocket: WebSocket,
                    error: Throwable,
                    response: Response?
                ) {
                    if (closed.get()) return
                    dispatchDiagnostic(
                        "Cloudflare WebSocket FAILED" +
                            (response?.code?.let { " (HTTP $it)" } ?: "")
                    )
                    if (
                        response?.code == 401 ||
                        response?.code == 403
                    ) {
                        dispatchError(
                            CloudflareBackendException(
                                response.code,
                                "signaling_unauthorized",
                                "Session authorization expired."
                            )
                        )
                    } else {
                        scheduleReconnect()
                    }
                }
            }
        )
    }

    private fun scheduleReconnect() {
        if (
            closed.get() ||
            !reconnectScheduled.compareAndSet(false, true)
        ) return

        val exponent =
            (reconnectAttempt.incrementAndGet() - 1)
                .coerceIn(0, 4)
        val delayMs =
            (500L * (1L shl exponent))
                .coerceAtMost(5_000L)
        writer.schedule(
            {
                reconnectScheduled.set(false)
                if (!closed.get()) openSocket()
            },
            delayMs,
            TimeUnit.MILLISECONDS
        )
    }

    private fun handleSocketMessage(raw: String) {
        if (raw == "pong") return
        val root = JSONObject(raw)
        if (root.optString("kind") == "session") {
            if (
                root.optJSONObject("session")
                    ?.optString("state") == "CLOSED"
            ) {
                dispatch { listener?.onRemotePresence(false) }
            }
            return
        }
        if (root.optString("kind") != "signal_event") return

        val event = root.getJSONObject("event")
        val sequence = event.getLong("seq")
        if (!sequenceTracker.accept(sequence)) return

        /*
         * Cloudflare assigns a single monotonically increasing sequence to
         * events from both peers. HTTP event publications and WebSocket
         * broadcasts can complete out of order, so a higher event must never
         * cause a lower-but-unseen remote ICE candidate to be discarded.
         * The tracker processes every unique event while advancing the
         * reconnect cursor only across a contiguous prefix.
         */
        if (event.optString("senderRole") == roleWireName()) return

        val payload =
            event.optJSONObject("payload") ?: JSONObject()
        when (event.getString("kind")) {
            "description" ->
                handleRemoteDescription(payload)

            "candidate" -> {
                if (firstRemoteCandidateReceived.compareAndSet(false, true)) {
                    dispatchDiagnostic("First remote ICE candidate received")
                }
                val candidate = SignalCandidate(
                    sdpMid =
                        if (payload.isNull("mid")) null
                        else payload.getString("mid"),
                    sdpMLineIndex = payload.getInt("mLine"),
                    sdp = payload.getString("sdp"),
                    negotiationId = payload.optString(
                        "negotiationId",
                        LEGACY_NEGOTIATION_ID
                    )
                )
                dispatch {
                    listener?.onRemoteCandidate(candidate)
                }
            }

            "ice_restart" ->
                dispatch {
                    listener?.onRemoteIceRestartRequested()
                }

            "presence" ->
                dispatch {
                    listener?.onRemotePresence(
                        payload.optBoolean("online", false)
                    )
                }
        }
    }

    private fun handleRemoteDescription(payload: JSONObject) {
        val description = SignalDescription(
            type = payload.getString("type"),
            sdp = payload.getString("sdp"),
            negotiationId = payload.optString(
                "negotiationId",
                LEGACY_NEGOTIATION_ID
            ),
            replyToNegotiationId = payload
                .optString("replyToNegotiationId")
                .takeIf(String::isNotBlank)
        )
        val redelivery =
            payload.optBoolean("redelivery", false)

        if (
            role == PeerRole.HOST &&
            description.type.equals("answer", true)
        ) {
            val replyTo = description.replyToNegotiationId
            val currentOffer =
                lastLocalDescription?.negotiationId
            if (
                !replyTo.isNullOrBlank() &&
                currentOffer != null &&
                replyTo != currentOffer
            ) return
        }

        val duplicate =
            redelivery &&
                remoteNegotiationGuard.isCurrent(
                    description.negotiationId
                )
        val previous = lastAcceptedRemoteDescription
        if (
            duplicate &&
            previous != null &&
            (
                previous.negotiationId !=
                    description.negotiationId ||
                    previous.replyToNegotiationId !=
                        description.replyToNegotiationId ||
                    previous.type != description.type ||
                    previous.sdp != description.sdp
                )
        ) return

        if (
            !remoteNegotiationGuard.accept(
                description.negotiationId,
                allowCurrentDuplicate = redelivery
            )
        ) return

        lastAcceptedRemoteDescription = description
        dispatchDiagnostic(
            "Remote SDP " + description.type.uppercase() +
                " received from Cloudflare"
        )
        dispatch {
            if (duplicate) {
                listener?.onRemoteDescriptionRedelivery(
                    description
                )
            } else {
                listener?.onRemoteDescription(description)
            }
        }
    }

    private fun publishDescription(
        record: LocalDescriptionRecord,
        redelivery: Boolean,
        fatal: Boolean,
        attempt: Int
    ) {
        if (closed.get()) return
        writer.execute {
            if (
                closed.get() ||
                record.negotiationEpoch !=
                    candidateGate.currentEpoch() ||
                lastLocalDescription?.negotiationId !=
                    record.negotiationId
            ) return@execute

            val payload = JSONObject()
                .put("type", record.description.type)
                .put("sdp", record.description.sdp)
                .put("negotiationId", record.negotiationId)
            record.description.replyToNegotiationId
                ?.takeIf(String::isNotBlank)
                ?.let {
                    payload.put("replyToNegotiationId", it)
                }
            if (redelivery) {
                payload
                    .put("redelivery", true)
                    .put(
                        "deliveryAttempt",
                        descriptionDeliverySequence
                            .incrementAndGet()
                    )
            }

            runCatching {
                postEvent("description", payload)
            }.onSuccess {
                dispatchDiagnostic(
                    "Local SDP " + record.description.type.uppercase() +
                        " published to Cloudflare" +
                        if (redelivery) " (retry)" else ""
                )
                candidateGate
                    .markDescriptionPublished(
                        record.negotiationEpoch
                    )
                    .forEach { publishCandidate(it, 1) }
            }.onFailure { error ->
                if (attempt >= 7) {
                    if (fatal) dispatchError(error)
                    return@onFailure
                }
                val delayMs =
                    (250L * (1L shl (attempt - 1).coerceIn(0, 4)))
                        .coerceAtMost(4_000L)
                writer.schedule(
                    {
                        publishDescription(
                            record,
                            true,
                            fatal,
                            attempt + 1
                        )
                    },
                    delayMs,
                    TimeUnit.MILLISECONDS
                )
            }
        }
    }

    private fun publishCandidate(
        candidate: SignalCandidate,
        attempt: Int
    ) {
        if (closed.get()) return
        writer.execute {
            if (
                closed.get() ||
                candidate.negotiationId !=
                    negotiationIdFor(
                        candidateGate.currentEpoch()
                    )
            ) return@execute

            val payload = JSONObject()
                .put("mid", candidate.sdpMid)
                .put("mLine", candidate.sdpMLineIndex)
                .put("sdp", candidate.sdp)
                .put(
                    "negotiationId",
                    candidate.negotiationId
                )
            runCatching {
                postEvent("candidate", payload)
            }.onSuccess {
                if (firstLocalCandidatePublished.compareAndSet(false, true)) {
                    dispatchDiagnostic("First local ICE candidate published")
                }
            }.onFailure {
                if (attempt >= 4) return@onFailure
                val delayMs =
                    (200L * (1L shl (attempt - 1).coerceIn(0, 3)))
                        .coerceAtMost(1_500L)
                writer.schedule(
                    {
                        publishCandidate(
                            candidate,
                            attempt + 1
                        )
                    },
                    delayMs,
                    TimeUnit.MILLISECONDS
                )
            }
        }
    }

    private fun postEvent(kind: String, payload: JSONObject) {
        CloudflareBackend.sessionRequest(
            appContext,
            sessionId,
            "POST",
            "events",
            JSONObject()
                .put("kind", kind)
                .put("payload", payload)
        )
    }

    private fun dispatch(block: () -> Unit) {
        if (!closed.get()) {
            mainHandler.post {
                if (!closed.get()) block()
            }
        }
    }

    private fun dispatchDiagnostic(message: String) {
        dispatch { listener?.onSignalingDiagnostic(message) }
    }

    private fun dispatchError(error: Throwable) {
        dispatch { listener?.onError(error) }
    }

    private fun negotiationIdFor(epoch: Long): String =
        if (epoch <= 0L) LEGACY_NEGOTIATION_ID
        else "$clientInstanceId:$epoch"

    private fun roleWireName(): String =
        if (role == PeerRole.HOST) "host" else "controller"
}
