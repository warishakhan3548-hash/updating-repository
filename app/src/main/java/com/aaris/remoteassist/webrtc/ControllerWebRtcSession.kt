package com.aaris.remoteassist.webrtc

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.control.CommandLatencyTracker
import com.aaris.remoteassist.control.InputToGlassTracker
import android.os.SystemClock
import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlPathPoint
import com.aaris.remoteassist.control.ControlProtocol
import android.view.Display
import org.webrtc.VideoTrack
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong

data class RemoteGeometry(
    val generation: Int,
    val widthPx: Int,
    val heightPx: Int
)

class ControllerWebRtcSession(
    context: Context,
    private val sessionId: String,
    private val listener: Listener
) : Closeable, WebRtcPeer.Listener {
    interface Listener {
        fun onLive(geometry: RemoteGeometry)
        fun onConnectivityChanged(connected: Boolean)
        fun onRemoteVideoTrack(track: VideoTrack)
        fun onFallbackVideoFrame(frame: FallbackVideoFrame) = Unit
        fun onFallbackDeltaFrame(frame: FallbackDeltaFrame) = Unit
        fun onPrimaryVideoRecoveryStarted() = Unit
        fun onCommandResult(sequence: Long, applied: Boolean)
        fun onDiagnostic(message: String) = Unit
        fun onRecoverableError(error: Throwable)
        fun onTerminalError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val started = AtomicBoolean(false)
    private val screenReadyArmed = AtomicBoolean(false)
    private val sequence = AtomicLong(0L)
    private val commandLatency = CommandLatencyTracker()
    private val inputToGlass = InputToGlassTracker()
    private var lastLatencyReportMs = 0L
    private var lastPhotonReportMs = 0L
    private val feedbackSequence = AtomicLong(0L)
    private var lastVideoLivenessMs = 0L
    private val gestureStreamIds = AtomicLong(0L)
    private val handler = Handler(Looper.getMainLooper())
    private val displayManager =
        appContext.getSystemService(DisplayManager::class.java)
    @Volatile
    private var lastPublishedDisplayRefreshRateHz: Float? = null

    private val displayRefreshUpdate =
        Runnable {
            if (closed.get()) return@Runnable
            val refresh = currentDisplayRefreshRateHz() ?: return@Runnable
            val previous = lastPublishedDisplayRefreshRateHz
            if (
                previous == null ||
                kotlin.math.abs(refresh - previous) >=
                    DISPLAY_REFRESH_CHANGE_EPSILON_HZ
            ) {
                publishDisplayCapabilities(refresh)
            }
        }

    private val displayListener =
        object : DisplayManager.DisplayListener {
            override fun onDisplayAdded(displayId: Int) = Unit

            override fun onDisplayRemoved(displayId: Int) = Unit

            override fun onDisplayChanged(displayId: Int) {
                if (
                    displayId == Display.DEFAULT_DISPLAY &&
                    !closed.get()
                ) {
                    /*
                     * Surface.setFrameRate(), power policy, or adaptive-refresh
                     * policy can move the active clock. Display callbacks may
                     * arrive in bursts, so coalesce them and only publish a
                     * materially different rate. The heartbeat remains the
                     * periodic freshness signal even when the rate is stable.
                     */
                    handler.removeCallbacks(displayRefreshUpdate)
                    handler.postDelayed(
                        displayRefreshUpdate,
                        DISPLAY_REFRESH_SETTLE_MS
                    )
                }
            }
        }
    private val transport = ControlTransportTracker()
    private val inboundVideoLiveness =
        InboundVideoLivenessMonitor()

    @Volatile
    private var leaseSecret: Long? = null

    @Volatile
    private var geometry: RemoteGeometry? = null

    @Volatile
    private var interactionActive = false

    /*
     * Local receiver telemetry has a second, presentation-driven demand.
     * A fling/video/game may keep moving long after the remote finger lifts;
     * that must not masquerade as an active input gesture on the host, but the
     * controller should still sample decoder/jitter health at realtime cadence.
     */
    @Volatile
    private var presentationMotionActive = false

    private val signaling = CloudflareSignalingClient(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.CONTROLLER
    )

    private val peer = WebRtcPeer(
        context = appContext,
        sessionId = sessionId,
        role = PeerRole.CONTROLLER,
        signaling = signaling,
        listener = this
    )

    private val helloWatchdog = Runnable {
        if (!closed.get() && leaseSecret == null) {
            listener.onTerminalError(
                IllegalStateException(
                    "Remote control handshake timed out"
                )
            )
        }
    }

    private val heartbeat = object : Runnable {
        override fun run() {
            if (closed.get()) return

            val lease = leaseSecret
            if (lease != null) {
                peer.sendControl(
                    ControlProtocol.encode(
                        ControlPacket.Heartbeat(lease)
                    )
                )
                // Display capability is control-plane metadata, not proof that
                // EGL presented a frame. Publish it independently so a renderer
                // stall cannot make the host forget the controller's active
                // presentation clock.
                publishDisplayCapabilities()
            }

            handler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    fun start() {
        check(!closed.get())
        if (!started.compareAndSet(false, true)) return

        /*
         * Preconnect may start at HOST_APPROVED, minutes before the host has
         * completed MediaProjection consent. Do not start the HELLO timeout
         * yet; otherwise the controller can self-destruct while the user is
         * still legitimately approving screen sharing.
         */
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.BAKLAVA) {
            displayManager?.registerDisplayListener(
                appContext.mainExecutor,
                DisplayManager.EVENT_TYPE_DISPLAY_CHANGED or
                    DisplayManager.EVENT_TYPE_DISPLAY_REFRESH_RATE,
                displayListener
            )
        } else {
            displayManager?.registerDisplayListener(
                displayListener,
                handler
            )
        }
        peer.start()
    }

    fun onScreenReady() {
        if (closed.get()) return
        if (!screenReadyArmed.compareAndSet(false, true)) return

        handler.removeCallbacks(helloWatchdog)
        handler.postDelayed(
            helloWatchdog,
            HELLO_TIMEOUT_MS
        )
        listener.onDiagnostic(
            "SCREEN_READY confirmed; controller handshake watchdog armed"
        )
    }

    fun remoteGeometry(): RemoteGeometry? = geometry

    fun confirmPrimaryVideoRendered(): Boolean {
        if (closed.get()) return false
        val lease = leaseSecret ?: return false

        val sent = peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.PrimaryVideoReady(
                    leaseSecret = lease
                )
            )
        )
        if (sent) inboundVideoLiveness.markPrimaryRecoveredConfirmed()
        return sent
    }

    fun sendPresentationFeedback(
        window: PresentationCadenceWindow,
        displayRefreshRateHz: Float? = null
    ): Boolean {
        if (closed.get()) return false
        val lease = leaseSecret ?: return false
        val display = geometry ?: return false
        if (displayRefreshRateHz != null) {
            publishDisplayCapabilities(displayRefreshRateHz)
        }
        return peer.sendTelemetry(
            bytes = ControlProtocol.encode(
                ControlPacket.PresentationFeedback(
                    leaseSecret = lease,
                    generation = display.generation,
                    sequence = feedbackSequence.incrementAndGet(),
                    intervalMs = window.intervalMs,
                    renderedFrames = window.renderedFrames,
                    maxGapMs = window.maxGapMs
                )
            )
        )
    }

    fun sendDisplayCapabilities(
        refreshRateHz: Float? = currentDisplayRefreshRateHz()
    ): Boolean = publishDisplayCapabilities(refreshRateHz)

    private fun publishDisplayCapabilities(
        refreshRateHz: Float? = currentDisplayRefreshRateHz()
    ): Boolean {
        if (closed.get()) return false
        val lease = leaseSecret ?: return false
        val display = geometry ?: return false
        val refresh =
            refreshRateHz
                ?.takeIf { it.isFinite() && it in 1f..240f }
                ?: return false

        val sent =
            peer.sendTelemetry(
                ControlProtocol.encode(
                    ControlPacket.DisplayCapabilities(
                        lease,
                        display.generation,
                        feedbackSequence.incrementAndGet(),
                        refresh
                    )
                )
            )
        if (sent) {
            lastPublishedDisplayRefreshRateHz = refresh
        }
        return sent
    }

    @Suppress("DEPRECATION")
    private fun currentDisplayRefreshRateHz(): Float? {
        val display =
            displayManager
                ?.getDisplay(Display.DEFAULT_DISPLAY)
                ?: return null

        /*
         * This value is a presentation clock, not a capability ceiling.
         *
         * Display.getRefreshRate() is intentionally read first. Android's
         * DisplayManager documentation uses that read to subscribe clients to
         * refresh-rate change callbacks, and it reflects the effective current
         * display refresh seen by this process. Using the fastest entry from
         * supportedModes here used to misclassify a 60 Hz active session on a
         * 120 Hz-capable panel as 120 Hz. That changes DisplayCadencePolicy's
         * adaptation ladder (for example, a 60 Hz controller can lose the
         * 50/45 fps relief rungs and fall much more abruptly).
         *
         * The physical active mode remains a defensive fallback for OEMs that
         * return an invalid effective rate.
         */
        val effectiveRefresh = display.refreshRate
        if (
            effectiveRefresh.isFinite() &&
            effectiveRefresh in 1f..240f
        ) {
            return effectiveRefresh
        }

        val modeRefresh = display.mode.refreshRate
        return modeRefresh.takeIf {
            it.isFinite() && it in 1f..240f
        }
    }

    fun sendPresentationHeartbeat(): Boolean {
        if (closed.get()) return false
        val lease = leaseSecret ?: return false
        val display = geometry ?: return false
        return peer.sendTelemetry(
            bytes = ControlProtocol.encode(
                ControlPacket.PresentationHeartbeat(
                    leaseSecret = lease,
                    generation = display.generation,
                    sequence = feedbackSequence.incrementAndGet()
                )
            )
        )
    }

    fun setInteractionActive(active: Boolean): Boolean {
        if (closed.get()) return false

        /*
         * Decoder/jitter stats are generated on the controller endpoint, so
         * finger-down must accelerate this local health loop as well as telling
         * the host to prioritize fresh capture. This changes telemetry cadence
         * only; it does not create extra decode/render work.
         */
        peer.setRealtimeVideoTelemetry(
            active || presentationMotionActive
        )

        if (interactionActive == active) return true

        val lease = leaseSecret ?: return false
        val sent = peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.InteractionState(
                    leaseSecret = lease,
                    active = active
                )
            )
        )
        if (sent) {
            interactionActive = active
        }
        return sent
    }

    /**
     * Keep receiver-side getStats responsive while real EGL cadence proves
     * autonomous screen motion. This is local-only telemetry policy: it never
     * emits InteractionState and therefore cannot make the host believe a
     * finger is still down.
     */
    fun setPresentationMotionActive(active: Boolean): Boolean {
        if (closed.get()) return false
        if (presentationMotionActive == active) return true

        presentationMotionActive = active
        peer.setRealtimeVideoTelemetry(
            interactionActive || presentationMotionActive
        )
        return true
    }

    fun requestMediaRecovery(): Boolean {
        if (closed.get()) return false
        // Re-arm the renderer acknowledgement before asking for recovery. Old
        // rendered=true state must not discard all incoming fallback frames.
        listener.onPrimaryVideoRecoveryStarted()

        val lease = leaseSecret
        if (
            lease != null &&
            peer.sendControl(
                ControlProtocol.encode(
                    ControlPacket.VideoRecoveryRequest(
                        leaseSecret = lease
                    )
                )
            )
        ) {
            listener.onDiagnostic(
                "Video recovery requested over healthy control channel"
            )
            return true
        }

        /*
         * Only fall back to transport-level signaling if the ordered control
         * channel is unavailable. A black picture alone must not disturb a
         * healthy ICE/DataChannel path.
         */
        return peer.requestRemoteRecovery()
    }

    private fun nextCommandSequence(trackAck: Boolean = true): Long = sequence.incrementAndGet().also {
        if (trackAck) commandLatency.sent(it, SystemClock.elapsedRealtime())
    }

    fun sendTap(
        nx: Float,
        ny: Float,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Tap(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    nx = nx,
                    ny = ny
                )
            )
        )
    }

    fun sendLongPress(
        nx: Float,
        ny: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.LongPress(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    nx = nx,
                    ny = ny,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendSwipe(
        fromNx: Float,
        fromNy: Float,
        toNx: Float,
        toNy: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Swipe(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    fromNx = fromNx,
                    fromNy = fromNy,
                    toNx = toNx,
                    toNy = toNy,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendGesturePath(
        points: List<Pair<Float, Float>>,
        durationMs: Int,
        expectedGeneration: Int
    ): Boolean {
        if (points.size !in 2..MAX_GESTURE_PATH_POINTS) return false

        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false
        val controlPoints = points.map { (nx, ny) ->
            if (!nx.isFinite() || !ny.isFinite()) return false
            ControlPathPoint(
                nx = nx.coerceIn(0f, 1f),
                ny = ny.coerceIn(0f, 1f)
            )
        }

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.GesturePath(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    points = controlPoints,
                    durationMs = durationMs
                )
            )
        )
    }

    fun newGestureStreamId(): Long =
        gestureStreamIds.incrementAndGet()

    fun sendGestureStreamSegment(
        streamId: Long,
        phase: com.aaris.remoteassist.control.GestureStreamPhase,
        points: List<Pair<Float, Float>>,
        durationMs: Int,
        expectedGeneration: Int
    ): Boolean {
        if (
            streamId <= 0L ||
            points.size !in 1..MAX_GESTURE_STREAM_POINTS
        ) {
            return false
        }

        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false
        val controlPoints = points.map { (nx, ny) ->
            if (!nx.isFinite() || !ny.isFinite()) return false
            ControlPathPoint(
                nx = nx.coerceIn(0f, 1f),
                ny = ny.coerceIn(0f, 1f)
            )
        }

        val payload = ControlProtocol.encode(
            ControlPacket.GestureStream(
                leaseSecret = lease,
                generation = geometry.generation,
                sequence = nextCommandSequence(
                    trackAck = phase != com.aaris.remoteassist.control.GestureStreamPhase.CONTINUE
                ),
                streamId = streamId,
                phase = phase,
                points = controlPoints,
                durationMs = durationMs
            )
        )

        return peer.sendControl(
            bytes = payload,
            freshnessSensitive =
                phase ==
                    com.aaris.remoteassist.control.GestureStreamPhase.CONTINUE
        )
    }

    fun sendTwoFingerGesture(
        firstFromNx: Float,
        firstFromNy: Float,
        firstToNx: Float,
        firstToNy: Float,
        secondFromNx: Float,
        secondFromNy: Float,
        secondToNx: Float,
        secondToNy: Float,
        durationMs: Int,
        expectedGeneration: Int? = null
    ): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = currentGeometry(expectedGeneration) ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.TwoFinger(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    firstFromNx = firstFromNx,
                    firstFromNy = firstFromNy,
                    firstToNx = firstToNx,
                    firstToNy = firstToNy,
                    secondFromNx = secondFromNx,
                    secondFromNy = secondFromNy,
                    secondToNx = secondToNx,
                    secondToNy = secondToNy,
                    durationMs = durationMs
                )
            )
        )
    }

    fun sendBack(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Back(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence()
                )
            )
        )
    }

    fun sendHome(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Home(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence()
                )
            )
        )
    }

    fun sendRecents(): Boolean {
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Recents(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence()
                )
            )
        )
    }

    fun sendText(text: String): Boolean {
        val safeText = text.take(MAX_REMOTE_TEXT_CHARS)
        if (safeText.isEmpty()) return false
        val lease = leaseSecret ?: return false
        val geometry = geometry ?: return false

        return peer.sendControl(
            ControlProtocol.encode(
                ControlPacket.Text(
                    leaseSecret = lease,
                    generation = geometry.generation,
                    sequence = nextCommandSequence(),
                    text = safeText
                )
            )
        )
    }

    private fun currentGeometry(
        expectedGeneration: Int?
    ): RemoteGeometry? {
        val current = geometry ?: return null
        if (
            expectedGeneration != null &&
            current.generation != expectedGeneration
        ) {
            return null
        }
        return current
    }

    override fun onPeerConnected() {
        transport.onPeerConnected()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onPeerDisconnected() {
        inboundVideoLiveness.reset()
        transport.onPeerDisconnected()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlChannelOpen() {
        transport.onControlChannelOpen()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlChannelClosed() {
        interactionActive = false
        presentationMotionActive = false
        peer.setRealtimeVideoTelemetry(false)
        transport.onControlChannelClosed()
            ?.let(listener::onConnectivityChanged)
    }

    override fun onControlMessage(bytes: ByteArray) {
        when (val packet = ControlProtocol.decode(bytes)) {
            is ControlPacket.Hello -> {
                if (
                    packet.widthPx <= 0 ||
                    packet.heightPx <= 0 ||
                    packet.generation < 0
                ) {
                    return
                }

                val resetLatency = leaseSecret != packet.leaseSecret || geometry?.generation != packet.generation
                leaseSecret = packet.leaseSecret
                interactionActive = false
                presentationMotionActive = false
                peer.setRealtimeVideoTelemetry(false)
                inboundVideoLiveness.reset()
                handler.removeCallbacks(helloWatchdog)
                val geometry = RemoteGeometry(
                    generation = packet.generation,
                    widthPx = packet.widthPx,
                    heightPx = packet.heightPx
                )
                this.geometry = geometry
                if (resetLatency) {
                    commandLatency.reset()
                    inputToGlass.reset()
                }

                handler.removeCallbacks(heartbeat)
                handler.post(heartbeat)

                listener.onLive(geometry)
                // Publish display capability immediately at lease bind; do not
                // wait for the first rendered frame/presentation window.
                publishDisplayCapabilities()
                peer.sendControl(
                    ControlProtocol.encode(
                        ControlPacket.FallbackDeltaReady(
                            leaseSecret = packet.leaseSecret
                        )
                    )
                )
            }

            is ControlPacket.CommandResult -> {
                val now = SystemClock.elapsedRealtime()
                commandLatency
                    .acknowledged(
                        packet.sequence,
                        packet.applied,
                        now
                    )
                    ?.let(inputToGlass::applied)
                if (now - lastLatencyReportMs >= 1000) {
                    lastLatencyReportMs = now
                    listener.onDiagnostic(commandLatency.summary())
                }
                listener.onCommandResult(
                    sequence = packet.sequence,
                    applied = packet.applied
                )
            }

            else -> Unit
        }
    }

    /**
     * Called from EglRenderer's render thread after a real buffer swap.
     * The synchronized tracker does O(1) work and normally returns null. Only
     * when an authoritative applied-input probe completes do we hop to the
     * main/session lane and emit one tiny freshness telemetry packet.
     */
    fun onFramePresented(presentedAtMs: Long) {
        val sample = inputToGlass.onPresented(presentedAtMs) ?: return
        val lease = leaseSecret ?: return
        val display = geometry ?: return

        handler.post {
            if (
                closed.get() ||
                leaseSecret != lease ||
                geometry?.generation != display.generation
            ) {
                return@post
            }

            peer.sendTelemetry(
                bytes =
                    ControlProtocol.encode(
                        ControlPacket.PhotonFeedback(
                            leaseSecret = lease,
                            generation = display.generation,
                            sequence = feedbackSequence.incrementAndGet(),
                            inputToGlassUpperBoundMs = sample.upperBoundMs,
                            commandAckMs = sample.commandAckMs,
                            postAckPresentMs = sample.postAckPresentMs
                        )
                    )
            )

            val now = SystemClock.elapsedRealtime()
            if (now - lastPhotonReportMs >= 1_000L) {
                lastPhotonReportMs = now
                listener.onDiagnostic(inputToGlass.summary())
            }
        }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) {
        inboundVideoLiveness.reset()
        listener.onRemoteVideoTrack(track)
    }

    override fun onFallbackVideoFrame(
        frame: FallbackVideoFrame
    ) {
        listener.onFallbackVideoFrame(frame)
    }

    override fun onFallbackDeltaFrame(
        frame: FallbackDeltaFrame
    ) {
        listener.onFallbackDeltaFrame(frame)
    }

    override fun onVideoHealth(
        snapshot: VideoHealthSnapshot
    ) {
        if (
            snapshot.direction != "inbound" ||
            leaseSecret == null
        ) {
            return
        }

        val lease = leaseSecret
        val display = geometry
        val recent = snapshot.recent
        if (lease != null && display != null && recent != null) {
            peer.sendTelemetry(
                bytes = ControlProtocol.encode(
                    ControlPacket.VideoFeedback(
                        lease,
                        display.generation,
                        feedbackSequence.incrementAndGet(),
                        recent.intervalMs,
                        recent.frames,
                        recent.processingMs?.toFloat() ?: -1f,
                        /*
                         * Keep the wire field protocol-compatible, but report
                         * measured jitter-buffer residence whenever WebRTC
                         * exposes it. The native target delay is a scheduling
                         * goal, not time already spent waiting; conflating it
                         * with actual debt can make host adaptation fight the
                         * receiver jitter controller. On implementations that
                         * omit measured residence, playoutDelayMs falls back to
                         * the target so telemetry does not disappear entirely.
                         */
                        recent.playoutDelayMs?.toFloat() ?: -1f,
                        recent.dropped ?: -1,
                        recent.freezes ?: -1
                    )
                )
            )
        }
        val now = android.os.SystemClock.elapsedRealtime()
        // Throttle diagnostics, not decoder liveness. getStats() already runs
        // every 500 ms during interaction and more slowly while idle. Every
        // cumulative counter sample helps distinguish real decoder blockage
        // from a quiet remote screen without introducing another stats poll.
        if (now - lastVideoLivenessMs >= 3_000L) {
            lastVideoLivenessMs = now
            listener.onDiagnostic(snapshot.compact())
        }

        when (
            inboundVideoLiveness.observe(
                framesReceived = snapshot.frames,
                framesDecoded = snapshot.framesSecondary,
                nowMs = now
            )
        ) {
            InboundVideoLivenessAction.NONE -> Unit

            InboundVideoLivenessAction.REQUEST_RECOVERY -> {
                listener.onDiagnostic(
                    "Primary video stalled • requesting in-session media recovery"
                )
                if (!requestMediaRecovery()) {
                    inboundVideoLiveness
                        .markRecoveryRequestFailed()
                }
            }

            InboundVideoLivenessAction.CONFIRM_PRIMARY_RECOVERED -> {
                // RTP decoded counters are not proof that pixels reached EGL.
                // Only the viewer's fresh rendered frame may stop fallback.
                listener.onDiagnostic("Primary decoded frames resumed • waiting for display confirmation")
            }
        }
    }

    override fun onDiagnostic(message: String) {
        listener.onDiagnostic(message)
    }

    override fun onError(error: Throwable) {
        listener.onRecoverableError(error)
    }

    override fun close() {
        close(notifyRemote = true)
    }

    fun close(notifyRemote: Boolean) {
        if (!closed.compareAndSet(false, true)) return

        screenReadyArmed.set(false)
        handler.removeCallbacks(helloWatchdog)
        handler.removeCallbacks(heartbeat)
        handler.removeCallbacks(displayRefreshUpdate)
        runCatching {
            displayManager?.unregisterDisplayListener(
                displayListener
            )
        }
        inboundVideoLiveness.reset()
        commandLatency.reset()
        inputToGlass.reset()
        if (notifyRemote) {
            runCatching {
                peer.sendControl(
                    ControlProtocol.encode(
                        ControlPacket.Disconnect
                    )
                )
            }
        }
        runCatching { peer.close() }

        leaseSecret = null
        geometry = null
        interactionActive = false
        presentationMotionActive = false
    }

    companion object {
        private const val HEARTBEAT_MS = 5_000L
        private const val DISPLAY_REFRESH_SETTLE_MS = 150L
        private const val DISPLAY_REFRESH_CHANGE_EPSILON_HZ = 0.75f
        private const val HELLO_TIMEOUT_MS = 90_000L
        private const val MAX_REMOTE_TEXT_CHARS = 500
        private const val MAX_GESTURE_PATH_POINTS = 96
        private const val MAX_GESTURE_STREAM_POINTS = 16
    }
}
