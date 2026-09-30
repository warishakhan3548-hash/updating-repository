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
    private var controlOpen = false

    @Volatile
    private var lease: LiveLease? = null

    private val signaling = FirebaseSignalingClient(
        sessionId = sessionId,
        role = PeerRole.HOST
    )

    private val peer = WebRtcPeer(
        context = appContext,
        role = PeerRole.HOST,
        signaling = signaling,
        listener = this
    )

    private val capture = ScreenCaptureTrack(
        context = appContext,
        grant = projectionGrant,
        onProjectionStopped = listener::onProjectionStopped
    )

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
        peer.start()
    }

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
        listener.onConnectivityChanged(true)
        ensureLiveHandshake()
    }

    override fun onPeerDisconnected() {
        peerConnected = false
        listener.onConnectivityChanged(false)
    }

    override fun onControlChannelOpen() {
        controlOpen = true
        ensureLiveHandshake()
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

                refreshDisplayProfile()
            }

            ControlPacket.Disconnect ->
                listener.onRemoteDisconnect()

            is ControlPacket.Tap,
            is ControlPacket.LongPress,
            is ControlPacket.Swipe,
            is ControlPacket.Back,
            is ControlPacket.Home -> {
                val currentProfile = profile
                val command = ControlProtocol.toRemoteCommand(
                    sessionId = sessionId,
                    packet = packet,
                    widthPx = currentProfile.displayWidthPx,
                    heightPx = currentProfile.displayHeightPx
                ) ?: return

                AssistAccessibilityService.dispatch(command)
            }

            is ControlPacket.Hello -> Unit
        }
    }

    override fun onRemoteVideoTrack(track: VideoTrack) = Unit

    override fun onError(error: Throwable) {
        listener.onError(error)
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        runCatching {
            displayManager.unregisterDisplayListener(displayListener)
        }
        runCatching { peer.close() }
        runCatching { capture.close() }

        peerConnected = false
        controlOpen = false
        lease = null
    }

    private fun ensureLiveHandshake() {
        if (!peerConnected || !controlOpen || closed.get()) return

        val currentLease = lease ?: runCatching {
            SessionCoordinator.activateLive(sessionId)
        }.getOrElse {
            listener.onError(it)
            return
        }.also {
            lease = it
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
}
