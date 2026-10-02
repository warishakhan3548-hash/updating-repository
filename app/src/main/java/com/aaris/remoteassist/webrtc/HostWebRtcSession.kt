package com.aaris.remoteassist.webrtc

import android.content.Context
import android.hardware.display.DisplayManager
import android.os.Handler
import android.os.Looper
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.ProjectionGrant
import com.aaris.remoteassist.capture.ScreenCaptureTrack
import com.aaris.remoteassist.control.ControlPacket
import com.aaris.remoteassist.control.ControlProtocol
import com.aaris.remoteassist.session.LiveLease
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionRuntime
import java.io.Closeable
import java.util.concurrent.atomic.AtomicBoolean
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
        fun onError(error: Throwable)
    }

    private val appContext = context.applicationContext
    private val closed = AtomicBoolean(false)
    private val displayManager =
        appContext.getSystemService(DisplayManager::class.java)
    private val displayHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var profile = CaptureProfile.current(appContext)

    @Volatile
    private var peerConnected = false

    @Volatile
    private var everConnected = false

    @Volatile
    private var controlOpen = false

    @Volatile
    private var transportReady = false

    @Volatile
    private var captureReady = false

    private var startupControlRecoveryAttempts = 0

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

    private val captureWatchdog = Runnable {
        if (!closed.get() && !captureReady) {
            listener.onError(
                IllegalStateException(
                    "Screen capture produced no frames"
                )
            )
        }
    }

    private val capture = ScreenCaptureTrack(
        context = appContext,
        grant = projectionGrant,
        onProjectionStopped = listener::onProjectionStopped,
        onFirstFrame = {
            displayHandler.post {
                if (!closed.get() && !captureReady) {
                    captureReady = true
                    displayHandler.removeCallbacks(captureWatchdog)
                    ensureLiveHandshake()
                }
            }
        }
    )

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

        peer.addLocalVideoTrack(capture.videoTrack)
        capture.start(profile)
        displayHandler.removeCallbacks(captureWatchdog)
        displayHandler.postDelayed(
            captureWatchdog,
            FIRST_CAPTURE_FRAME_TIMEOUT_MS
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

        val latest = CaptureProfile.current(appContext)
        if (latest == profile) return

        profile = latest
        capture.update(latest)

        val currentLease = lease ?: return
        val rotated = SessionCoordinator.bumpDisplayGeneration(
            sessionId
        ) ?: return

        lease = rotated
        sendHello(rotated, latest)
    }

    override fun onPeerConnected() {
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
        controlOpen = true
        displayHandler.removeCallbacks(startupControlRecovery)
        transport.onControlChannelOpen()
            ?.let(listener::onConnectivityChanged)
        ensureLiveHandshake()
    }

    override fun onControlChannelClosed() {
        controlOpen = false
        transportReady = false
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

            ControlPacket.Disconnect ->
                listener.onRemoteDisconnect()

            is ControlPacket.Tap,
            is ControlPacket.LongPress,
            is ControlPacket.Swipe,
            is ControlPacket.GesturePath,
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

                AssistAccessibilityService.dispatch(command) { applied ->
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

            is ControlPacket.CommandResult,
            is ControlPacket.Hello -> Unit
        }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) = Unit

    override fun onError(error: Throwable) {
        listener.onError(error)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.removeCallbacks(captureWatchdog)
        displayHandler.removeCallbacks(iceRestart)
        displayHandler.removeCallbacks(startupControlRecovery)
        displayHandler.removeCallbacks(
            leaseWatchdog
        )
        runCatching {
            displayManager.unregisterDisplayListener(displayListener)
        }
        runCatching { peer.close() }
        runCatching { capture.close() }

        peerConnected = false
        everConnected = false
        controlOpen = false
        transportReady = false
        captureReady = false
        lease = null
    }

    @Synchronized
    private fun ensureLiveHandshake() {
        if (
            !peerConnected ||
            !controlOpen ||
            !captureReady ||
            closed.get() ||
            transportReady
        ) {
            return
        }

        if (!AssistAccessibilityService.isConnected()) {
            listener.onLocalControlUnavailable()
            return
        }

        displayHandler.removeCallbacks(connectionWatchdog)
        displayHandler.removeCallbacks(startupControlRecovery)

        val firstLive = lease == null
        val currentLease = runCatching {
            SessionCoordinator.activateLive(sessionId)
        }.getOrElse {
            listener.onError(it)
            return
        }

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
            listener.onLive()
        }

        sendHello(currentLease, profile)
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
        private const val FIRST_CAPTURE_FRAME_TIMEOUT_MS = 12_000L
        private const val CONNECT_TIMEOUT_MS = 60_000L
        private const val CONTROL_CHANNEL_GRACE_MS = 5_000L
        private const val ICE_RESTART_DELAY_MS = 1_500L
        private const val STARTUP_CONTROL_RECOVERY_INITIAL_DELAY_MS = 8_000L
        private const val STARTUP_CONTROL_RECOVERY_INTERVAL_MS = 8_000L
        private const val MAX_STARTUP_CONTROL_RECOVERY_ATTEMPTS = 2
        private const val LEASE_WATCHDOG_MS = 3_000L
    }
}
