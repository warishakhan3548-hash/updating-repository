package com.aaris.remoteassist.webrtc

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureQualityGovernor
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.ProjectionGrant
import com.aaris.remoteassist.capture.ScreenCaptureTrack
import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.control.GestureStreamPhase
import com.aaris.remoteassist.session.LiveLease
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

class HostWebRtcSession(
    context: Context,
    private val sessionId: String,
    projectionGrant: ProjectionGrant,
    private val listener: Listener
) : Closeable, WebRtcPeer.Listener {
    interface Listener {
        fun onLive()
        fun onConnectivityChanged(connected: Boolean)
        fun onProjectionStopped()
        fun onRemoteDisconnect()
        fun onLocalControlUnavailable()
        fun onDiagnostic(message: String) = Unit
        fun onRecoverableError(error: Throwable)
        fun onTerminalError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val displayManager =
        appContext.getSystemService(DisplayManager::class.java)
    private val displayHandler = Handler(Looper.getMainLooper())

    private val maxCaptureTier =
        CaptureProfile.recommendedTier(appContext)

    @Volatile
    private var captureTier = maxCaptureTier

    @Volatile
    private var profile =
        CaptureProfile.current(appContext, captureTier)

    private val captureQualityGovernor =
        CaptureQualityGovernor(
            initialTier = captureTier,
            maxTier = maxCaptureTier
        )
    private val cadenceGovernor =
        VideoCadenceGovernor(
            maxFps = minOf(profile.motionFps, MAX_SESSION_VIDEO_FPS),
            initialCap = minOf(profile.motionFps, MAX_SESSION_VIDEO_FPS)
        )
    private val passiveMotionPriority = PassiveMotionPriority()
    private val motionVideoBudget = MotionVideoBudget()
    private val receiverFeedback = ReceiverVideoFeedback()
    private var lastSlowVideoCheckMs = 0L
    // Evidence is taken while the producer is quiet, BEFORE fresh motion.
    // A short-lived snapshot is enough to safely probe one FPS rung.
    private var lastQuietOutbound: VideoHealthSnapshot? = null
    private var lastQuietSourceFps: Double? = null
    private var lastQuietSampleAtMs = 0L

    @Volatile
    private var peerConnected = false

    @Volatile
    private var everConnected = false

    @Volatile
    private var controlOpen = false

    @Volatile
    private var transportReady = false

    @Volatile
    private var interactionActive = false

    private val interactionPriorityTimeout = Runnable {
        if (!closed.get() && interactionActive) {
            interactionActive = false
            fallbackStreamer.setInteractionActive(false)
            applyVideoPolicy(profile)
            listener.onDiagnostic(
                if (freshnessPriorityActive()) {
                    "Remote interaction idle • visible screen motion remains freshness-first"
                } else {
                    "Remote interaction idle • native motion adaptation remains enabled"
                }
            )
        }
    }

    private var startupControlRecoveryAttempts = 0
    private var captureRecoveryAttempts = 0
    private val localCaptureFrameSeen = AtomicBoolean(false)

    @Volatile
    private var lease: LiveLease? = null

    private val transport = ControlTransportTracker()

    private val signaling = CloudflareSignalingClient(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.HOST
    )

    private val peer = WebRtcPeer(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.HOST,
        signaling = signaling,
        listener = this
    )

    private val capture = ScreenCaptureTrack(
        context = appContext,
        grant = projectionGrant,
        onProjectionStopped = listener::onProjectionStopped,
        onSourceMotion = {
            // Capture-thread signal only posts tiny work. Policy evaluation and
            // sender mutation remain serialized on the main/session thread.
            displayHandler.post { handleSourceMotionPulse() }
        }
    )

    private val fallbackStreamer =
        FallbackScreenStreamer(
            capture = capture,
            sendPacket = peer::sendFallbackVideo,
            onDiagnostic = listener::onDiagnostic,
            canStartFrame = peer::canStartFallbackFrame,
            requestFreshFrame = capture::requestSnapshot
        )

    private val captureProbe = VideoSink {
        if (localCaptureFrameSeen.compareAndSet(false, true)) {
            listener.onDiagnostic("MediaProjection produced first capture frame")
            displayHandler.removeCallbacks(captureFrameWatchdog)
            displayHandler.post {
                if (!closed.get()) {
                    ensureLiveHandshake()
                }
            }
        }
    }

    private val captureFrameWatchdog = object : Runnable {
        override fun run() {
            if (closed.get() || localCaptureFrameSeen.get()) {
                return
            }

            if (captureRecoveryAttempts < MAX_CAPTURE_RECOVERY_ATTEMPTS) {
                captureRecoveryAttempts += 1
                capture.update(effectiveCaptureProfile(profile))
                displayHandler.postDelayed(
                    this,
                    CAPTURE_RECOVERY_INTERVAL_MS
                )
                return
            }

            listener.onTerminalError(
                IllegalStateException(
                    "Screen capture produced no video frames"
                )
            )
        }
    }

    private val connectionWatchdog = Runnable {
        if (
            !closed.get() &&
            (!peerConnected || !controlOpen)
        ) {
            listener.onRemoteDisconnect()
        }
    }

    private val iceRestart = Runnable {
        if (
            !closed.get() &&
            everConnected &&
            !peerConnected
        ) {
            peer.requestIceRestart()
        }
    }

    private val startupControlRecovery = object : Runnable {
        override fun run() {
            if (
                !StartupTransportRecoveryPolicy.shouldAttempt(
                    peerConnected = peerConnected,
                    controlChannelOpen = controlOpen,
                    transportReady = transportReady,
                    completedAttempts =
                        startupControlRecoveryAttempts,
                    maxAttempts =
                        MAX_STARTUP_CONTROL_RECOVERY_ATTEMPTS
                ) ||
                closed.get()
            ) {
                return
            }

            val requested = peer.requestIceRestart(
                forceRelay =
                    StartupTransportRecoveryPolicy.shouldForceRelay(
                        startupControlRecoveryAttempts
                    )
            )

            if (requested) {
                startupControlRecoveryAttempts += 1
            }

            if (
                !closed.get() &&
                StartupTransportRecoveryPolicy.shouldAttempt(
                    peerConnected = peerConnected,
                    controlChannelOpen = controlOpen,
                    transportReady = transportReady,
                    completedAttempts =
                        startupControlRecoveryAttempts,
                    maxAttempts =
                        MAX_STARTUP_CONTROL_RECOVERY_ATTEMPTS
                )
            ) {
                displayHandler.postDelayed(
                    this,
                    STARTUP_CONTROL_RECOVERY_INTERVAL_MS
                )
            }
        }
    }

    private val leaseWatchdog = object : Runnable {
        override fun run() {
            if (closed.get()) return

            val expected = lease
            if (
                expected != null &&
                SessionRuntime.currentLease() == null
            ) {
                listener.onRemoteDisconnect()
                return
            }

            if (
                expected != null &&
                !AssistAccessibilityService.isConnected()
            ) {
                listener.onLocalControlUnavailable()
                return
            }

            displayHandler.postDelayed(
                this,
                LEASE_WATCHDOG_MS
            )
        }
    }

    private val displayListener = object : DisplayManager.DisplayListener {
        override fun onDisplayAdded(displayId: Int) = Unit
        override fun onDisplayRemoved(displayId: Int) = Unit

        override fun onDisplayChanged(displayId: Int) {
            refreshDisplayProfile()
        }
    }

    fun start() {
        check(!closed.get())

        displayManager.registerDisplayListener(
            displayListener,
            displayHandler
        )

        captureRecoveryAttempts = 0
        localCaptureFrameSeen.set(false)

        val initialEffective = effectiveCaptureProfile(profile)
        listener.onDiagnostic(
            "Starting MediaProjection capture • app=" +
                com.aaris.remoteassist.BuildConfig.VERSION_NAME +
                " (" + com.aaris.remoteassist.BuildConfig.VERSION_CODE + ") • encoder=realtime • " +
                initialEffective.captureWidthPx +
                "x" +
                initialEffective.captureHeightPx +
                "@" +
                initialEffective.fps +
                " • tier=" +
                profile.tier.name
        )
        capture.videoTrack.addSink(captureProbe)
        val initialVideoPolicy =
            InteractiveVideoPolicy.forState(
                tier = profile.tier,
                interactionActive = false
            )
        peer.addLocalVideoTrack(
            track = capture.videoTrack,
            maxBitrateBps = profile.maxVideoBitrateBps,
            maxFramerate = initialEffective.fps,
            preserveResolution =
                initialVideoPolicy.preserveResolution,
            motionPriority = initialVideoPolicy.motionPriority
        )
        capture.start(initialEffective)

        displayHandler.removeCallbacks(captureFrameWatchdog)
        displayHandler.postDelayed(
            captureFrameWatchdog,
            CAPTURE_FIRST_FRAME_TIMEOUT_MS
        )

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.postDelayed(
            connectionWatchdog,
            CONNECT_TIMEOUT_MS
        )
        peer.start()
    }

    @Synchronized
    fun refreshDisplayProfile() {
        if (closed.get()) return

        val previous = profile
        val latest =
            CaptureProfile.current(
                appContext,
                captureTier
            )
        if (latest == previous) return

        profile = latest
        applyVideoPolicy(latest)

        /*
         * Capture resolution/FPS may adapt without changing the remote phone's
         * logical display geometry. Only rotate the control generation when
         * the actual display dimensions changed (rotation/display resize).
         */
        if (
            latest.displayWidthPx == previous.displayWidthPx &&
            latest.displayHeightPx == previous.displayHeightPx
        ) {
            return
        }

        val currentLease = lease ?: return
        val rotated = SessionCoordinator.bumpDisplayGeneration(
            sessionId
        ) ?: return

        lease = rotated
        sendHello(rotated, latest)
    }

    @Synchronized
    private fun applyCaptureTier(
        nextTier: CaptureTier
    ) {
        if (
            closed.get() ||
            nextTier == captureTier ||
            nextTier.ordinal > maxCaptureTier.ordinal
        ) {
            return
        }

        captureTier = nextTier
        val next =
            CaptureProfile.current(
                appContext,
                nextTier
            )
        profile = next
        applyVideoPolicy(next)

        listener.onDiagnostic(
            "Adaptive screen quality → " +
                next.tier.name +
                " • " +
                next.captureWidthPx +
                "x" +
                next.captureHeightPx +
                "@" +
                next.fps +
                " • max=" +
                next.maxVideoBitrateBps +
                "bps"
        )
    }

    override fun onPeerConnected() {
        listener.onDiagnostic("Host WebRTC transport CONNECTED")
        peerConnected = true
        everConnected = true
        displayHandler.removeCallbacks(iceRestart)

        if (!controlOpen && !transportReady) {
            displayHandler.removeCallbacks(startupControlRecovery)
            displayHandler.postDelayed(
                startupControlRecovery,
                STARTUP_CONTROL_RECOVERY_INITIAL_DELAY_MS
            )
        }

        transport.onPeerConnected()
            ?.let(listener::onConnectivityChanged)
        ensureLiveHandshake()
    }

    override fun onPeerDisconnected() {
        peerConnected = false
        transportReady = false
        passiveMotionPriority.reset()
        updateInteractionPriority(false)
        displayHandler.removeCallbacks(startupControlRecovery)
        transport.onPeerDisconnected()
            ?.let(listener::onConnectivityChanged)

        if (everConnected && !closed.get()) {
            displayHandler.removeCallbacks(iceRestart)
            displayHandler.postDelayed(
                iceRestart,
                ICE_RESTART_DELAY_MS
            )
        }
    }

    override fun onControlChannelOpen() {
        listener.onDiagnostic("Host control-v1 DataChannel OPEN")
        controlOpen = true
        displayHandler.removeCallbacks(startupControlRecovery)
        transport.onControlChannelOpen()
            ?.let(listener::onConnectivityChanged)
        ensureLiveHandshake()
    }

    override fun onControlChannelClosed() {
        controlOpen = false
        transportReady = false
        passiveMotionPriority.reset()
        updateInteractionPriority(false)
        transport.onControlChannelClosed()
            ?.let(listener::onConnectivityChanged)
        if (!closed.get()) {
            displayHandler.removeCallbacks(connectionWatchdog)
            displayHandler.postDelayed(
                connectionWatchdog,
                CONTROL_CHANNEL_GRACE_MS
            )
        }
    }

    override fun onControlMessage(bytes: ByteArray) {
        val packet = ControlProtocol.decode(bytes) ?: return

        when (packet) {
            is ControlPacket.Heartbeat -> {
                val currentLease = lease ?: return
                if (packet.leaseSecret != currentLease.leaseSecret) return

                SessionRuntime.renew(
                    sessionId = sessionId,
                    leaseSecret = currentLease.leaseSecret
                )?.let { lease = it }

                displayHandler.post {
                    refreshDisplayProfile()
                }
            }

            ControlPacket.Disconnect -> {
                updateInteractionPriority(false)
                listener.onRemoteDisconnect()
            }

            is ControlPacket.Tap,
            is ControlPacket.LongPress,
            is ControlPacket.Swipe,
            is ControlPacket.GesturePath,
            is ControlPacket.GestureStream,
            is ControlPacket.TwoFinger,
            is ControlPacket.Back,
            is ControlPacket.Home,
            is ControlPacket.Recents,
            is ControlPacket.Text -> {
                val currentProfile = profile
                val command = ControlProtocol.toRemoteCommand(
                    sessionId = sessionId,
                    packet = packet,
                    widthPx = currentProfile.displayWidthPx,
                    heightPx = currentProfile.displayHeightPx
                ) ?: return

                /*
                 * The real command stream is the authoritative motion clock.
                 * control-live-v1 CONTINUE packets are intentionally unordered
                 * and may arrive before the reliable InteractionState(true)
                 * hint. Promoting video priority here removes that cross-lane
                 * race and keeps capture/encoder cadence aligned to the pixels
                 * the controller is actively changing.
                 */
                noteRemoteInteraction()

                AssistAccessibilityService.dispatch(command) { applied ->
                    /*
                     * CONTINUE is a freshness-only motion sample. It is never
                     * acknowledged, whether applied or dropped, because a late
                     * failure is not actionable and must not compete with newer
                     * positions or flash a false UI error when the reliable
                     * START is still crossing the network. START/END and every
                     * other authoritative command remain acknowledged.
                     */
                    if (
                        packet is ControlPacket.GestureStream &&
                        packet.phase == GestureStreamPhase.CONTINUE
                    ) {
                        return@dispatch
                    }

                    peer.sendControl(
                        ControlProtocol.encode(
                            ControlPacket.CommandResult(
                                sequence = command.sequence,
                                applied = applied
                            )
                        )
                    )
                }
            }

            is ControlPacket.VideoRecoveryRequest -> {
                val currentLease = lease ?: return
                if (
                    packet.leaseSecret !=
                    currentLease.leaseSecret
                ) {
                    return
                }
                handleMediaRecoveryRequest()
            }

            is ControlPacket.PrimaryVideoReady -> {
                val currentLease = lease ?: return
                if (
                    packet.leaseSecret !=
                    currentLease.leaseSecret
                ) {
                    return
                }

                displayHandler.post {
                    if (!closed.get()) {
                        primaryRecoveryRequests = 0
                        fallbackStreamer.disable()
                    }
                }
                listener.onDiagnostic(
                    "Primary screen renderer confirmed healthy • fallback stopped"
                )
            }

            is ControlPacket.InteractionState -> {
                val currentLease = lease ?: return
                if (
                    packet.leaseSecret !=
                    currentLease.leaseSecret
                ) {
                    return
                }

                if (packet.active) {
                    noteRemoteInteraction()
                } else {
                    /*
                     * The controller's false state is an early power/UX hint,
                     * not proof that visible motion is over. A fling, launcher
                     * animation or page transition can continue after finger-up.
                     * Keep the host's existing short freshness tail, which is
                     * anchored by the last actual command packet. Disconnects
                     * and transport closure still clear priority immediately.
                     */
                    Unit
                }
            }

            is ControlPacket.FallbackDeltaReady -> {
                val currentLease = lease ?: return
                if (
                    packet.leaseSecret !=
                    currentLease.leaseSecret
                ) {
                    return
                }
                fallbackStreamer.setDeltaCapable(true)
                listener.onDiagnostic(
                    "Controller supports adaptive delta recovery transport"
                )
            }

            is ControlPacket.VideoFeedback -> displayHandler.post {
                val current = lease
                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {
                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())
                }
            }
            is ControlPacket.PresentationFeedback -> displayHandler.post {
                val current = lease
                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {
                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())
                }
            }
            is ControlPacket.CommandResult,
            is ControlPacket.Hello -> Unit
        }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) = Unit

    override fun onRemoteMediaRecoveryRequested() {
        /*
         * Legacy signaling-level recovery remains as a last resort when the
         * control channel itself is unavailable.
         */
        handleMediaRecoveryRequest()
    }

    private var primaryRecoveryRequests = 0
    private var lastPrimaryRepairRequestMs = 0L

    private fun handleMediaRecoveryRequest() {
        displayHandler.post {
            if (closed.get()) return@post
            fallbackStreamer.enable()
            fallbackStreamer.requestKeyframe()
            // Pausing the track here also pauses the primary encoder we want to
            // recover. Request current pixels without disabling capture/video.
            runCatching { capture.requestSnapshot() }
            val now = android.os.SystemClock.elapsedRealtime()
            val decodedRecently = lease?.let {
                receiverFeedback.hasRecentDecodedFrames(it.leaseSecret, it.displayGeneration, now)
            } == true
            if (decodedRecently) {
                // A slow/missing Surface is a renderer problem. Renegotiating a
                // working hardware codec can replace it with expensive libvpx
                // while the original presentation problem is still unresolved.
                primaryRecoveryRequests = 0
                lastPrimaryRepairRequestMs = now
                listener.onDiagnostic("Primary decoder is progressing • retaining codec during display recovery")
            } else if (now - lastPrimaryRepairRequestMs >= 2500L) {
                lastPrimaryRepairRequestMs = now
                primaryRecoveryRequests++
                if (primaryRecoveryRequests >= 2) peer.recoverPrimaryVideoCodec()
            }
            listener.onDiagnostic("Video recovery active • fresh capture requested")
        }
    }

    override fun onVideoHealth(
        snapshot: VideoHealthSnapshot
    ) {
        if (snapshot.direction != "outbound") return

        displayHandler.post {
            if (closed.get()) return@post

            val now = android.os.SystemClock.elapsedRealtime()
            val current = lease
            val receiver =
                current?.let {
                    receiverFeedback.consume(
                        it.leaseSecret,
                        it.displayGeneration,
                        now
                    )
                }

            val sourceFps = capture.sampleSourceFps(now)
            val motionChanged =
                passiveMotionPriority.observe(
                    window = snapshot.recent,
                    nowMs = now,
                    sourceFps = sourceFps
                )
            val motionActive = freshnessPriorityActive(now)
            if (!motionActive && sourceFps != null &&
                sourceFps.isFinite() && sourceFps >= 0.0 && sourceFps < 2.5 &&
                (snapshot.recent?.frames ?: Int.MAX_VALUE) <= 3) {
                lastQuietOutbound = snapshot
                lastQuietSourceFps = sourceFps
                lastQuietSampleAtMs = now
            }
            val resolutionChanged = motionVideoBudget.observe(
                outbound = snapshot,
                receiver = receiver,
                sourceFps = sourceFps,
                motionActive = motionActive,
                targetFps = minOf(30, profile.motionFps),
                nowMs = now
            )
            val requestedFps = effectiveCaptureProfile(profile).fps
            val cadenceChanged =
                cadenceGovernor.observe(
                    outbound = snapshot,
                    receiver = receiver,
                    requestedFps = requestedFps,
                    nowMs = now,
                    minimumFps = motionVideoBudget.cadenceFloor(profile, motionActive, now),
                    producerFps = sourceFps
                )
            if (motionChanged || cadenceChanged || resolutionChanged) {
                applyVideoPolicy(profile)
            }
            if (resolutionChanged) {
                val effective = effectiveCaptureProfile(profile)
                listener.onDiagnostic(
                    "Motion video budget → ${effective.captureWidthPx}x${effective.captureHeightPx}@${effective.fps}" +
                        " • max=${motionVideoBudget.bitrateCeiling(profile, motionActive) / 1000}kbps" +
                        " • source=${sourceFps?.toInt()}fps"
                )
            }
            if (cadenceChanged) {
                listener.onDiagnostic(
                    "Sustainable video cadence → ${cadenceGovernor.cap}fps ceiling • preserving screen geometry"
                )
            }
            if (motionChanged) {
                listener.onDiagnostic(
                    if (freshnessPriorityActive(now)) {
                        "Visible screen motion → freshness-first video policy"
                    } else {
                        "Visible screen motion settled → gradual detail recovery"
                    }
                )
            }

            // Preserve the existing recovery/governor timing despite 1s sampling.
            if (now - lastSlowVideoCheckMs < 3000) return@post
            lastSlowVideoCheckMs = now
            listener.onDiagnostic(snapshot.compact())
            listener.onDiagnostic("Video delivery • source=${sourceFps?.toInt()}fps target=${effectiveCaptureProfile(profile).fps}fps decode=${receiver?.fps?.toInt()}fps present=${receiver?.presentedFps?.toInt()}fps gap=${receiver?.maxRenderGapMs}ms")

            // One resolution owner during motion: do not simultaneously lower
            // the legacy quality tier and the motion pixel budget.
            if (motionActive) return@post

            val sender = snapshot.recent
            val effectiveRequestedFps = effectiveCaptureProfile(profile).fps
            val localPipelinePressure =
                sender?.let {
                    captureQualityGovernor.hasLocalPipelinePressure(
                        encodeTimeMs = it.processingMs,
                        sendQueueMs = it.sendQueueMs,
                        deliveredFps = it.fps,
                        requestedFps = effectiveRequestedFps
                    )
                } ?: false
            val pressured =
                snapshot.qualityLimitationReason == "cpu" ||
                    (snapshot.packetLossRatio ?: 0.0) >=
                        CaptureQualityGovernor.PRESSURE_PACKET_LOSS_RATIO ||
                    (snapshot.roundTripTimeMs ?: 0) >=
                        CaptureQualityGovernor.PRESSURE_RTT_MS ||
                    localPipelinePressure

            // Cadence is the cheaper freshness lever. Reduce resolution only
            // after cadence relief has had a bounded opportunity to drain the
            // encoder/pacer queue.
            if (
                pressured &&
                !cadenceGovernor.mayReduceResolution(now)
            ) {
                return@post
            }

            captureQualityGovernor
                .observeQualityLimitation(
                    reason = snapshot.qualityLimitationReason,
                    roundTripTimeMs = snapshot.roundTripTimeMs,
                    packetLossRatio = snapshot.packetLossRatio,
                    encodeTimeMs = sender?.processingMs,
                    sendQueueMs = sender?.sendQueueMs,
                    deliveredFps = sender?.fps,
                    requestedFps = effectiveRequestedFps
                )
                ?.let(::applyCaptureTier)
        }
    }

    private fun noteRemoteInteraction() {
        if (closed.get()) return

        if (interactionActive) {
            refreshInteractionPriorityTimeout()
        } else {
            updateInteractionPriority(true)
        }
    }

    private fun updateInteractionPriority(active: Boolean) {
        displayHandler.removeCallbacks(interactionPriorityTimeout)
        fallbackStreamer.setInteractionActive(active)

        if (interactionActive != active) {
            val wasFreshnessActive = freshnessPriorityActive()
            interactionActive = active
            if (active) {
                val now = android.os.SystemClock.elapsedRealtime()
                if (!wasFreshnessActive) {
                    tryRecoverCadenceOnNewMotion(now)
                }
                if (motionVideoBudget.primeForMotion(profile, now)) {
                    val effective = effectiveCaptureProfile(profile)
                    listener.onDiagnostic(
                        "Remote interaction warm-start → " +
                            effective.captureWidthPx +
                            "x" +
                            effective.captureHeightPx +
                            "@" +
                            effective.fps
                    )
                }
            }
            applyVideoPolicy(profile)
            val freshnessActive = freshnessPriorityActive()
            val policy =
                InteractiveVideoPolicy.forState(
                    tier = profile.tier,
                    interactionActive = freshnessActive
                )
            listener.onDiagnostic(
                when {
                    !active && freshnessActive ->
                        "Remote interaction ended • visible motion remains freshness-first"
                    !active ->
                        "Remote interaction ended • native motion adaptation remains enabled"
                    policy.motionPriority ->
                        "Remote interaction active • prioritizing fresh motion frames"
                    else ->
                        "Remote interaction active • balancing motion smoothness and screen clarity"
                }
            )
        }

        if (active) {
            refreshInteractionPriorityTimeout()
        }
    }

    private fun refreshInteractionPriorityTimeout() {
        if (closed.get() || !interactionActive) return

        displayHandler.removeCallbacks(interactionPriorityTimeout)
        displayHandler.postDelayed(
            interactionPriorityTimeout,
            INTERACTION_PRIORITY_TIMEOUT_MS
        )
    }

    private fun freshnessPriorityActive(
        nowMs: Long = android.os.SystemClock.elapsedRealtime()
    ): Boolean =
        interactionActive ||
            passiveMotionPriority.isActive(nowMs)

    private fun tryRecoverCadenceOnNewMotion(nowMs: Long): Boolean {
        val recovered = cadenceGovernor.tryProbeAfterQuiet(
            outbound = lastQuietOutbound,
            producerFps = lastQuietSourceFps,
            telemetryAtMs = lastQuietSampleAtMs,
            nowMs = nowMs
        )
        // Consume the evidence once. A later touch must not repeatedly borrow
        // a quiet sample from before the previous animation.
        lastQuietOutbound = null
        lastQuietSourceFps = null

        if (recovered) {
            listener.onDiagnostic(
                "Fresh motion • quiet-path FPS probe → ${cadenceGovernor.cap}fps ceiling"
            )
        }
        return recovered
    }

    private fun handleSourceMotionPulse() {
        if (closed.get()) return

        val now = android.os.SystemClock.elapsedRealtime()
        val motionChanged = passiveMotionPriority.pulse(now)
        val cadenceChanged =
            if (motionChanged) tryRecoverCadenceOnNewMotion(now) else false
        val budgetChanged = motionVideoBudget.primeForMotion(profile, now)

        if (motionChanged || budgetChanged || cadenceChanged) {
            applyVideoPolicy(profile)
        }

        if (budgetChanged) {
            val effective = effectiveCaptureProfile(profile)
            listener.onDiagnostic(
                "Source motion warm-start → " +
                    effective.captureWidthPx +
                    "x" +
                    effective.captureHeightPx +
                    "@" +
                    effective.fps +
                    " • newest frames first"
            )
        } else if (motionChanged) {
            listener.onDiagnostic(
                "Source motion → freshness-first video policy before stats"
            )
        }
    }

    private fun effectiveCaptureProfile(
        target: CaptureProfile
    ): CaptureProfile {
        val freshnessActive = freshnessPriorityActive()
        val targetFps =
            minOf(
                cadenceGovernor.cap,
                if (freshnessActive) {
                    target.motionFps
                } else {
                    target.fps
                }
            )

        val paced = if (targetFps == target.fps) {
            target
        } else {
            target.copy(fps = targetFps)
        }
        return motionVideoBudget.apply(paced, freshnessActive)
    }

    private fun applyVideoPolicy(target: CaptureProfile) {
        val freshnessActive = freshnessPriorityActive()
        val policy =
            InteractiveVideoPolicy.forState(
                tier = target.tier,
                interactionActive = freshnessActive
            )
        val effective = effectiveCaptureProfile(target)

        // Apply cadence in VideoSource. FPS/bandwidth changes keep the actual
        // Android capture surface stable; only display geometry may resize it.
        capture.update(effective)
        peer.updateInteractiveVideoPolicy(
            maxBitrateBps =
                motionVideoBudget.bitrateCeiling(
                    profile = target,
                    motionActive = freshnessActive
                ),
            maxFramerate = effective.fps,
            preserveResolution = policy.preserveResolution,
            motionPriority = policy.motionPriority
        )
    }

    override fun onDiagnostic(message: String) {
        listener.onDiagnostic(message)
    }

    override fun onError(error: Throwable) {
        listener.onRecoverableError(error)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.removeCallbacks(iceRestart)
        displayHandler.removeCallbacks(startupControlRecovery)
        displayHandler.removeCallbacks(captureFrameWatchdog)
        displayHandler.removeCallbacks(interactionPriorityTimeout)
        displayHandler.removeCallbacks(
            leaseWatchdog
        )
        runCatching {
            displayManager.unregisterDisplayListener(displayListener)
        }
        runCatching {
            capture.videoTrack.removeSink(captureProbe)
        }
        runCatching { fallbackStreamer.close() }
        runCatching { peer.close() }
        runCatching { capture.close() }

        peerConnected = false
        everConnected = false
        controlOpen = false
        transportReady = false
        interactionActive = false
        passiveMotionPriority.reset()
        lease = null
    }

    @Synchronized
    private fun ensureLiveHandshake() {
        if (
            !peerConnected ||
            !controlOpen ||
            !localCaptureFrameSeen.get() ||
            closed.get() ||
            transportReady
        ) {
            return
        }

        if (!AssistAccessibilityService.isConnected()) {
            listener.onLocalControlUnavailable()
            return
        }

        displayHandler.removeCallbacks(startupControlRecovery)

        val firstLive = lease == null
        val currentLease = runCatching {
            SessionCoordinator.activateLive(sessionId)
        }.getOrElse {
            listener.onTerminalError(it)
            return
        }

        displayHandler.removeCallbacks(connectionWatchdog)
        transportReady = true
        lease = currentLease

        displayHandler.removeCallbacks(
            leaseWatchdog
        )
        displayHandler.postDelayed(
            leaseWatchdog,
            LEASE_WATCHDOG_MS
        )

        if (firstLive) {
            listener.onDiagnostic(
                "Host prerequisites complete: WebRTC + control + capture + Accessibility"
            )
            listener.onLive()
        }

        sendHello(currentLease, profile)
        listener.onDiagnostic("HELLO sent to controller")
    }

    private fun sendHello(
        lease: LiveLease,
        profile: CaptureProfile
    ) {
        peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Hello(
                    leaseSecret = lease.leaseSecret,
                    generation = lease.displayGeneration,
                    widthPx = profile.displayWidthPx,
                    heightPx = profile.displayHeightPx
                )
            )
        )
    }
    companion object {
        private const val CONNECT_TIMEOUT_MS = 90_000L
        private const val CONTROL_CHANNEL_GRACE_MS = 5_000L
        private const val ICE_RESTART_DELAY_MS = 1_500L
        private const val STARTUP_CONTROL_RECOVERY_INITIAL_DELAY_MS = 8_000L
        private const val STARTUP_CONTROL_RECOVERY_INTERVAL_MS = 8_000L
        private const val MAX_STARTUP_CONTROL_RECOVERY_ATTEMPTS = 2
        private const val CAPTURE_FIRST_FRAME_TIMEOUT_MS = 12_000L
        private const val CAPTURE_RECOVERY_INTERVAL_MS = 8_000L
        private const val MAX_CAPTURE_RECOVERY_ATTEMPTS = 3
        private const val LEASE_WATCHDOG_MS = 3_000L
        private const val INTERACTION_PRIORITY_TIMEOUT_MS = 3_000L
        private const val MAX_SESSION_VIDEO_FPS = 30
    }
}
