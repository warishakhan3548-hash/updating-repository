package com.aaris.remoteassist.webrtc

import android.content.Context
import android.net.ConnectivityManager
import android.net.Network
import android.os.Handler
import android.os.Looper
import org.webrtc.DataChannel
import org.webrtc.IceCandidate
import org.webrtc.MediaConstraints
import org.webrtc.MediaStream
import org.webrtc.MediaStreamTrack
import org.webrtc.PeerConnection
import org.webrtc.RtpParameters
import org.webrtc.RtpReceiver
import org.webrtc.RtpSender
import org.webrtc.RtpTransceiver
import org.webrtc.SessionDescription
import org.webrtc.VideoTrack
import java.nio.ByteBuffer
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class WebRtcPeer(
    context: Context,
    private val sessionId: String,
    private val role: PeerRole,
    private val signaling: SignalingClient,
    private val listener: Listener
) : SignalingClient.Listener, PeerConnection.Observer {
    interface Listener {
        fun onPeerConnected()
        fun onPeerDisconnected()
        fun onControlChannelOpen()
        fun onControlChannelClosed()
        fun onControlMessage(bytes: ByteArray)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onFallbackVideoFrame(frame: FallbackVideoFrame) = Unit
        fun onRemoteMediaRecoveryRequested() = Unit
        fun onVideoHealth(snapshot: VideoHealthSnapshot) = Unit
        fun onDiagnostic(message: String) = Unit
        fun onError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val factory = WebRtcRuntime.factory(appContext)
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val initialIceRestartAttempted = AtomicBoolean(false)
    private val offerPreparationInFlight = AtomicBoolean(false)
    private val handler = Handler(Looper.getMainLooper())
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private val connectivity = PeerConnectivityTracker()
    private val connectivityManager =
        appContext.getSystemService(ConnectivityManager::class.java)
    private val networkLock = Any()

    @Volatile
    private var networkCallbackRegistered = false

    private var activeDefaultNetwork: Network? = null
    private var hasSeenDefaultNetwork = false

    private val networkCallback =
        object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) {
                val changed = synchronized(networkLock) {
                    val previous = activeDefaultNetwork
                    val hadPrevious = hasSeenDefaultNetwork
                    activeDefaultNetwork = network
                    hasSeenDefaultNetwork = true
                    hadPrevious && previous != network
                }

                if (
                    changed &&
                    connectivity.hasEverConnected()
                ) {
                    when (role) {
                        PeerRole.HOST -> requestIceRestart()
                        PeerRole.CONTROLLER ->
                            signaling.requestRemoteIceRestart()
                    }
                }
            }

            override fun onLost(network: Network) {
                synchronized(networkLock) {
                    if (activeDefaultNetwork == network) {
                        activeDefaultNetwork = null
                    }
                }
            }
        }

    private val remoteCandidates =
        RemoteCandidateBuffer<IceCandidate>(
            MAX_PENDING_REMOTE_CANDIDATES
        )
    private val remoteDescriptionInFlight =
        AtomicBoolean(false)

    @Volatile
    private var lastAppliedRemoteNegotiationId: String? = null

    @Volatile
    private var lastAnsweredRemoteNegotiationId: String? = null

    private val lastIceRestartAtMs = AtomicLong(0L)
    private val controllerRelayRefreshAttempts = AtomicLong(0L)
    private var bootstrapRecoveryAttempts = 0
    private var offerRedeliveryAttempts = 0

    @Volatile
    private var preLiveDisconnected = false

    @Volatile
    private var lastRemoteAnswerAppliedAtMs = 0L

    private val initialIceRestart = Runnable {
        if (
            !closed.get() &&
            role == PeerRole.HOST &&
            preLiveDisconnected &&
            !connectivity.hasEverConnected() &&
            initialIceRestartAttempted.compareAndSet(false, true)
        ) {
            requestIceRestart()
        }
    }

    private val videoStatsProbe = object : Runnable {
        override fun run() {
            if (closed.get()) return

            peerConnection.getStats { report ->
                if (closed.get()) return@getStats
                VideoHealthSnapshot
                    .from(report, role)
                    ?.let(listener::onVideoHealth)
            }

            handler.postDelayed(
                this,
                VIDEO_STATS_INTERVAL_MS
            )
        }
    }

    private val bootstrapRecovery = object : Runnable {
        override fun run() {
            if (
                closed.get() ||
                role != PeerRole.HOST ||
                connectivity.hasEverConnected()
            ) {
                return
            }

            val signalingState =
                peerConnection.signalingState()

            when (signalingState) {
                PeerConnection.SignalingState.HAVE_LOCAL_OFFER -> {
                    if (
                        offerRedeliveryAttempts <
                            MAX_OFFER_REDELIVERY_ATTEMPTS &&
                        signaling.retryLocalDescription()
                    ) {
                        offerRedeliveryAttempts += 1
                    }
                }

                PeerConnection.SignalingState.STABLE -> {
                    val waitForCurrentIce =
                        BootstrapRecoveryPolicy.shouldWaitAfterRemoteAnswer(
                            lastRemoteAnswerAppliedAtMs =
                                lastRemoteAnswerAppliedAtMs,
                            nowMs = monotonicNowMs(),
                            settleWindowMs =
                                POST_ANSWER_ICE_SETTLE_MS
                        )
                    val forceRelay =
                        activeIceFromBackend ||
                            bootstrapRecoveryAttempts > 0
                    if (
                        !waitForCurrentIce &&
                        bootstrapRecoveryAttempts <
                            MAX_BOOTSTRAP_RECOVERY_ATTEMPTS &&
                        requestIceRestart(
                            forceRelay = forceRelay
                        )
                    ) {
                        bootstrapRecoveryAttempts += 1
                    }
                }

                else -> Unit
            }

            val recoveryRemaining =
                when (peerConnection.signalingState()) {
                    PeerConnection.SignalingState.HAVE_LOCAL_OFFER ->
                        offerRedeliveryAttempts <
                            MAX_OFFER_REDELIVERY_ATTEMPTS

                    PeerConnection.SignalingState.STABLE ->
                        bootstrapRecoveryAttempts <
                            MAX_BOOTSTRAP_RECOVERY_ATTEMPTS

                    else -> true
                }

            if (
                !closed.get() &&
                !connectivity.hasEverConnected() &&
                recoveryRemaining
            ) {
                val nextDelayMs =
                    if (
                        peerConnection.signalingState() ==
                            PeerConnection.SignalingState.HAVE_LOCAL_OFFER
                    ) {
                        BootstrapRecoveryPolicy
                            .offerRedeliveryDelayMs(
                                offerRedeliveryAttempts
                            )
                    } else {
                        BOOTSTRAP_RECOVERY_INTERVAL_MS
                    }

                handler.postDelayed(
                    this,
                    nextDelayMs
                )
            }
        }
    }

    @Volatile
    private var controlChannel: DataChannel? = null

    @Volatile
    private var liveControlChannel: DataChannel? = null

    @Volatile
    private var fallbackVideoChannel: DataChannel? = null

    private val fallbackReassembler =
        FallbackVideoProtocol.Reassembler()

    @Volatile
    private var localScreenTransceiver: RtpTransceiver? = null

    @Volatile
    private var controllerVideoTransceiver: RtpTransceiver? = null

    @Volatile
    private var publishedRemoteVideoTrack: VideoTrack? = null

    @Volatile
    private var videoMaxBitrateBps = DEFAULT_VIDEO_BITRATE_BPS

    @Volatile
    private var videoMaxFramerate = DEFAULT_VIDEO_FRAMERATE

    @Volatile
    private var preserveVideoResolution = true

    @Volatile
    private var motionPriority = false

    @Volatile
    private var activeIceServers = IceServerProvider.fallbackServers()

    @Volatile
    private var activeIceFromBackend = false

    private val controllerRelayRefresh = object : Runnable {
        override fun run() {
            if (
                closed.get() ||
                role != PeerRole.CONTROLLER ||
                connectivity.hasEverConnected() ||
                activeIceFromBackend
            ) {
                return
            }

            val attempt =
                controllerRelayRefreshAttempts.incrementAndGet()
            if (attempt > MAX_CONTROLLER_RELAY_REFRESH_ATTEMPTS) {
                return
            }

            scope.launch {
                val refreshed = IceServerProvider.loadConfig(
                    context = appContext,
                    sessionId = sessionId,
                    timeoutMs = PRELIVE_ICE_REFRESH_TIMEOUT_MS
                )

                if (!refreshed.fromBackend) {
                    scheduleControllerRelayRefreshRetry(attempt)
                    return@launch
                }

                handler.post {
                    if (
                        closed.get() ||
                        connectivity.hasEverConnected()
                    ) {
                        return@post
                    }

                    val applied = runCatching {
                        check(
                            peerConnection.setConfiguration(
                                createRtcConfiguration(
                                    refreshed.servers,
                                    relayOnly = false
                                )
                            )
                        ) {
                            "Could not refresh controller ICE configuration"
                        }
                    }.isSuccess

                    if (applied) {
                        activeIceServers = refreshed.servers
                        activeIceFromBackend = true
                        return@post
                    }

                    scheduleControllerRelayRefreshRetry(attempt)
                }
            }
        }
    }

    private fun scheduleControllerRelayRefreshRetry(
        completedAttempt: Long
    ) {
        if (
            closed.get() ||
            role != PeerRole.CONTROLLER ||
            connectivity.hasEverConnected() ||
            activeIceFromBackend ||
            completedAttempt >= MAX_CONTROLLER_RELAY_REFRESH_ATTEMPTS
        ) {
            return
        }

        handler.removeCallbacks(controllerRelayRefresh)
        handler.postDelayed(
            controllerRelayRefresh,
            CONTROLLER_RELAY_REFRESH_INTERVAL_MS
        )
    }

    private val peerConnection: PeerConnection = checkNotNull(
        factory.createPeerConnection(
            createRtcConfiguration(activeIceServers),
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

        listener.onDiagnostic("WebRTC engine start requested")
        registerNetworkHandoffObserver()

        scope.launch {
            val loaded = IceServerProvider.loadConfig(appContext, sessionId)
            handler.post {
                if (closed.get()) return@post

                runCatching {
                    activeIceServers = loaded.servers
                    activeIceFromBackend = loaded.fromBackend
                    listener.onDiagnostic(
                        if (loaded.fromBackend) {
                            "TURN + STUN ready; trying direct and relay paths in parallel"
                        } else {
                            "TURN unavailable; using STUN/direct candidates"
                        }
                    )
                    check(
                        peerConnection.setConfiguration(
                            createRtcConfiguration(
                                activeIceServers,
                                relayOnly = false
                            )
                        )
                    ) {
                        "Could not apply ICE server configuration"
                    }
                    startSignaling()
                }.onFailure(listener::onError)
            }
        }
    }

    private fun startSignaling() {
        if (closed.get()) return

        if (role == PeerRole.CONTROLLER) {
            ensureControllerVideoReceiver()
        }

        listener.onDiagnostic("Opening Cloudflare signaling channel")
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
            bindLiveControlChannel(
                peerConnection.createDataChannel(
                    LIVE_CONTROL_CHANNEL,
                    DataChannel.Init().apply {
                        ordered = false
                        maxRetransmits = 0
                    }
                )
            )
            bindFallbackVideoChannel(
                peerConnection.createDataChannel(
                    FALLBACK_VIDEO_CHANNEL,
                    DataChannel.Init().apply {
                        ordered = false
                        maxRetransmits = 0
                    }
                )
            )
            check(
                offerPreparationInFlight.compareAndSet(
                    false,
                    true
                )
            ) {
                "Initial WebRTC offer already in progress"
            }
            createOffer(
                onLocalDescriptionSet = {
                    offerPreparationInFlight.set(false)
                },
                onFailure = {
                    offerPreparationInFlight.set(false)
                }
            )
            bootstrapRecoveryAttempts = 0
            handler.removeCallbacks(bootstrapRecovery)
            handler.postDelayed(
                bootstrapRecovery,
                BOOTSTRAP_RECOVERY_INITIAL_DELAY_MS
            )
        } else if (!activeIceFromBackend) {
            handler.removeCallbacks(controllerRelayRefresh)
            handler.postDelayed(
                controllerRelayRefresh,
                CONTROLLER_RELAY_REFRESH_DELAY_MS
            )
        }
    }

    private fun ensureControllerVideoReceiver() {
        if (
            closed.get() ||
            role != PeerRole.CONTROLLER ||
            controllerVideoTransceiver != null
        ) {
            return
        }

        controllerVideoTransceiver = peerConnection.addTransceiver(
            MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO,
            RtpTransceiver.RtpTransceiverInit(
                RtpTransceiver.RtpTransceiverDirection.RECV_ONLY,
                emptyList()
            )
        )
        controllerVideoTransceiver?.let {
            preferBaselineScreenCodec(
                transceiver = it,
                senderSide = false
            )
        }
        listener.onDiagnostic(
            "Controller RECV_ONLY video transceiver ready • VP8 preferred"
        )
    }

    fun addLocalVideoTrack(
        track: VideoTrack,
        maxBitrateBps: Int = DEFAULT_VIDEO_BITRATE_BPS,
        maxFramerate: Int = DEFAULT_VIDEO_FRAMERATE,
        preserveResolution: Boolean = true
    ) {
        check(!closed.get())
        check(role == PeerRole.HOST) {
            "Only the host may publish the screen track"
        }
        check(localScreenTransceiver == null) {
            "Screen video transceiver already exists"
        }

        videoMaxBitrateBps =
            maxBitrateBps.coerceIn(
                MIN_VIDEO_BITRATE_BPS,
                MAX_VIDEO_BITRATE_BPS
            )
        videoMaxFramerate =
            maxFramerate.coerceIn(
                MIN_VIDEO_FRAMERATE,
                MAX_VIDEO_FRAMERATE
            )
        preserveVideoResolution = preserveResolution

        val transceiver = peerConnection.addTransceiver(
            track,
            RtpTransceiver.RtpTransceiverInit(
                RtpTransceiver.RtpTransceiverDirection.SEND_ONLY,
                listOf(SCREEN_STREAM_ID)
            )
        )
        localScreenTransceiver = transceiver
        preferBaselineScreenCodec(
            transceiver = transceiver,
            senderSide = true
        )
        listener.onDiagnostic(
            "Host SEND_ONLY screen transceiver ready • VP8 preferred"
        )
        applyInteractiveVideoPolicy(transceiver.sender)
    }

    private fun publishRemoteVideoTrack(
        track: VideoTrack?
    ) {
        if (
            closed.get() ||
            role != PeerRole.CONTROLLER ||
            track == null
        ) {
            return
        }

        track.setEnabled(true)

        if (publishedRemoteVideoTrack === track) {
            return
        }

        publishedRemoteVideoTrack = track
        listener.onDiagnostic("Remote video track discovered")
        listener.onRemoteVideoTrack(track)
    }

    private fun reconcileRemoteVideoTrack() {
        if (
            closed.get() ||
            role != PeerRole.CONTROLLER
        ) {
            return
        }

        val preferred =
            controllerVideoTransceiver
                ?.receiver
                ?.track() as? VideoTrack
        if (preferred != null) {
            publishRemoteVideoTrack(preferred)
            return
        }

        peerConnection.transceivers
            .asSequence()
            .mapNotNull { transceiver ->
                transceiver.receiver.track() as? VideoTrack
            }
            .firstOrNull()
            ?.let(::publishRemoteVideoTrack)
    }

    fun requestRemoteRecovery(): Boolean {
        if (
            closed.get() ||
            role != PeerRole.CONTROLLER
        ) {
            return false
        }

        reconcileRemoteVideoTrack()
        signaling.requestRemoteIceRestart()
        return true
    }

    fun requestIceRestart(
        forceRelay: Boolean = false
    ): Boolean {
        if (closed.get() || role != PeerRole.HOST) return false

        if (
            peerConnection.signalingState() !=
            PeerConnection.SignalingState.STABLE
        ) {
            return false
        }
        if (
            !offerPreparationInFlight.compareAndSet(
                false,
                true
            )
        ) {
            return false
        }

        val nowMs = System.nanoTime() / 1_000_000L
        while (true) {
            val previous = lastIceRestartAtMs.get()
            if (
                previous != 0L &&
                nowMs - previous < ICE_RESTART_MIN_INTERVAL_MS
            ) {
                offerPreparationInFlight.set(false)
                return false
            }
            if (lastIceRestartAtMs.compareAndSet(previous, nowMs)) {
                break
            }
        }

        scope.launch {
            val refreshTimeoutMs =
                if (connectivity.hasEverConnected()) {
                    RESTART_ICE_REFRESH_TIMEOUT_MS
                } else {
                    PRELIVE_ICE_REFRESH_TIMEOUT_MS
                }
            val refreshed = IceServerProvider.loadConfig(
                context = appContext,
                sessionId = sessionId,
                timeoutMs = refreshTimeoutMs
            )
            val selectedServers =
                if (refreshed.fromBackend) {
                    refreshed.servers
                } else {
                    activeIceServers
                }
            val relayOnly =
                forceRelay &&
                    selectedServers.any { server ->
                        server.urls.any(IceServerProvider::isTurnUrl)
                    }

            handler.post {
                if (closed.get()) {
                    offerPreparationInFlight.set(false)
                    return@post
                }

                if (
                    peerConnection.signalingState() !=
                    PeerConnection.SignalingState.STABLE
                ) {
                    offerPreparationInFlight.set(false)
                    return@post
                }

                runCatching {
                    if (refreshed.fromBackend) {
                        activeIceServers = refreshed.servers
                        activeIceFromBackend = true
                    }
                    remoteCandidates.markDescriptionNotReady()
                    check(
                        peerConnection.setConfiguration(
                            createRtcConfiguration(
                                iceServers = selectedServers,
                                relayOnly = relayOnly
                            )
                        )
                    ) {
                        "Could not refresh ICE server configuration"
                    }
                    peerConnection.restartIce()
                    createOffer(
                        onLocalDescriptionSet = {
                            offerPreparationInFlight.set(false)
                        },
                        onFailure = {
                            offerPreparationInFlight.set(false)
                        }
                    )
                }.onFailure {
                    offerPreparationInFlight.set(false)
                    listener.onError(it)
                }
            }
        }
        return true
    }

    fun sendControl(
        bytes: ByteArray,
        freshnessSensitive: Boolean = false
    ): Boolean {
        if (freshnessSensitive) {
            val liveChannel = liveControlChannel
            if (liveChannel?.state() == DataChannel.State.OPEN) {
                /*
                 * Once the freshness lane is open it owns every CONTINUE
                 * sample. Backpressure here means the sample is already stale,
                 * so drop it instead of feeding it into the reliable ordered
                 * lane and recreating head-of-line pointer lag.
                 *
                 * Reliable fallback is used only before the auxiliary lane has
                 * opened, which keeps startup compatibility without degrading
                 * steady-state latency under packet loss/congestion.
                 */
                if (
                    liveChannel.bufferedAmount() >=
                    MAX_FRESH_CONTROL_BUFFERED_BYTES
                ) {
                    return false
                }
                return sendBinary(liveChannel, bytes)
            }
        }

        val channel = controlChannel ?: return false
        if (channel.state() != DataChannel.State.OPEN) return false

        if (
            freshnessSensitive &&
            channel.bufferedAmount() >=
                MAX_FRESH_CONTROL_BUFFERED_BYTES
        ) {
            return false
        }

        return sendBinary(channel, bytes)
    }

    private fun sendBinary(
        channel: DataChannel,
        bytes: ByteArray
    ): Boolean =
        channel.send(
            DataChannel.Buffer(
                ByteBuffer.wrap(bytes),
                true
            )
        )

    fun sendFallbackVideo(bytes: ByteArray): Boolean {
        if (
            closed.get() ||
            role != PeerRole.HOST ||
            bytes.isEmpty() ||
            bytes.size > MAX_FALLBACK_PACKET_BYTES
        ) {
            return false
        }

        val channel = fallbackVideoChannel ?: return false
        if (channel.state() != DataChannel.State.OPEN) {
            return false
        }

        if (
            channel.bufferedAmount() >
            MAX_FALLBACK_BUFFERED_BYTES
        ) {
            return false
        }

        return sendBinary(channel, bytes)
    }

    override fun onRemoteDescription(description: SignalDescription) {
        if (closed.get()) return

        listener.onDiagnostic(
            "WebRTC received remote SDP " + description.type.uppercase()
        )

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

        val expectedRemoteType = when (role) {
            PeerRole.HOST -> SessionDescription.Type.ANSWER
            PeerRole.CONTROLLER -> SessionDescription.Type.OFFER
        }
        if (sessionDescription.type != expectedRemoteType) {
            listener.onError(
                IllegalStateException(
                    "Unexpected remote SDP type: " +
                        sessionDescription.type
                )
            )
            return
        }

        if (
            role == PeerRole.CONTROLLER &&
            sessionDescription.type == SessionDescription.Type.OFFER &&
            peerConnection.signalingState() !=
                PeerConnection.SignalingState.STABLE
        ) {
            return
        }

        if (
            role == PeerRole.HOST &&
            sessionDescription.type == SessionDescription.Type.ANSWER &&
            peerConnection.signalingState() !=
                PeerConnection.SignalingState.HAVE_LOCAL_OFFER
        ) {
            return
        }

        if (
            !remoteDescriptionInFlight.compareAndSet(
                false,
                true
            )
        ) {
            return
        }

        remoteCandidates.beginRemoteDescription(
            description.negotiationId
        )

        runCatching {
            peerConnection.setRemoteDescription(
                object : SdpObserverAdapter() {
                    override fun onSetSuccess() {
                        lastAppliedRemoteNegotiationId =
                            description.negotiationId
                        if (
                            role == PeerRole.HOST &&
                            sessionDescription.type ==
                                SessionDescription.Type.ANSWER
                        ) {
                            lastRemoteAnswerAppliedAtMs =
                                monotonicNowMs()
                        }
                        remoteDescriptionInFlight.set(false)
                        listener.onDiagnostic(
                            "Remote SDP " +
                                sessionDescription.type.canonicalForm().uppercase() +
                                " applied"
                        )

                        remoteCandidates
                            .markDescriptionReady()
                            .forEach(peerConnection::addIceCandidate)

                        if (
                            role == PeerRole.CONTROLLER &&
                            sessionDescription.type ==
                                SessionDescription.Type.OFFER
                        ) {
                            reconcileRemoteVideoTrack()
                            createAnswer(
                                description.negotiationId
                            )
                        }
                    }

                    override fun onSetFailure(error: String?) {
                        remoteDescriptionInFlight.set(false)
                        listener.onError(
                            IllegalStateException(
                                error ?:
                                    "Could not set remote description"
                            )
                        )
                    }
                },
                sessionDescription
            )
        }.onFailure {
            remoteDescriptionInFlight.set(false)
            listener.onError(it)
        }
    }

    override fun onRemoteDescriptionRedelivery(
        description: SignalDescription
    ) {
        if (closed.get()) return

        if (
            lastAppliedRemoteNegotiationId !=
            description.negotiationId
        ) {
            onRemoteDescription(description)
            return
        }

        if (
            role == PeerRole.CONTROLLER &&
            lastAnsweredRemoteNegotiationId ==
                description.negotiationId
        ) {
            signaling.retryLocalDescription()
        }
    }

    override fun onRemoteIceRestartRequested() {
        if (closed.get() || role != PeerRole.HOST) return

        listener.onRemoteMediaRecoveryRequested()

        if (
            peerConnection.signalingState() ==
            PeerConnection.SignalingState.STABLE
        ) {
            requestIceRestart(
                forceRelay = true
            )
        }
    }

    override fun onRemoteCandidate(candidate: SignalCandidate) {
        if (closed.get()) return

        val ice = IceCandidate(
            candidate.sdpMid,
            candidate.sdpMLineIndex,
            candidate.sdp
        )

        remoteCandidates.offer(
            negotiationId = candidate.negotiationId,
            value = ice
        )?.let(peerConnection::addIceCandidate)
    }

    override fun onRemotePresence(online: Boolean) = Unit

    override fun onSignalingDiagnostic(message: String) {
        listener.onDiagnostic(message)
    }

    override fun onError(error: Throwable) {
        listener.onDiagnostic(
            "Signaling/WebRTC error: " +
                (error.message ?: error.javaClass.simpleName)
        )
        listener.onError(error)
    }

    override fun onSignalingChange(
        newState: PeerConnection.SignalingState
    ) = Unit

    override fun onIceConnectionChange(
        newState: PeerConnection.IceConnectionState
    ) {
        listener.onDiagnostic("ICE state → " + newState.name)
        when (newState) {
            PeerConnection.IceConnectionState.CONNECTED,
            PeerConnection.IceConnectionState.COMPLETED ->
                handleTransportConnected()

            PeerConnection.IceConnectionState.FAILED ->
                handleTransportFailed()

            else -> Unit
        }
    }

    override fun onConnectionChange(
        newState: PeerConnection.PeerConnectionState
    ) {
        listener.onDiagnostic("PeerConnection state → " + newState.name)
        when (newState) {
            PeerConnection.PeerConnectionState.CONNECTED ->
                handleTransportConnected()

            PeerConnection.PeerConnectionState.DISCONNECTED ->
                handleTransportDisconnected()

            PeerConnection.PeerConnectionState.FAILED ->
                handleTransportFailed()

            PeerConnection.PeerConnectionState.CLOSED -> {
                if (!closed.get()) {
                    publishPeerDisconnected()
                }
            }

            else -> Unit
        }
    }

    private fun handleTransportConnected() {
        preLiveDisconnected = false
        handler.removeCallbacks(initialIceRestart)
        handler.removeCallbacks(bootstrapRecovery)
        handler.removeCallbacks(controllerRelayRefresh)
        reconcileRemoteVideoTrack()
        handler.removeCallbacks(videoStatsProbe)
        handler.postDelayed(
            videoStatsProbe,
            VIDEO_STATS_INITIAL_DELAY_MS
        )
        publishPeerConnected()
    }

    private fun handleTransportDisconnected() {
        preLiveDisconnected =
            !connectivity.hasEverConnected()

        if (connectivity.hasEverConnected()) {
            handler.removeCallbacks(initialIceRestart)
            publishPeerDisconnected()
            return
        }

        if (role == PeerRole.HOST) {
            handler.removeCallbacks(initialIceRestart)
            handler.postDelayed(
                initialIceRestart,
                INITIAL_ICE_RESTART_DELAY_MS
            )
        }
    }

    private fun handleTransportFailed() {
        preLiveDisconnected = false
        handler.removeCallbacks(initialIceRestart)

        if (connectivity.hasEverConnected()) {
            publishPeerDisconnected()
            return
        }

        if (
            role == PeerRole.HOST &&
            initialIceRestartAttempted.compareAndSet(
                false,
                true
            )
        ) {
            requestIceRestart(
                forceRelay = activeIceFromBackend
            )
        }
    }

    override fun onIceConnectionReceivingChange(receiving: Boolean) = Unit
    override fun onIceGatheringChange(
        newState: PeerConnection.IceGatheringState
    ) {
        listener.onDiagnostic("ICE gathering → " + newState.name)
    }

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
        if (role == PeerRole.CONTROLLER) {
            when (dataChannel.label()) {
                CONTROL_CHANNEL -> {
                    bindControlChannel(dataChannel)
                    return
                }

                LIVE_CONTROL_CHANNEL -> {
                    bindLiveControlChannel(dataChannel)
                    return
                }

                FALLBACK_VIDEO_CHANNEL -> {
                    bindFallbackVideoChannel(dataChannel)
                    return
                }
            }
        }

        runCatching { dataChannel.unregisterObserver() }
        runCatching { dataChannel.close() }
        runCatching { dataChannel.dispose() }
    }

    override fun onRenegotiationNeeded() = Unit

    override fun onAddTrack(
        receiver: RtpReceiver,
        mediaStreams: Array<MediaStream>
    ) {
        publishRemoteVideoTrack(
            receiver.track() as? VideoTrack
        )
    }

    override fun onTrack(transceiver: RtpTransceiver) {
        publishRemoteVideoTrack(
            transceiver.receiver.track() as? VideoTrack
        )
    }

    fun close() {
        if (!closed.compareAndSet(false, true)) return

        unregisterNetworkHandoffObserver()

        runCatching { signaling.setPresence(false) }
        runCatching { signaling.close() }

        controlChannel?.let(::disposeDataChannel)
        controlChannel = null

        liveControlChannel?.let(::disposeDataChannel)
        liveControlChannel = null

        fallbackVideoChannel?.let(::disposeDataChannel)
        fallbackVideoChannel = null
        fallbackReassembler.reset()

        publishedRemoteVideoTrack = null
        controllerVideoTransceiver = null
        localScreenTransceiver = null

        scope.cancel()
        handler.removeCallbacksAndMessages(null)

        runCatching { peerConnection.close() }
        runCatching { peerConnection.dispose() }

        lastAppliedRemoteNegotiationId = null
        lastAnsweredRemoteNegotiationId = null
        lastRemoteAnswerAppliedAtMs = 0L
        remoteDescriptionInFlight.set(false)
        remoteCandidates.reset()
    }

    private fun disposeDataChannel(channel: DataChannel) {
        runCatching { channel.unregisterObserver() }
        runCatching { channel.close() }
        runCatching { channel.dispose() }
    }

    private fun registerNetworkHandoffObserver() {
        if (networkCallbackRegistered) return

        synchronized(networkLock) {
            activeDefaultNetwork = connectivityManager.activeNetwork
            hasSeenDefaultNetwork = activeDefaultNetwork != null
        }

        networkCallbackRegistered = runCatching {
            connectivityManager.registerDefaultNetworkCallback(
                networkCallback
            )
            true
        }.getOrDefault(false)
    }

    private fun unregisterNetworkHandoffObserver() {
        if (!networkCallbackRegistered) return
        networkCallbackRegistered = false

        runCatching {
            connectivityManager.unregisterNetworkCallback(networkCallback)
        }

        synchronized(networkLock) {
            activeDefaultNetwork = null
            hasSeenDefaultNetwork = false
        }
    }

    private fun createOffer(
        onLocalDescriptionSet: (() -> Unit)? = null,
        onFailure: (() -> Unit)? = null
    ) {
        offerRedeliveryAttempts = 0
        if (role == PeerRole.HOST) {
            lastRemoteAnswerAppliedAtMs = 0L
        }

        val negotiationEpoch =
            signaling.beginLocalDescription()
        listener.onDiagnostic("Creating local SDP OFFER")
        peerConnection.createOffer(
            object : SdpObserverAdapter() {
                override fun onCreateSuccess(
                    description: SessionDescription?
                ) {
                    if (description == null) {
                        onFailure?.invoke()
                        listener.onError(
                            IllegalStateException("Offer was null")
                        )
                        return
                    }
                    setLocalAndSignal(
                        description = description,
                        negotiationEpoch = negotiationEpoch,
                        onLocalDescriptionSet =
                            onLocalDescriptionSet,
                        onFailure = onFailure
                    )
                }

                override fun onCreateFailure(error: String?) {
                    onFailure?.invoke()
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

    private fun createAnswer(
        remoteNegotiationId: String
    ) {
        val negotiationEpoch =
            signaling.beginLocalDescription()
        listener.onDiagnostic("Creating local SDP ANSWER")
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
                    setLocalAndSignal(
                        description = description,
                        negotiationEpoch = negotiationEpoch,
                        replyToNegotiationId =
                            remoteNegotiationId,
                        onLocalDescriptionSet = {
                            lastAnsweredRemoteNegotiationId =
                                remoteNegotiationId
                        }
                    )
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
        description: SessionDescription,
        negotiationEpoch: Long,
        replyToNegotiationId: String? = null,
        onLocalDescriptionSet: (() -> Unit)? = null,
        onFailure: (() -> Unit)? = null
    ) {
        peerConnection.setLocalDescription(
            object : SdpObserverAdapter() {
                override fun onSetSuccess() {
                    onLocalDescriptionSet?.invoke()
                    listener.onDiagnostic(
                        "Local SDP " +
                            description.type.canonicalForm().uppercase() +
                            " applied; publishing to Cloudflare"
                    )
                    if (role == PeerRole.CONTROLLER) {
                        reconcileRemoteVideoTrack()
                    }
                    signaling.sendDescription(
                        description = SignalDescription(
                            type = description.type.canonicalForm(),
                            sdp = description.description,
                            replyToNegotiationId =
                                replyToNegotiationId
                        ),
                        negotiationEpoch = negotiationEpoch
                    )
                }

                override fun onSetFailure(error: String?) {
                    onFailure?.invoke()
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
                disposeDataChannel(existing)
            }
        }

        controlChannel = channel
        channel.registerObserver(
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(
                    previousAmount: Long
                ) = Unit

                override fun onStateChange() {
                    when (channel.state()) {
                        DataChannel.State.OPEN -> {
                            listener.onDiagnostic("control-v1 DataChannel OPEN")
                            listener.onControlChannelOpen()
                        }

                        DataChannel.State.CLOSED -> {
                            if (!closed.get()) {
                                listener.onControlChannelClosed()
                            }
                        }

                        else -> Unit
                    }
                }

                override fun onMessage(buffer: DataChannel.Buffer) {
                    readControlMessage(buffer)
                }
            }
        )

        if (channel.state() == DataChannel.State.OPEN) {
            listener.onDiagnostic("control-v1 DataChannel OPEN")
            listener.onControlChannelOpen()
        }
    }

    private fun bindLiveControlChannel(channel: DataChannel) {
        liveControlChannel?.let { existing ->
            if (existing !== channel) {
                disposeDataChannel(existing)
            }
        }

        liveControlChannel = channel
        channel.registerObserver(
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(
                    previousAmount: Long
                ) = Unit

                override fun onStateChange() {
                    if (channel.state() == DataChannel.State.OPEN) {
                        listener.onDiagnostic(
                            "control-live-v1 DataChannel OPEN • freshness lane ready"
                        )
                    }
                }

                override fun onMessage(buffer: DataChannel.Buffer) {
                    readControlMessage(buffer)
                }
            }
        )

        if (channel.state() == DataChannel.State.OPEN) {
            listener.onDiagnostic(
                "control-live-v1 DataChannel OPEN • freshness lane ready"
            )
        }
    }

    private fun readControlMessage(buffer: DataChannel.Buffer) {
        if (!buffer.binary) return

        val source = buffer.data.slice()
        val size = source.remaining()
        if (
            size <= 0 ||
            size > MAX_CONTROL_PACKET_BYTES
        ) {
            return
        }

        val bytes = ByteArray(size)
        source.get(bytes)
        listener.onControlMessage(bytes)
    }

    private fun bindFallbackVideoChannel(
        channel: DataChannel
    ) {
        fallbackVideoChannel?.let { existing ->
            if (existing !== channel) {
                disposeDataChannel(existing)
            }
        }

        fallbackVideoChannel = channel
        channel.registerObserver(
            object : DataChannel.Observer {
                override fun onBufferedAmountChange(
                    previousAmount: Long
                ) = Unit

                override fun onStateChange() {
                    if (channel.state() == DataChannel.State.OPEN) {
                        listener.onDiagnostic(
                            "fallback-video-v1 DataChannel OPEN"
                        )
                    }
                }

                override fun onMessage(
                    buffer: DataChannel.Buffer
                ) {
                    if (
                        role != PeerRole.CONTROLLER ||
                        !buffer.binary
                    ) {
                        return
                    }

                    val source = buffer.data.slice()
                    val size = source.remaining()
                    if (
                        size <= 0 ||
                        size > MAX_FALLBACK_PACKET_BYTES
                    ) {
                        return
                    }

                    val bytes = ByteArray(size)
                    source.get(bytes)

                    fallbackReassembler
                        .offer(bytes)
                        ?.let { frame ->
                            listener.onDiagnostic(
                                "Compatibility video frame received (" +
                                    frame.jpeg.size +
                                    " bytes)"
                            )
                            listener.onFallbackVideoFrame(
                                frame
                            )
                        }
                }
            }
        )

        if (channel.state() == DataChannel.State.OPEN) {
            listener.onDiagnostic(
                "fallback-video-v1 DataChannel OPEN"
            )
        }
    }

    private fun publishPeerConnected() {
        if (connectivity.onConnected()) {
            listener.onPeerConnected()
        }
    }

    private fun publishPeerDisconnected() {
        if (connectivity.onDisconnected()) {
            listener.onPeerDisconnected()
        }
    }

    private fun preferBaselineScreenCodec(
        transceiver: RtpTransceiver,
        senderSide: Boolean
    ) {
        runCatching {
            val capabilities =
                if (senderSide) {
                    factory.getRtpSenderCapabilities(
                        MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO
                    )
                } else {
                    factory.getRtpReceiverCapabilities(
                        MediaStreamTrack.MediaType.MEDIA_TYPE_VIDEO
                    )
                }

            val codecs = capabilities.codecs
            if (codecs.isEmpty()) return@runCatching

            val vp8Payloads = codecs
                .filter { it.name.equals("VP8", ignoreCase = true) }
                .map { it.preferredPayloadType.toString() }
                .toSet()

            fun rank(codec: org.webrtc.RtpCapabilities.CodecCapability): Int {
                val name = codec.name.uppercase()
                if (name == "VP8") return 0

                if (
                    name == "RTX" &&
                    codec.parameters["apt"] in vp8Payloads
                ) {
                    return 1
                }

                return when (name) {
                    "RED", "ULPFEC", "FLEXFEC-03" -> 2
                    "VP9" -> 3
                    "H264" -> 4
                    "AV1", "AV1X", "AV1F" -> 5
                    "RTX" -> 6
                    else -> 7
                }
            }

            val ordered = codecs.withIndex()
                .sortedWith(
                    compareBy<IndexedValue<org.webrtc.RtpCapabilities.CodecCapability>>(
                        { rank(it.value) },
                        { it.index }
                    )
                )
                .map { it.value }

            transceiver.setCodecPreferences(ordered)
        }.onFailure {
            listener.onDiagnostic(
                "Video codec preference fallback: " +
                    (it.message ?: it.javaClass.simpleName)
            )
        }
    }

    fun updateInteractiveVideoPolicy(
        maxBitrateBps: Int,
        maxFramerate: Int,
        preserveResolution: Boolean,
        motionPriority: Boolean = false
    ) {
        if (closed.get() || role != PeerRole.HOST) return

        videoMaxBitrateBps =
            maxBitrateBps.coerceIn(
                MIN_VIDEO_BITRATE_BPS,
                MAX_VIDEO_BITRATE_BPS
            )
        videoMaxFramerate =
            maxFramerate.coerceIn(
                MIN_VIDEO_FRAMERATE,
                MAX_VIDEO_FRAMERATE
            )
        preserveVideoResolution = preserveResolution
        this.motionPriority = motionPriority

        localScreenTransceiver
            ?.sender
            ?.let(::applyInteractiveVideoPolicy)
    }

    private fun applyInteractiveVideoPolicy(
        sender: RtpSender
    ) {
        runCatching {
            val parameters = sender.parameters
            parameters.degradationPreference =
                when {
                    motionPriority ->
                        RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE
                    preserveVideoResolution ->
                        RtpParameters.DegradationPreference.MAINTAIN_RESOLUTION
                    else ->
                        RtpParameters.DegradationPreference.BALANCED
                }

            parameters.encodings.forEach { encoding ->
                encoding.maxBitrateBps = videoMaxBitrateBps
                encoding.maxFramerate = videoMaxFramerate
            }

            check(sender.setParameters(parameters)) {
                "WebRTC rejected interactive video sender parameters"
            }
        }.onFailure {
            listener.onDiagnostic(
                "Interactive video policy fallback: " +
                    (it.message ?: it.javaClass.simpleName)
            )
        }
    }

    private fun monotonicNowMs(): Long =
        System.nanoTime() / 1_000_000L

    private fun createRtcConfiguration(
        iceServers: List<PeerConnection.IceServer>,
        relayOnly: Boolean = false
    ): PeerConnection.RTCConfiguration {
        return PeerConnection.RTCConfiguration(iceServers).apply {
            sdpSemantics = PeerConnection.SdpSemantics.UNIFIED_PLAN
            continualGatheringPolicy =
                PeerConnection.ContinualGatheringPolicy.GATHER_CONTINUALLY
            iceTransportsType =
                if (relayOnly) {
                    PeerConnection.IceTransportsType.RELAY
                } else {
                    PeerConnection.IceTransportsType.ALL
                }
            iceCandidatePoolSize = 0
        }
    }

    companion object {
        private const val MAX_PENDING_REMOTE_CANDIDATES = 192
        private const val MAX_CONTROL_PACKET_BYTES = 4_096
        private const val MAX_FRESH_CONTROL_BUFFERED_BYTES = 512L
        private const val MAX_FALLBACK_PACKET_BYTES = 12_500
        private const val MAX_FALLBACK_BUFFERED_BYTES = 900_000L
        private const val CONTROL_CHANNEL = "control-v1"
        private const val LIVE_CONTROL_CHANNEL = "control-live-v1"
        private const val FALLBACK_VIDEO_CHANNEL = "fallback-video-v1"
        private const val SCREEN_STREAM_ID = "remote-screen"
        private const val MIN_VIDEO_BITRATE_BPS = 600_000
        private const val DEFAULT_VIDEO_BITRATE_BPS = 1_800_000
        private const val MAX_VIDEO_BITRATE_BPS = 8_000_000
        private const val MIN_VIDEO_FRAMERATE = 10
        private const val DEFAULT_VIDEO_FRAMERATE = 20
        private const val MAX_VIDEO_FRAMERATE = 30
        private const val VIDEO_STATS_INITIAL_DELAY_MS = 1_500L
        private const val VIDEO_STATS_INTERVAL_MS = 3_000L
        private const val RESTART_ICE_REFRESH_TIMEOUT_MS = 1_500L
        private const val PRELIVE_ICE_REFRESH_TIMEOUT_MS = 5_000L
        private const val ICE_RESTART_MIN_INTERVAL_MS = 2_500L
        private const val INITIAL_ICE_RESTART_DELAY_MS = 1_500L
        private const val BOOTSTRAP_RECOVERY_INITIAL_DELAY_MS = 4_000L
        private const val BOOTSTRAP_RECOVERY_INTERVAL_MS = 5_000L
        private const val POST_ANSWER_ICE_SETTLE_MS = 6_000L
        private const val CONTROLLER_RELAY_REFRESH_DELAY_MS = 2_000L
        private const val CONTROLLER_RELAY_REFRESH_INTERVAL_MS = 4_000L
        private const val MAX_CONTROLLER_RELAY_REFRESH_ATTEMPTS = 4L
        private const val MAX_BOOTSTRAP_RECOVERY_ATTEMPTS = 5
        private const val MAX_OFFER_REDELIVERY_ATTEMPTS = 9
    }
}
