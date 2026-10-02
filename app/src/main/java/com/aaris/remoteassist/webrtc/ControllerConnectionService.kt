package com.aaris.remoteassist.webrtc

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.IBinder
import com.aaris.remoteassist.diagnostics.ConnectionFlightRecorder
import com.aaris.remoteassist.pairing.BackendSessionCloser
import com.aaris.remoteassist.pairing.CloudflarePairingGateway
import com.aaris.remoteassist.pairing.PairingGateway
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import com.aaris.remoteassist.ui.MainActivity
import java.io.Closeable
import org.webrtc.VideoTrack

/**
 * Foreground owner for controller signaling/WebRTC.
 *
 * This service is started directly from the user's Connect action. It owns the
 * network session independently from Activity lifecycle, so closing/recreating
 * the UI cannot silently remove the controller WebSocket before the host sends
 * its offer.
 */
class ControllerConnectionService : Service() {
    private var activeSessionId: String? = null
    private var observer: Closeable? = null

    private val ownerListener =
        object : ControllerWebRtcSession.Listener {
            override fun onLive(geometry: RemoteGeometry) {
                activeSessionId?.let { id ->
                    ConnectionFlightRecorder.pass(
                        id,
                        "Controller HELLO received; transport is live"
                    )
                }
                updateNotification(
                    "Remote connection is live"
                )
            }

            override fun onConnectivityChanged(
                connected: Boolean
            ) {
                activeSessionId?.let { id ->
                    ConnectionFlightRecorder.pass(
                        id,
                        if (connected) {
                            "Controller WebRTC transport CONNECTED"
                        } else {
                            "Controller WebRTC transport reconnecting"
                        }
                    )
                }
                updateNotification(
                    if (connected) {
                        "Phone-to-phone link connected"
                    } else {
                        "Reconnecting secure link…"
                    }
                )
            }

            override fun onRemoteVideoTrack(track: VideoTrack) {
                activeSessionId?.let { id ->
                    ConnectionFlightRecorder.pass(
                        id,
                        "Controller received remote video track"
                    )
                }
            }

            override fun onCommandResult(
                sequence: Long,
                applied: Boolean
            ) = Unit

            override fun onDiagnostic(message: String) {
                activeSessionId?.let { id ->
                    ConnectionFlightRecorder.pass(id, message)
                }
            }

            override fun onRecoverableError(error: Throwable) {
                activeSessionId?.let { id ->
                    ConnectionFlightRecorder.fail(
                        id,
                        "Controller recovery: " +
                            (error.message
                                ?: error.javaClass.simpleName)
                    )
                }
            }

            override fun onTerminalError(error: Throwable) {
                val id = activeSessionId ?: return
                ConnectionFlightRecorder.fail(
                    id,
                    "Controller terminal failure: " +
                        (error.message
                            ?: error.javaClass.simpleName)
                )
                stopSession(
                    id = id,
                    closeBackend = true
                )
            }
        }

    override fun onCreate() {
        super.onCreate()
        ensureChannel()
    }

