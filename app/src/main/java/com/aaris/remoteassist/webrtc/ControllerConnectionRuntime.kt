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
    private var ownerListener: ControllerWebRtcSession.Listener? = null

    @Volatile
    private var connected = false

    @Volatile
    private var geometry: RemoteGeometry? = null

    @Volatile
    private var remoteTrack: VideoTrack? = null

    @Volatile
    private var fallbackFrame: FallbackVideoFrame? = null

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
            fallbackFrame = null
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

    fun setOwnerListener(
        listener: ControllerWebRtcSession.Listener?
    ) {
        ownerListener = listener
    }

    fun attachOrStart(
        context: Context,
        sessionId: String,
        listener: ControllerWebRtcSession.Listener
    ): ControllerWebRtcSession {
        val active = ensureStarted(context, sessionId)
        /*
         * Do not synchronously replay cached media callbacks while the viewer
         * Activity is still inside onCreate/onResume. Some OEM Surface/EGL
         * stacks are fragile during that handoff. The Activity explicitly
         * requests replay after its window is attached and laid out.
         */
        uiListener = listener
        return active
    }

    fun replayUiState(sessionId: String) {
        if (activeSessionId != sessionId) return
        val listener = uiListener ?: return

        if (connected) {
            listener.onConnectivityChanged(true)
        }
        geometry?.let(listener::onLive)
        remoteTrack?.let(listener::onRemoteVideoTrack)
        fallbackFrame?.let(listener::onFallbackVideoFrame)
    }

    fun detachUi() {
        uiListener = null
    }

    fun attach(
        sessionId: String,
        listener: ControllerWebRtcSession.Listener
    ): ControllerWebRtcSession? {
        if (activeSessionId != sessionId) return null

        /*
         * Registration and replay are intentionally separate. Inline viewers
         * register before their first layout pass, then call replayUiState()
         * from View.post once TextureView/EGL can safely bind. Synchronous
         * replay here used to duplicate geometry/video callbacks and could ask
         * fragile OEM EGL stacks to attach a track before a real surface was
         * available.
         */
        uiListener = listener
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
            ownerListener = null
            connected = false
            geometry = null
            remoteTrack = null
            fallbackFrame = null
        }
    }

    private val runtimeListener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                this@ControllerConnectionRuntime.geometry = geometry
                ownerListener?.onLive(geometry)
                uiListener?.onLive(geometry)
            }

            override fun onConnectivityChanged(
                connected: Boolean
            ) {
                this@ControllerConnectionRuntime.connected = connected
                ownerListener?.onConnectivityChanged(connected)
                uiListener?.onConnectivityChanged(connected)
            }

            override fun onRemoteVideoTrack(track: VideoTrack) {
                remoteTrack = track
                ownerListener?.onRemoteVideoTrack(track)
                uiListener?.onRemoteVideoTrack(track)
            }

            override fun onFallbackVideoFrame(
                frame: FallbackVideoFrame
            ) {
                fallbackFrame = frame
                ownerListener?.onFallbackVideoFrame(frame)
                uiListener?.onFallbackVideoFrame(frame)
            }

            override fun onCommandResult(
                sequence: Long,
                applied: Boolean
            ) {
                ownerListener?.onCommandResult(
                    sequence,
                    applied
                )
                uiListener?.onCommandResult(
                    sequence,
                    applied
                )
            }

            override fun onDiagnostic(message: String) {
                ownerListener?.onDiagnostic(message)
                uiListener?.onDiagnostic(message)
            }

            override fun onRecoverableError(error: Throwable) {
                ownerListener?.onRecoverableError(error)
                uiListener?.onRecoverableError(error)
            }

            override fun onTerminalError(error: Throwable) {
                ownerListener?.onTerminalError(error)
                uiListener?.onTerminalError(error)
            }
        }
}
