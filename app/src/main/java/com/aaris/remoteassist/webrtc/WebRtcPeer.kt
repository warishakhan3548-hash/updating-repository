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
                    /*
                     * An ICE restart cannot begin until the pending offer has
                     * an answer. Re-deliver that exact offer instead of
                     * creating a second offer or overwriting its negotiation.
                     *
                     * This recovers the two important startup-loss cases:
                     *  1. controller attached after the first signal write;
                     *  2. controller answered, but the answer write was lost.
                     *
                     * The same negotiationId is retained, so existing trickle
                     * candidates remain correlated with the offer.
                     */
                    if (
                        offerRedeliveryAttempts <
                            MAX_OFFER_REDELIVERY_ATTEMPTS &&
                        signaling.retryLocalDescription()
                    ) {
                        offerRedeliveryAttempts += 1
                    }
                }

                PeerConnection.SignalingState.STABLE -> {
                    /*
                     * STABLE only means offer/answer negotiation completed; it
                     * does not mean ICE has had time to establish a route.
                     * On slower mobile networks the answer can land just
                     * before this watchdog fires. Restarting ICE immediately
                     * then destroys a healthy in-progress generation and can
                     * create a perpetual Connecting loop.
                     *
                     * Give every freshly-applied answer one full bounded
                     * settling window before escalating to a relay restart.
                     */
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
                handler.postDelayed(
                    this,
                    BOOTSTRAP_RECOVERY_INTERVAL_MS
                )
            }
        }
    }

    @Volatile
    private var controlChannel: DataChannel? = null

    /*
     * Keep the one-way screen media contract explicit on both peers.
     *
     * Host owns exactly one SEND_ONLY screen transceiver. Controller owns
     * exactly one RECV_ONLY video transceiver before signaling opens, so an
     * immediately replayed Cloudflare offer cannot race receiver creation.
     */
    @Volatile
    private var localScreenTransceiver: RtpTransceiver? = null

    @Volatile
    private var controllerVideoTransceiver: RtpTransceiver? = null

    @Volatile
    private var publishedRemoteVideoTrack: VideoTrack? = null

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
                                    relayOnly = true
                                )
                            )
                        ) {
                            "Could not refresh controller ICE configuration"
                        }
                    }.isSuccess

                    if (applied) {
                        activeIceServers = refreshed.servers
                        activeIceFromBackend = true

                        /*
                         * Do not overwrite controllerSignal here.
                         *
                         * During startup the most recent signaling value may still hold
                         * the SDP answer the host has not observed yet. Replacing
                         * it with a restart hint can permanently lose the answer
                         * and leave both phones stuck at Connecting.
                         *
                         * The host already owns bounded pre-live ICE restart
                         * cadence, so once TURN is installed here the next host
                         * recovery offer will gather relay-capable candidates
                         * without corrupting offer/answer signaling.
                         */
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
                            "TURN credentials loaded from Cloudflare"
                        } else {
                            "TURN unavailable; using STUN fallback"
                        }
                    )
                    check(
                        peerConnection.setConfiguration(
                            createRtcConfiguration(
                                activeIceServers,
                                relayOnly = loaded.fromBackend
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

        /*
         * The WebSocket can replay the host offer immediately on open.
         * Establish the controller's receive-side m=video contract first so
         * the offer is always answered with an explicit video receiver.
         */
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
        listener.onDiagnostic("Controller RECV_ONLY video transceiver ready")
    }

    fun addLocalVideoTrack(track: VideoTrack) {
        check(!closed.get())
        check(role == PeerRole.HOST) {
            "Only the host may publish the screen track"
        }
        check(localScreenTransceiver == null) {
            "Screen video transceiver already exists"
        }

        /*
         * Screen video is intentionally modeled as one authoritative
         * SEND_ONLY Unified-Plan transceiver instead of relying on addTrack()
         * to create an implicit SEND_RECV transceiver.
         *
         * The app has asymmetric media semantics: host -> controller is the
         * only video direction. Making that direction explicit guarantees
         * that the very first host offer contains a send-capable m=video
         * section and that every later ICE-restart offer reuses the same media
         * section. The controller mirrors this contract with one RECV_ONLY
         * transceiver created before signaling opens.
         */
        val transceiver = peerConnection.addTransceiver(
            track,
            RtpTransceiver.RtpTransceiverInit(
                RtpTransceiver.RtpTransceiverDirection.SEND_ONLY,
                listOf(SCREEN_STREAM_ID)
            )
        )
        localScreenTransceiver = transceiver
        listener.onDiagnostic("Host SEND_ONLY screen transceiver ready")
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

    /*
     * Some Android/libwebrtc builds can establish SCTP/DataChannel and create
     * the video receiver without reliably delivering onTrack/onAddTrack at the
     * moment the app expects it. The receiver is authoritative, so reconcile
     * it after SDP and transport transitions instead of waiting forever for a
     * callback that may already have been missed.
     */
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

        /*
         * A missed receiver callback is local state, not an ICE failure.
         * Reconcile the already-negotiated receiver first; then request the
         * host restart so a genuinely stalled RTP path still gets recovery.
         */
        reconcileRemoteVideoTrack()
        signaling.requestRemoteIceRestart()
        return true
    }

    fun requestIceRestart(
        forceRelay: Boolean = false
    ): Boolean {
        if (closed.get() || role != PeerRole.HOST) return false

        /*
         * Only one host offer may own negotiation at a time. The same gate
         * covers the initial offer plus TURN refresh, bootstrap recovery,
         * route handoff and disconnect recovery. Starting a second
         * createOffer() while another local offer is being prepared is enough
         * to poison the SDP/ICE generation and leave both phones "connecting".
         */
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
            /*
             * Startup redelivery may arrive while the controller is still
             * finishing the first copy of the same offer. Do not run two
             * concurrent setRemoteDescription/createAnswer pipelines.
             * The host will redeliver again if the answer never lands.
             */
            return
        }

        if (
            role == PeerRole.HOST &&
            sessionDescription.type == SessionDescription.Type.ANSWER &&
            peerConnection.signalingState() !=
                PeerConnection.SignalingState.HAVE_LOCAL_OFFER
        ) {
            /*
             * An answer is valid only while this peer owns a local offer.
             * Ignore delayed/duplicate answers rather than treating them as a
             * restart command. ICE restart now has its own explicit signal.
             */
            return
        }

        if (
            !remoteDescriptionInFlight.compareAndSet(
                false,
                true
            )
        ) {
            // The authoritative signal remains replayable. If this was a newer
            // generation the host-side delivery watchdog will re-deliver it
            // after the current SDP application has settled.
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
                            /*
                             * setRemoteDescription can create/associate the
                             * receiver before libwebrtc posts onTrack. Publish
                             * it immediately when present, then answer.
                             */
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

        /*
         * A delivery retry is not a new SDP generation.
         *
         * - If this exact remote generation never reached WebRTC, process it.
         * - If the controller already applied the offer and has an answer for
         *   it, re-publish that SAME answer/negotiation ID. This preserves
         *   trickle-candidate correlation instead of manufacturing a second
         *   answer generation.
         * - If the answer is still being created, do nothing; the host's next
         *   bounded redelivery can retry after it settles.
         */
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

        /*
         * If an offer is already pending, it is already the authoritative
         * recovery negotiation, so no second offer is needed.
         */
        if (
            peerConnection.signalingState() ==
            PeerConnection.SignalingState.STABLE
        ) {
            /*
             * An explicit controller recovery request is stronger than a
             * passive connectivity flap. It is used when remote video has
             * stalled or after a route handoff, so prefer a freshly-minted
             * relay path when TURN is available instead of repeatedly
             * selecting the same direct candidate pair.
             */
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

    // Backend presence is advisory signaling telemetry, not transport truth.
    // A temporary signaling disconnect must not override a healthy WebRTC
    // peer connection and ordered control channel.
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
        /*
         * Some Android/libwebrtc builds surface ICE progress a little before
         * PeerConnectionState catches up. Treat ICE CONNECTED/COMPLETED as a
         * positive secondary liveness signal so an otherwise healthy session
         * cannot remain stuck in Connecting just because the aggregate
         * callback is delayed.
         *
         * DISCONNECTED is intentionally left to PeerConnectionState/DataChannel
         * because mobile route handoffs can make ICE briefly flap without the
         * transport actually becoming unusable.
         */
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
            /*
             * A pre-live failure is recoverable. If signaling is not STABLE
             * yet requestIceRestart() may decline this immediate attempt; the
             * existing SDP redelivery/bootstrap loop then remains the bounded
             * recovery authority. Never tear down the whole session merely
             * because ICE and PeerConnection both reported the same failure.
             */
            requestIceRestart(
                forceRelay = activeIceFromBackend
            )
        }
        // The controller stays attached for the host's recovery offer. The
        // 60-second HELLO/session watchdogs remain the terminal authority.
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
        if (
            role == PeerRole.CONTROLLER &&
            dataChannel.label() == CONTROL_CHANNEL
        ) {
            bindControlChannel(dataChannel)
            return
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

        controlChannel?.let {
            runCatching { it.unregisterObserver() }
            runCatching { it.close() }
            runCatching { it.dispose() }
        }
        controlChannel = null
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
        // Redelivery/recovery timing belongs to one concrete SDP generation.
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
                        /*
                         * The receiver can become usable only after the local
                         * answer commits. Reconcile again so callback ordering
                         * cannot strand a valid video track.
                         */
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
            }
        )

        if (channel.state() == DataChannel.State.OPEN) {
            listener.onDiagnostic("control-v1 DataChannel OPEN")
            listener.onControlChannelOpen()
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

    private fun applyInteractiveVideoPolicy(
        sender: RtpSender
    ) {
        runCatching {
            val parameters = sender.parameters
            parameters.degradationPreference =
                RtpParameters.DegradationPreference.MAINTAIN_FRAMERATE

            parameters.encodings.forEach { encoding ->
                encoding.maxBitrateBps = MAX_VIDEO_BITRATE_BPS
                encoding.maxFramerate = MAX_VIDEO_FRAMERATE
            }

            sender.setParameters(parameters)
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
            // The final ICE list is loaded immediately before signaling.
            // Keeping the pool at zero prevents fallback-only candidates from
            // being pre-gathered before TURN is applied with setConfiguration.
            iceCandidatePoolSize = 0
        }
    }

    companion object {
        private const val MAX_PENDING_REMOTE_CANDIDATES = 192
        private const val MAX_CONTROL_PACKET_BYTES = 4_096
        private const val CONTROL_CHANNEL = "control-v1"
        private const val SCREEN_STREAM_ID = "remote-screen"
        private const val MAX_VIDEO_BITRATE_BPS = 2_500_000
        private const val MAX_VIDEO_FRAMERATE = 30
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
        /*
         * Backend CONNECT_TTL is 180 s. Keep re-delivering the exact same
         * pending offer for ~2.5 minutes (initial 4 s + 29 * 5 s), so the host
         * does not give up long before the authoritative session expires.
         * The same negotiationId is reused; this is waiting/replay, not a
         * second negotiation.
         */
        private const val MAX_OFFER_REDELIVERY_ATTEMPTS = 30
    }
}