    override fun onStartCommand(
        intent: Intent?,
        flags: Int,
        startId: Int
    ): Int {
        when (intent?.action) {
            ACTION_START -> {
                val id =
                    intent.getStringExtra(EXTRA_SESSION_ID)
                        ?: return START_NOT_STICKY
                startSession(id)
            }

            ACTION_STOP -> {
                activeSessionId?.let { id ->
                    stopSession(
                        id = id,
                        closeBackend = true
                    )
                } ?: stopSelf()
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        val id = activeSessionId
        activeSessionId = null

        observer?.close()
        observer = null

        ControllerConnectionRuntime.setOwnerListener(null)
        if (id != null) {
            ControllerConnectionRuntime.close(
                id,
                notifyRemote = false
            )
        }

        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startSession(sessionId: String) {
        if (activeSessionId == sessionId) return

        activeSessionId?.let { old ->
            stopSession(
                id = old,
                closeBackend = true
            )
        }

        activeSessionId = sessionId
        startVisibleForeground(
            "Waiting for host approval…"
        )

        ConnectionFlightRecorder.reset(
            sessionId,
            "CONTROLLER"
        )
        ConnectionFlightRecorder.pass(
            sessionId,
            "Foreground controller connection owner started"
        )

        prepareLocalPairingState(sessionId)
        ControllerConnectionRuntime.setOwnerListener(
            ownerListener
        )
        observeBackend(sessionId)
    }

    private fun observeBackend(sessionId: String) {
        observer?.close()
        observer = CloudflarePairingGateway(this)
            .observeSession(
                sessionId = sessionId,
                listener = { backend ->
                    if (activeSessionId != sessionId) {
                        return@observeSession
                    }

                    ConnectionFlightRecorder.pass(
                        sessionId,
                        "Controller backend state → " +
                            backend.state
                    )

                    when (backend.state) {
                        "PAIR_PENDING" ->
                            updateNotification(
                                "Waiting for host approval…"
                            )

                        "HOST_APPROVED" -> {
                            alignLocalState(
                                sessionId,
                                screenReady = false
                            )
                            ensureTransport(sessionId)
                            updateNotification(
                                "Approved • preparing secure link…"
                            )
                        }

                        "SCREEN_READY" -> {
                            alignLocalState(
                                sessionId,
                                screenReady = true
                            )
                            ensureTransport(sessionId)
                            ControllerConnectionRuntime
                                .onScreenReady(sessionId)
                            updateNotification(
                                "Screen ready • connecting phones…"
                            )
                        }

                        "LIVE" -> {
                            alignLocalState(
                                sessionId,
                                screenReady = true
                            )
                            ensureTransport(sessionId)
                            ControllerConnectionRuntime
                                .onScreenReady(sessionId)
                            runCatching {
                                val state =
                                    SessionCoordinator.snapshot()
                                if (
                                    state.sessionId == sessionId &&
                                    state.state ==
                                        SessionState.CONNECTING
                                ) {
                                    SessionCoordinator.transition(
                                        sessionId,
                                        SessionState.LIVE
                                    )
                                }
                            }
                            updateNotification(
                                "Remote connection is live"
                            )
                        }

                        "CLOSED" ->
                            stopSession(
                                id = sessionId,
                                closeBackend = false
                            )
                    }
                },
                onError = { error ->
                    if (activeSessionId != sessionId) {
                        return@observeSession
                    }

                    ConnectionFlightRecorder.fail(
                        sessionId,
                        "Controller backend observer stopped: " +
                            (error.message
                                ?: error.javaClass.simpleName)
                    )
                    stopSession(
                        id = sessionId,
                        closeBackend = false
                    )
                }
            )
    }

    private fun ensureTransport(sessionId: String) {
        if (activeSessionId != sessionId) return

        runCatching {
            ControllerConnectionRuntime.ensureStarted(
                this,
                sessionId
            )
        }.onFailure { error ->
            ConnectionFlightRecorder.fail(
                sessionId,
                "Controller transport could not start: " +
                    (error.message
                        ?: error.javaClass.simpleName)
            )
            stopSession(
                id = sessionId,
                closeBackend = true
            )
        }
    }

    private fun prepareLocalPairingState(sessionId: String) {
        runCatching {
            var state = SessionCoordinator.snapshot()

            if (
                state.sessionId != null &&
                state.sessionId != sessionId &&
                state.state != SessionState.LIVE
            ) {
                SessionCoordinator.reset()
                state = SessionCoordinator.snapshot()
            }

            if (
                state.state == SessionState.IDLE ||
                state.state == SessionState.SETUP_REQUIRED ||
                state.state == SessionState.CLOSED
            ) {
                SessionCoordinator.prepareReady()
                state = SessionCoordinator.snapshot()
            }

            if (state.state == SessionState.READY) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.PAIR_PENDING
                )
            }
        }
    }

    private fun alignLocalState(
        sessionId: String,
        screenReady: Boolean
    ) {
        runCatching {
            prepareLocalPairingState(sessionId)
            var state = SessionCoordinator.snapshot()

            if (
                state.sessionId == sessionId &&
                state.state == SessionState.PAIR_PENDING
            ) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.HOST_APPROVED
                )
                state = SessionCoordinator.snapshot()
            }

            if (
                screenReady &&
                state.sessionId == sessionId &&
                state.state == SessionState.HOST_APPROVED
            ) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.SCREEN_CONSENT
                )
                state = SessionCoordinator.snapshot()
            }

            if (
                screenReady &&
                state.sessionId == sessionId &&
                state.state == SessionState.SCREEN_CONSENT
            ) {
                SessionCoordinator.transition(
                    sessionId,
                    SessionState.CONNECTING
                )
            }
        }
    }

    private fun stopSession(
        id: String,
        closeBackend: Boolean
    ) {
        if (activeSessionId != id) return

        activeSessionId = null
        observer?.close()
        observer = null

        ControllerConnectionRuntime.setOwnerListener(null)
        ControllerConnectionRuntime.close(
            id,
            notifyRemote = true
        )

        if (closeBackend) {
            BackendSessionCloser.close(this, id)
        }
        SessionCoordinator.close(id)

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startVisibleForeground(message: String) {
        val notification = buildNotification(message)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC
            )
        } else {
            startForeground(
                NOTIFICATION_ID,
                notification
            )
        }
    }

    private fun updateNotification(message: String) {
        getSystemService(NotificationManager::class.java)
            .notify(
                NOTIFICATION_ID,
                buildNotification(message)
            )
    }

    private fun buildNotification(message: String): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            210,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(
            this,
            ControllerConnectionService::class.java
        ).apply {
            action = ACTION_STOP
        }

        val stopPendingIntent = PendingIntent.getService(
            this,
            211,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(
                android.R.drawable.presence_online
            )
            .setContentTitle(
                "Aaris Remote controller"
            )
            .setContentText(message)
            .setOngoing(true)
            .setContentIntent(contentIntent)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(
                        this,
                        android.R.drawable.ic_menu_close_clear_cancel
                    ),
                    "STOP",
                    stopPendingIntent
                ).build()
            )
            .build()
    }

    private fun ensureChannel() {
        getSystemService(NotificationManager::class.java)
            .createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Controller connection",
                    NotificationManager.IMPORTANCE_LOW
                ).apply {
                    description =
                        "Keeps the secure remote connection alive"
                    setShowBadge(false)
                }
            )
    }

    companion object {
        const val ACTION_START =
            "com.aaris.remoteassist.action.START_CONTROLLER_CONNECTION"
        const val ACTION_STOP =
            "com.aaris.remoteassist.action.STOP_CONTROLLER_CONNECTION"
        const val EXTRA_SESSION_ID = "session_id"

        private const val CHANNEL_ID =
            "controller_connection"
        private const val NOTIFICATION_ID = 4208
    }
}
