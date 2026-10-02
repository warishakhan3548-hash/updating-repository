package com.aaris.remoteassist.webrtc

import android.content.Context
import org.webrtc.VideoTrack

/**
 * Process-scoped controller transport owner.
 *
 * The foreground ControllerConnectionService owns the lifetime. Activities may
 * attach/detach as views without creating or destroying the underlying WebRTC
 * peer. This prevents Activity handoffs from killing signaling.
 */
object ControllerConnectionRuntime {
    private val lock = Any()

    @Volatile
    private var activeSessionId: String? = null

    @Volatile
    private var session: ControllerWebRtcSession? = null

    @Volatile
    private var uiListener: ControllerWebRtcSession.Listener? = null

    @Volatile
    private var connected = false

    @Volatile
    private var geometry: RemoteGeometry? = null

    @Volatile
    private var remoteTrack: VideoTrack? = null

    fun ensureStarted(
        context: Context,
        sessionId: String
    ): ControllerWebRtcSession {
        synchronized(lock) {
            val existing = session
            if (
                existing != null &&
                activeSessionId == sessionId
            ) {
                return existing
            }

            existing?.close(notifyRemote = false)
            connected = false
            geometry = null
            remoteTrack = null
            activeSessionId = sessionId

            val created = ControllerWebRtcSession(
                context = context.applicationContext,
                sessionId = sessionId,
                listener = runtimeListener
            )
            session = created
            created.start()
            return created
        }
    }

    fun onScreenReady(sessionId: String) {
        if (activeSessionId != sessionId) return
        session?.onScreenReady()
    }

    fun attach(
        sessionId: String,
        listener: ControllerWebRtcSession.Listener
    ): ControllerWebRtcSession? {
        if (activeSessionId != sessionId) return null
        uiListener = listener

        if (connected) {
            listener.onConnectivityChanged(true)
        }
        geometry?.let(listener::onLive)
        remoteTrack?.let(listener::onRemoteVideoTrack)

        return session
    }

    fun detach(listener: ControllerWebRtcSession.Listener) {
        if (uiListener === listener) {
            uiListener = null
        }
    }

    fun activeSession(sessionId: String): ControllerWebRtcSession? =
        if (activeSessionId == sessionId) session else null

    fun close(
        sessionId: String? = activeSessionId,
        notifyRemote: Boolean = true
    ) {
        synchronized(lock) {
            if (
                sessionId != null &&
                activeSessionId != sessionId
            ) {
                return
            }

            session?.close(notifyRemote)
            session = null
            activeSessionId = null
            uiListener = null
            connected = false
            geometry = null
            remoteTrack = null
        }
    }

    private val runtimeListener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                this@ControllerConnectionRuntime.geometry = geometry
                uiListener?.onLive(geometry)
            }

            override fun onConnectivityChanged(
                connected: Boolean
            ) {
                this@ControllerConnectionRuntime.connected = connected
                uiListener?.onConnectivityChanged(connected)
            }

            override fun onRemoteVideoTrack(track: VideoTrack) {
                remoteTrack = track
                uiListener?.onRemoteVideoTrack(track)
            }

            override fun onCommandResult(
                sequence: Long,
                applied: Boolean
            ) {
                uiListener?.onCommandResult(
                    sequence,
                    applied
                )
            }

            override fun onDiagnostic(message: String) {
                uiListener?.onDiagnostic(message)
            }

            override fun onRecoverableError(error: Throwable) {
                uiListener?.onRecoverableError(error)
            }

            override fun onTerminalError(error: Throwable) {
                uiListener?.onTerminalError(error)
            }
        }
}
