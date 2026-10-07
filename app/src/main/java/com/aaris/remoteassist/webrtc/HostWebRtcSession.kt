package com.aaris.remoteassist.webrtc

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.HandlerThread
import android.os.Looper
import android.os.Build
import android.os.PowerManager
import android.os.Process
import android.view.Display
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureQualityGovernor
import com.aaris.remoteassist.capture.CaptureTier
import com.aaris.remoteassist.capture.InteractionRefreshTiming
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
    private val listener: Listener,
    private val browserLink: Boolean = false
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

    /*
     * Adaptive policy/recovery is latency-sensitive orchestration, but it must
     * never compete with Android UI/input callbacks. WebRTC already owns its
     * native network/worker/signaling queues; this lightweight serial lane owns
     * only our product policy state and emits tiny actuator updates.
     */
    private val policyThread =
        HandlerThread(
            "AarisRemotePolicy",
            Process.THREAD_PRIORITY_MORE_FAVORABLE
        ).apply { start() }
    private val policyHandler = Handler(policyThread.looper)

    private val powerManager = appContext.getSystemService(PowerManager::class.java)
    private var deviceFpsLimit = MAX_SESSION_VIDEO_FPS

    private val recommendedCaptureTier =
        CaptureProfile.recommendedTier(appContext)

    /*
     * Memory size does not guarantee realtime codec throughput. Only count
     * hardware codecs that ScreenCodecPolicy can actually negotiate as the
     * primary screen format; unrelated hardware codecs must not unlock an
     * aggressive capture bootstrap.
     */
    private val hardwareRealtimeEncoderAvailable =
        WebRtcRuntime.hardwareScreenEncoders(appContext).any { codec ->
            codec.equals("H264", ignoreCase = true) ||
                codec.equals("VP8", ignoreCase = true)
        }

    private val maxCaptureTier =
        CaptureProfile.capForEncoderAcceleration(
            recommendedTier = recommendedCaptureTier,
            hardwareRealtimeEncoderAvailable =
                hardwareRealtimeEncoderAvailable
        )

    @Volatile
    private var captureTier = maxCaptureTier

    @Volatile
    private var profile =
        CaptureProfile.current(appContext, captureTier)

    /*
     * One app-level authority owns resolution + cadence + bitrate ceiling.
     * WebRTC/GCC remains the transport/rate-control authority underneath it.
     */
    private val mediaController =
        UnifiedMediaController(
            initialProfile = profile,
            maxFps = MAX_SESSION_VIDEO_FPS
        )
    private val receiverFeedback = ReceiverVideoFeedback()
    private var controllerRefreshRateHz: Double? = null
    private var lastSlowVideoCheckMs = 0L

    /*
     * Policy-lane snapshot of the source shape that is already admitted to the
     * media pipeline. Startup seeds it after the sender envelope is configured;
     * subsequent transitions use it only to choose safe actuator ordering.
     */
    private var lastAppliedCaptureWidthPx = 0
    private var lastAppliedCaptureHeightPx = 0
    private var lastAppliedCaptureFps = 0

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
            // Route every transition through one state owner so capture-thread
            // scheduling, fallback policy and RTP policy cannot drift apart.
            updateInteractionPriority(false)
        }
    }

    /*
     * Single-flight post-input capture probe. The first applied command owns the
     * next display-tick deadline; later samples must never push that deadline
     * forward. This is a throttle, not a debounce: a long 60/120 Hz gesture
     * cannot starve forced freshness on OEMs whose MediaProjection producer is
     * temporarily sparse.
     *
     * CaptureRefreshPolicy still cancels the pull when a natural frame arrived,
     * so this adds no duplicate encoder path and keeps at most one scheduled
     * probe on the main looper.
     */
    private val interactionRefreshProbeScheduled = AtomicBoolean(false)
    private val interactionRefreshProbe = Runnable {
        interactionRefreshProbeScheduled.set(false)
        if (!closed.get()) {
            capture.requestInteractionRefresh()
        }
    }

    private var startupControlRecoveryAttempts = 0
    private var captureRecoveryAttempts = 0
    private val localCaptureFrameSeen = AtomicBoolean(false)

    @Volatile
    private var lease: LiveLease? = null

    private val transport = ControlTransportTracker()

    private fun createPeer() = WebRtcPeer(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.HOST,
        signaling = CloudflareSignalingClient(appContext, sessionId, PeerRole.HOST),
        listener = this
    )
    @Volatile private var peer = createPeer()
    private val peerSwapLock = Any()
    private var browserEpoch = 0L
    private var browserOfflineAtMs = 0L

    private val capture = ScreenCaptureTrack(
        context = appContext,
        grant = projectionGrant,
        onProjectionStopped = listener::onProjectionStopped,
        onSourceMotion = {
            /*
             * Source activity no longer changes FPS/resolution by itself.
             * MediaProjection may go quiet for a moment during scrolling or app
             * transitions; the unified controller reacts only to measured
             * pipeline/network pressure, not motion/idle edges.
             */
        },
        onSourceGeometryChanged = { observedWidth, observedHeight ->
            /*
             * Fullscreen games can rotate MediaProjection before some OEMs
             * deliver DisplayManager.onDisplayChanged(). Use only an aspect
             * transition as a self-heal trigger; the UI/display lane remains
             * the sole owner that reads CaptureProfile and bumps generation.
             */
            val current = profile
            val observedLandscape = observedWidth > observedHeight
            val logicalLandscape =
                current.displayWidthPx > current.displayHeightPx
            if (observedLandscape != logicalLandscape) {
                displayHandler.post {
                    if (!closed.get()) {
                        refreshDisplayProfile()
                    }
                }
            }
        }
    )

    private val fallbackStreamer =
        FallbackScreenStreamer(
            capture = capture,
            sendPacket = { peer.sendFallbackVideo(it) },
            onDiagnostic = listener::onDiagnostic,
            canStartFrame = { peer.canStartFallbackFrame() },
            requestFreshFrame = capture::requestSnapshot
        )

    private val captureProbe = VideoSink {
        if (localCaptureFrameSeen.compareAndSet(false, true)) {
            listener.onDiagnostic("MediaProjection produced first capture frame")
            displayHandler.removeCallbacks(captureFrameWatchdog)
            displayHandler.post {
                if (!closed.get()) {
                    /*
                     * This sink exists only to prove startup capture. Leaving it
                     * attached forever adds a useless VideoTrack fan-out on every
                     * steady-state frame.
                     */
                    detachStartupCaptureProbe()
                    ensureLiveHandshake()
                }
            }
        }
    }

    private fun detachStartupCaptureProbe() {
        runCatching {
            capture.videoTrack.removeSink(captureProbe)
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
            (!peerConnected || !controlOpen || (browserLink && !transportReady))
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
                if (browserLink) {
                    // Lease expiry disables gestures immediately. Keep the single
                    // projection alive for a bounded browser reconnect window.
                    waitForBrowser()
                    return
                }
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

    /*
     * Some fullscreen games/OEMs coalesce or delay display callbacks while
     * immersive mode owns the screen. A cheap logical-geometry poll is the
     * backstop: identical profiles are a no-op, so steady-state work is just
     * one metrics read per interval. This avoids a permanent portrait capture
     * surface after a missed 90-degree rotation.
     */
    private val displayGeometryWatchdog =
        object : Runnable {
            override fun run() {
                if (closed.get()) return
                refreshDisplayProfile()
                displayHandler.postDelayed(
                    this,
                    DISPLAY_GEOMETRY_WATCHDOG_MS
                )
            }
        }

    fun start() {
        check(!closed.get())

        displayManager.registerDisplayListener(
            displayListener,
            displayHandler
        )
        displayHandler.removeCallbacks(
            displayGeometryWatchdog
        )
        displayHandler.postDelayed(
            displayGeometryWatchdog,
            DISPLAY_GEOMETRY_WATCHDOG_MS
        )

        captureRecoveryAttempts = 0
        localCaptureFrameSeen.set(false)

        val initialEffective = effectiveCaptureProfile(profile)
        if (maxCaptureTier != recommendedCaptureTier) {
            listener.onDiagnostic(
                "Realtime video bootstrap → " +
                    maxCaptureTier.name +
                    " • no H264/VP8 hardware encoder"
            )
        }
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
        /*
         * The sender is already primed above. Seed the transition snapshot
         * before capture starts so even an immediate source-motion callback
         * sees the correct baseline on the policy lane.
         */
        lastAppliedCaptureWidthPx = initialEffective.captureWidthPx
        lastAppliedCaptureHeightPx = initialEffective.captureHeightPx
        lastAppliedCaptureFps = initialEffective.fps
        capture.start(initialEffective)

        displayHandler.removeCallbacks(captureFrameWatchdog)
        displayHandler.postDelayed(
            captureFrameWatchdog,
            CAPTURE_FIRST_FRAME_TIMEOUT_MS
        )

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.postDelayed(
            connectionWatchdog,
            if (browserLink) BROWSER_CONNECT_TIMEOUT_MS else CONNECT_TIMEOUT_MS
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
        policyHandler.post {
            if (!closed.get()) {
                // Read the newest profile at execution time so rapid rotation /
                // display callbacks coalesce instead of replaying stale policy.
                applyVideoPolicy(profile)
            }
        }

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
        policyHandler.post {
            mediaController.resetEvidence()
            updateInteractionPriority(false)
        }
        displayHandler.removeCallbacks(startupControlRecovery)
        transport.onPeerDisconnected()
            ?.let(listener::onConnectivityChanged)

        if (browserLink && everConnected) displayHandler.post { waitForBrowser() }

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
        policyHandler.post {
            mediaController.resetEvidence()
            updateInteractionPriority(false)
        }
        transport.onControlChannelClosed()
            ?.let(listener::onConnectivityChanged)
        if (!closed.get()) {
            if (browserLink && everConnected) {
                displayHandler.post { waitForBrowser() }
                return
            }
            displayHandler.removeCallbacks(connectionWatchdog)
            displayHandler.postDelayed(
                connectionWatchdog,
                CONTROL_CHANNEL_GRACE_MS
            )
        }
    }

    override fun onControlMessage(bytes: ByteArray) {
        val packet = ControlProtocol.decode(bytes) ?: return

        if (browserLink && (!transportReady || browserOfflineAtMs != 0L)) {
            if (packet is ControlPacket.Heartbeat && packet.leaseSecret == lease?.leaseSecret && peerConnected && controlOpen) {
                displayHandler.post { ensureLiveHandshake() }
            }
            return
        }

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
                policyHandler.post {
                    updateInteractionPriority(false)
                }
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

                val commandPeer = peer
                AssistAccessibilityService.dispatch(command) { applied ->
                    // An asynchronous gesture from the previous browser must
                    // never ACK a recycled sequence number on its replacement.
                    if (browserLink && (closed.get() || peer !== commandPeer ||
                        !SessionRuntime.isAuthorized(sessionId, command.leaseSecret, command.generation))) return@dispatch
                    if (applied) {
                        /*
                         * Arm a causal refresh at the exact applied-input point.
                         * A natural MediaProjection frame after this moment
                         * cancels the pull. Otherwise one display tick later we
                         * sample the current texture. Rapid gestures coalesce
                         * into one pending probe instead of creating a queue.
                         */
                        val appliedAtMs =
                            android.os.SystemClock.elapsedRealtime()
                        capture.armInteractionRefresh(appliedAtMs)
                        if (
                            interactionRefreshProbeScheduled
                                .compareAndSet(false, true)
                        ) {
                            displayHandler.postDelayed(
                                interactionRefreshProbe,
                                interactionRefreshDelayMs()
                            )
                        }
                    }

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

                policyHandler.post {
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

            is ControlPacket.VideoFeedback -> policyHandler.post {
                val current = lease
                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {
                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())
                }
            }
            is ControlPacket.PresentationFeedback -> policyHandler.post {
                val current = lease
                val now =
                    android.os.SystemClock.elapsedRealtime()
                if (
                    !closed.get() &&
                    current != null &&
                    SessionRuntime.isAuthorized(
                        sessionId,
                        current.leaseSecret,
                        current.displayGeneration
                    )
                ) {
                    /*
                     * Presentation feedback is evidence only. It is consumed by
                     * the next unified media sample with sender/network/decoder
                     * state; it never owns an independent FPS brake.
                     */
                    receiverFeedback.accept(
                        packet,
                        current.leaseSecret,
                        current.displayGeneration,
                        now
                    )
                }
            }
            is ControlPacket.PresentationHeartbeat -> policyHandler.post {
                val current = lease
                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {
                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())
                }
            }
            is ControlPacket.DisplayCapabilities -> policyHandler.post {
                val current = lease
                if (!closed.get() && current != null && SessionRuntime.isAuthorized(sessionId, current.leaseSecret, current.displayGeneration)) {
                    receiverFeedback.accept(packet, current.leaseSecret, current.displayGeneration, android.os.SystemClock.elapsedRealtime())
                }
            }
            is ControlPacket.PhotonFeedback -> policyHandler.post {
                val current = lease
                if (
                    !closed.get() &&
                    current != null &&
                    SessionRuntime.isAuthorized(
                        sessionId,
                        current.leaseSecret,
                        current.displayGeneration
                    )
                ) {
                    receiverFeedback.accept(
                        packet,
                        current.leaseSecret,
                        current.displayGeneration,
                        android.os.SystemClock.elapsedRealtime()
                    )
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
        policyHandler.post {
            handleMediaRecoveryRequestOnPolicy()
        }
    }

    private fun handleMediaRecoveryRequestOnPolicy() {
        if (closed.get()) return
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

    override fun onVideoHealth(
        snapshot: VideoHealthSnapshot
    ) {
        if (snapshot.direction != "outbound") return

        policyHandler.post {
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
            val previousDeviceLimit = deviceFpsLimit
            val previousRefresh = controllerRefreshRateHz

            deviceFpsLimit =
                when {
                    Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q &&
                        (powerManager?.currentThermalStatus ?: 0) >=
                        PowerManager.THERMAL_STATUS_SEVERE -> 24
                    powerManager?.isPowerSaveMode == true -> 30
                    else -> MAX_SESSION_VIDEO_FPS
                }

            controllerRefreshRateHz =
                receiver
                    ?.displayRefreshRateHz
                    ?.takeIf { it.isFinite() && it > 0.0 }
                    ?: controllerRefreshRateHz

            val mediaChanged =
                mediaController.observe(
                    profile = profile,
                    outbound = snapshot,
                    receiver = receiver,
                    sourceFps = sourceFps,
                    interactionActive = interactionActive,
                    deviceFpsLimit = deviceFpsLimit,
                    displayRefreshRateHz = controllerRefreshRateHz,
                    nowMs = now
                )

            if (
                mediaChanged ||
                previousDeviceLimit != deviceFpsLimit ||
                previousRefresh != controllerRefreshRateHz
            ) {
                applyVideoPolicy(profile)
            }

            if (now - lastSlowVideoCheckMs < 3_000L) {
                return@post
            }
            lastSlowVideoCheckMs = now

            val effective = effectiveCaptureProfile(profile)
            listener.onDiagnostic(snapshot.compact())
            listener.onDiagnostic(
                "Video delivery • source=" +
                    (sourceFps?.toInt() ?: -1) +
                    "fps target=" +
                    effective.fps +
                    "fps decode=" +
                    (receiver?.fps?.toInt() ?: -1) +
                    "fps present=" +
                    (receiver?.presentedFps?.toInt() ?: -1) +
                    "fps gap=" +
                    (receiver?.maxRenderGapMs ?: -1) +
                    "ms display=" +
                    (controllerRefreshRateHz?.toInt() ?: -1) +
                    "Hz"
            )
            listener.onDiagnostic(
                "QD|MEDIA|" +
                    mediaController.debugSummary(
                        profile = profile,
                        deviceFpsLimit = deviceFpsLimit,
                        displayRefreshRateHz = controllerRefreshRateHz,
                        nowMs = now
                    )
            )
        }
    }

    private fun noteRemoteInteraction() {
        if (closed.get()) return

        policyHandler.post {
            if (closed.get()) return@post
            if (interactionActive) {
                refreshInteractionPriorityTimeout()
            } else {
                updateInteractionPriority(true)
            }
        }
    }

    private fun updateInteractionPriority(active: Boolean) {
        policyHandler.removeCallbacks(interactionPriorityTimeout)
        fallbackStreamer.setInteractionActive(active)

        if (interactionActive != active) {
            interactionActive = active
            capture.setInteractionPriority(active)

            /*
             * Touch changes scheduling priority, not the media operating point.
             * This prevents finger-down/finger-up edges from repeatedly
             * reconfiguring MediaCodec dimensions or FPS.
             */
            listener.onDiagnostic(
                if (active) {
                    "Remote interaction active • media point held stable"
                } else {
                    "Remote interaction ended • media point unchanged"
                }
            )
        }

        if (active) {
            refreshInteractionPriorityTimeout()
        }
    }

    private fun refreshInteractionPriorityTimeout() {
        if (closed.get() || !interactionActive) return

        policyHandler.removeCallbacks(interactionPriorityTimeout)
        policyHandler.postDelayed(
            interactionPriorityTimeout,
            INTERACTION_PRIORITY_TIMEOUT_MS
        )
    }

    @Suppress("DEPRECATION")
    private fun interactionRefreshDelayMs(): Long {
        val refreshRate =
            runCatching {
                displayManager
                    .getDisplay(Display.DEFAULT_DISPLAY)
                    ?.mode
                    ?.refreshRate
            }.getOrNull()

        return InteractionRefreshTiming.oneDisplayTickMs(
            refreshRate
        )
    }

    private fun effectiveCaptureProfile(
        target: CaptureProfile
    ): CaptureProfile =
        mediaController.effectiveProfile(
            profile = target,
            deviceFpsLimit = deviceFpsLimit,
            displayRefreshRateHz = controllerRefreshRateHz
        )

    private fun applyVideoPolicy(target: CaptureProfile) {
        val policy =
            InteractiveVideoPolicy.forState(
                tier = target.tier,
                interactionActive = interactionActive
            )
        val effective = effectiveCaptureProfile(target)

        /*
         * Keep one steady telemetry clock. Sampling is frequent, but the master
         * controller's dwell/hysteresis prevents frequent media reconfiguration.
         */
        peer.setRealtimeVideoTelemetry(true)

        val maxBitrateBps =
            mediaController.bitrateCeiling(
                profile = target,
                deviceFpsLimit = deviceFpsLimit,
                displayRefreshRateHz = controllerRefreshRateHz
            )
        val senderFirst =
            RealtimeMediaPolicy.senderBeforeCaptureForTransition(
                previousWidthPx = lastAppliedCaptureWidthPx,
                previousHeightPx = lastAppliedCaptureHeightPx,
                previousFps = lastAppliedCaptureFps,
                nextWidthPx = effective.captureWidthPx,
                nextHeightPx = effective.captureHeightPx,
                nextFps = effective.fps
            )
        val probeRiskyUpshift =
            RealtimeMediaPolicy.shouldKickVideoStatsAfterTransition(
                previousWidthPx = lastAppliedCaptureWidthPx,
                previousHeightPx = lastAppliedCaptureHeightPx,
                previousFps = lastAppliedCaptureFps,
                nextWidthPx = effective.captureWidthPx,
                nextHeightPx = effective.captureHeightPx,
                nextFps = effective.fps
            )

        if (senderFirst) {
            peer.updateInteractiveVideoPolicy(
                maxBitrateBps = maxBitrateBps,
                maxFramerate = effective.fps,
                preserveResolution = policy.preserveResolution,
                motionPriority = policy.motionPriority
            )
            capture.update(effective)
        } else {
            capture.update(effective)
            peer.updateInteractiveVideoPolicy(
                maxBitrateBps = maxBitrateBps,
                maxFramerate = effective.fps,
                preserveResolution = policy.preserveResolution,
                motionPriority = policy.motionPriority
            )
        }

        lastAppliedCaptureWidthPx = effective.captureWidthPx
        lastAppliedCaptureHeightPx = effective.captureHeightPx
        lastAppliedCaptureFps = effective.fps

        if (probeRiskyUpshift) {
            peer.requestVideoHealthProbe()
        }
    }

    override fun onDiagnostic(message: String) {
        listener.onDiagnostic(message)
    }

    override fun onError(error: Throwable) {
        listener.onRecoverableError(error)
    }

    private fun waitForBrowser() {
        if (closed.get() || !browserLink) return
        if (browserOfflineAtMs == 0L) {
            browserOfflineAtMs = android.os.SystemClock.elapsedRealtime()
            SessionRuntime.reset()
            transportReady = false
            displayHandler.removeCallbacks(connectionWatchdog)
            displayHandler.postDelayed(connectionWatchdog, BROWSER_RECONNECT_GRACE_MS)
            listener.onDiagnostic("Browser offline • control paused • waiting up to 60 seconds")
        }
    }

    override fun onBrowserControllerAttached(epoch: Long) {
        displayHandler.post {
            if (!browserLink || closed.get() || epoch <= browserEpoch) return@post
            browserEpoch = epoch
            SessionRuntime.reset()
            transportReady = false
            controlOpen = false
            peerConnected = false
            browserOfflineAtMs = 0L
            // Recreate only transport. Never consume the projection grant twice
            // or allocate another capture/encoder pipeline on browser refresh.
            policyHandler.post replaceTransport@{
                synchronized(peerSwapLock) {
                    if (closed.get()) return@replaceTransport
                    peer.close()
                    if (closed.get()) return@replaceTransport
                    peer = createPeer()
                    val effective = effectiveCaptureProfile(profile)
                    val policy = InteractiveVideoPolicy.forState(profile.tier, false)
                    peer.addLocalVideoTrack(capture.videoTrack, profile.maxVideoBitrateBps, effective.fps,
                        policy.preserveResolution, policy.motionPriority)
                    peer.start()
                }
                displayHandler.post {
                    if (!closed.get()) {
                        displayHandler.removeCallbacks(connectionWatchdog)
                        displayHandler.postDelayed(connectionWatchdog, BROWSER_RECONNECT_GRACE_MS)
                    }
                }
            }
        }
    }

    override fun onRemoteSessionClosed() { listener.onRemoteDisconnect() }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.removeCallbacks(iceRestart)
        displayHandler.removeCallbacks(startupControlRecovery)
        displayHandler.removeCallbacks(captureFrameWatchdog)
        displayHandler.removeCallbacks(displayGeometryWatchdog)
        displayHandler.removeCallbacks(interactionRefreshProbe)
        interactionRefreshProbeScheduled.set(false)
        displayHandler.removeCallbacks(
            leaseWatchdog
        )
        policyHandler.removeCallbacksAndMessages(null)
        runCatching {
            displayManager.unregisterDisplayListener(displayListener)
        }
        runCatching {
            capture.videoTrack.removeSink(captureProbe)
        }
        runCatching { fallbackStreamer.close() }
        synchronized(peerSwapLock) { runCatching { peer.close() } }
        runCatching { capture.close() }
        runCatching { policyThread.quitSafely() }

        peerConnected = false
        everConnected = false
        controlOpen = false
        transportReady = false
        interactionActive = false
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
        browserOfflineAtMs = 0L
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
        private const val BROWSER_CONNECT_TIMEOUT_MS = 300_000L
        private const val BROWSER_RECONNECT_GRACE_MS = 60_000L
        private const val CONTROL_CHANNEL_GRACE_MS = 5_000L
        private const val DISPLAY_GEOMETRY_WATCHDOG_MS = 750L
        private const val ICE_RESTART_DELAY_MS = 1_500L
        private const val STARTUP_CONTROL_RECOVERY_INITIAL_DELAY_MS = 8_000L
        private const val STARTUP_CONTROL_RECOVERY_INTERVAL_MS = 8_000L
        private const val MAX_STARTUP_CONTROL_RECOVERY_ATTEMPTS = 2
        private const val CAPTURE_FIRST_FRAME_TIMEOUT_MS = 12_000L
        private const val CAPTURE_RECOVERY_INTERVAL_MS = 8_000L
        private const val MAX_CAPTURE_RECOVERY_ATTEMPTS = 3
        private const val LEASE_WATCHDOG_MS = 3_000L
        private const val INTERACTION_PRIORITY_TIMEOUT_MS = 3_000L
        private const val MAX_WARM_START_EVIDENCE_AGE_MS = 2_500L
        private const val MAX_SESSION_VIDEO_FPS = 60
        private const val PRESENTATION_HEARTBEAT_FRESH_MS = 1_500
    }
}
