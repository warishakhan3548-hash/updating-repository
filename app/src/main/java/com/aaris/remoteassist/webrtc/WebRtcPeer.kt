package com.aaris.remoteassist.webrtc

import android.content.Context
import android.os.Handler
import android.os.Looper
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.PeerConnection
import org.webrtc.RtpReceiver
import org.webrtc.RtpTransceiver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.ArrayDeque
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class WebRtcPeer(
    context: Context,
    private val role: PeerRole,
    private val signaling: SignalingClient,
    private val listener: Listener
) : SignalingClient.Listener, PeerConnection.Observer {
    interface Listener {
        fun onPeerConnected()
        fun onPeerDisconnected()
        fun onControlChannelOpen()
        fun onControlMessage(bytes: ByteArray)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val factory = WebRtcRuntime.factory(appContext)
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val pendingRemoteCandidates = ArrayDeque<IceCandidate>()

    @Volatile
    private var remoteDescriptionReady = false

    @Volatile
    private var controlChannel: DataChannel? = null

    private val peerConnection: PeerConnection = checkNotNull(
        factory.createPeerConnection(
            createRtcConfiguration(IceServerProvider.fallbackServers()),
            this
        )
    ) {
        "Could not create WebRTC peer connection"
    }

    fun start() {
        check(!closed.get()) { "WebRTC peer is closed" }
        check(started.compareAndSet(false, true)) {
            "WebRTC peer already started"
        }

        scope.launch {
            val iceServers = IceServerProvider.load()
            handler.post {
                if (closed.get()) return@post

                runCatching {
                    peerConnection.setConfiguration(
                        createRtcConfiguration(iceServers)
                    )
                    startSignaling()
                }.onFailure(listener::onError)
            }
        }
    }

    private fun startSignaling() {
        if (closed.get()) return
        signaling.start(this)

        if (role == PeerRole.HOST) {
            bindControlChannel(
                peerConnection.createDataChannel(
                    CONTROL_CHANNEL,
                    DataChannel.Init().apply {
                        ordered = true
                    }
                )
            )
            createOffer()
        }
    }

    fun addLocalVideoTrack(track: VideoTrack) {
        check(!closed.get())
        peerConnection.addTrack(track, listOf(SCREEN_STREAM_ID))
    }

    fun requestIceRestart(): Boolean {
        if (closed.get() || role != PeerRole.HOST) return false

        return runCatching {
            remoteDescriptionReady = false
            peerConnection.restartIce()
            createOffer()
            true
        }.getOrElse {
            listener.onError(it)
            false
        }
    }

    fun sendControl(bytes: ByteArray): Boolean {
        val channel = controlChannel ?: return false
        if (channel.state() != DataChannel.State.OPEN) return false

        return channel.send(
            DataChannel.Buffer(
                ByteBuffer.wrap(bytes),
                true
            )
        )
    }

    override fun onRemoteDescription(description: SignalDescription) {
        if (closed.get()) return

        val sessionDescription = runCatching {
            SessionDescription(
                SessionDescription.Type.fromCanonicalForm(
                    description.type
                ),
                description.sdp
            )
        }.getOrElse {
            listener.onError(it)
            return
        }

        synchronized(pendingRemoteCandidates) {
            remoteDescriptionReady = false
        }

        peerConnection.setRemoteDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    remoteDescriptionReady = true
                    flushPendingCandidates()

                    if (
                        role == PeerRole.CONTROLLER &&
                        sessionDescription.type == SessionDescription.Type.OFFER
                    ) {
                        createAnswer()
                    }
                }

                override fun onSetFailure(error: String?) {
                    listener.onError(
                        IllegalStateException(
                            error ?: "Could not set remote description"
                        )
                    )
                }
            },
            sessionDescription
        )
    }

    override fun onRemoteCandidate(candidate: SignalCandidate) {
        if (closed.get()) return

        val ice = IceCandidate(
            candidate.sdpMid,
            candidate.sdpMLineIndex,
            candidate.sdp
        )

        synchronized(pendingRemoteCandidates) {
            if (!remoteDescriptionReady) {
                pendingRemoteCandidates.addLast(ice)
                return
            }
        }

        peerConnection.addIceCandidate(ice)
    }

    override fun onRemotePresence(online: Boolean) {
        if (!online && role == PeerRole.CONTROLLER) {
            listener.onPeerDisconnected()
        }
    }

    override fun onError(error: Throwable) {
        listener.onError(error)
    }

    override fun onSignalingChange(
        newState: PeerConnection.SignalingState
    ) = Unit

    override fun onIceConnectionChange(
        newState: PeerConnection.IceConnectionState
    ) {
        when (newState) {
            PeerConnection.IceConnectionState.CONNECTED,
            PeerConnection.IceConnectionState.COMPLETED ->
                listener.onPeerConnected()

            PeerConnection.IceConnectionState.DISCONNECTED,
            PeerConnection.IceConnectionState.FAILED,
            PeerConnection.IceConnectionState.CLOSED ->
                listener.onPeerDisconnected()

            else -> Unit
        }
    }

    override fun onConnectionChange(
        newState: PeerConnection.PeerConnectionState
    ) {
        when (newState) {
            PeerConnection.PeerConnectionState.CONNECTED ->
                listener.onPeerConnected()

            PeerConnection.PeerConnectionState.DISCONNECTED,
            PeerConnection.PeerConnectionState.FAILED,
            PeerConnection.PeerConnectionState.CLOSED ->
                listener.onPeerDisconnected()

            else -> Unit
        }
    }

    override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
    override fun onIceGatheringChange(
        newState: PeerConnection.IceGatheringState
    ) = Unit

    override fun onIceCandidate(candidate: IceCandidate) {
        signaling.sendCandidate(
            SignalCandidate(
                sdpMid = candidate.sdpMid,
                sdpMLineIndex = candidate.sdpMLineIndex,
                sdp = candidate.sdp
            )
        )
    }

    override fun onIceCandidatesRemoved(candidates: Array<IceCandidate>) = Unit
    override fun onAddStream(stream: MediaStream) = Unit
    override fun onRemoveStream(stream: MediaStream) = Unit

    override fun onDataChannel(dataChannel: DataChannel) {
        if (dataChannel.label() == CONTROL_CHANNEL) {
            bindControlChannel(dataChannel)
        }
    }

    override fun onRenegotiationNeeded() = Unit

    override fun onAddTrack(
        receiver: RtpReceiver,
        mediaStreams: Array<MediaStream>
    ) {
        (receiver.track() as? VideoTrack)?.let(listener::onRemoteVideoTrack)
    }

    override fun onTrack(transceiver: RtpTransceiver) {
        (transceiver.receiver.track() as? VideoTrack)
            ?.let(listener::onRemoteVideoTrack)
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return

        runCatching { signaling.setPresence(false) }
        runCatching { signaling.close() }

        controlChannel?.let {
            runCatching { it.unregisterObserver() }
            runCatching { it.close() }
            runCatching { it.dispose() }
        }
        controlChannel = null

        scope.cancel()
        handler.removeCallbacksAndMessages(null)

        runCatching { peerConnection.close() }
        runCatching { peerConnection.dispose() }

        synchronized(pendingRemoteCandidates) {
            pendingRemoteCandidates.clear()
        }
    }

    private fun createOffer() {
        peerConnection.createOffer(
            object : SdpObserverAdapter() {
                override fun onCreateSuccess(
                    description: SessionDescription?
                ) {
                    if (description == null) {
                        listener.onError(
                            IllegalStateException("Offer was null")
                        )
                        return
                    }
                    setLocalAndSignal(description)
                }

                override fun onCreateFailure(error: String?) {
                    listener.onError(
                        IllegalStateException(
                            error ?: "Could not create offer"
                        )
                    )
                }
            },
            MediaConstraints()
        )
    }

    private fun createAnswer() {
        peerConnection.createAnswer(
            object : SdpObserverAdapter() {
                override fun onCreateSuccess(
                    description: SessionDescription?
                ) {
                    if (description == null) {
                        listener.onError(
                            IllegalStateException("Answer was null")
                        )
                        return
                    }
                    setLocalAndSignal(description)
                }

                override fun onCreateFailure(error: String?) {
                    listener.onError(
                        IllegalStateException(
                            error ?: "Could not create answer"
                        )
                    )
                }
            },
            MediaConstraints()
        )
    }

    private fun setLocalAndSignal(
        description: SessionDescription
    ) {
        peerConnection.setLocalDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    signaling.sendDescription(
                        SignalDescription(
                            type = description.type.canonicalForm(),
                            sdp = description.description
                        )
                    )
                }

                override fun onSetFailure(error: String?) {
                    listener.onError(
                        IllegalStateException(
                            error ?: "Could not set local description"
                        )
                    )
                }
            },
            description
        )
    }

    private fun bindControlChannel(channel: DataChannel) {
        controlChannel?.let { existing ->
            if (existing !== channel) {
                runCatching { existing.unregisterObserver() }
                runCatching { existing.close() }
                runCatching { existing.dispose() }
            }
        }

        controlChannel = channel
        channel.registerObserver(
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(
                    previousAmount: Long
                ) = Unit

                override fun onStateChange() {
                    if (channel.state() == DataChannel.State.OPEN) {
                        listener.onControlChannelOpen()
                    }
                }

                override fun onMessage(buffer: DataChannel.Buffer) {
                    if (!buffer.binary) return

                    val source = buffer.data.slice()
                    val bytes = ByteArray(source.remaining())
                    source.get(bytes)
                    listener.onControlMessage(bytes)
                }
            }
        )

        if (channel.state() == DataChannel.State.OPEN) {
            listener.onControlChannelOpen()
        }
    }

    private fun flushPendingCandidates() {
        val pending = mutableListOf<IceCandidate>()

        synchronized(pendingRemoteCandidates) {
            while (pendingRemoteCandidates.isNotEmpty()) {
                pending += pendingRemoteCandidates.removeFirst()
            }
        }

        pending.forEach(peerConnection::addIceCandidate)
    }

    private fun createRtcConfiguration(
        iceServers: List<PeerConnection.IceServer>
    ): PeerConnection.RTCConfiguration {
        return PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy =
                PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
        }
    }

    companion object {
        private const val CONTROL_CHANNEL = "control-v1"
        private const val SCREEN_STREAM_ID = "remote-screen"
    }
}
