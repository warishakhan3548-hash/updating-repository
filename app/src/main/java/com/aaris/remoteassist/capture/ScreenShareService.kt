package com.aaris.remoteassist.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Intent
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import com.aaris.remoteassist.pairing.BackendSessionCloser
import com.aaris.remoteassist.pairing.CloudflarePairingGateway
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import com.aaris.remoteassist.ui.MainActivity
import com.aaris.remoteassist.webrtc.HostWebRtcSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch

class ScreenShareService : Service() {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO
    )

    private val mainHandler = Handler(Looper.getMainLooper())

    @Volatile
    private var activeSessionId: String? = null
    private var hostSession: HostWebRtcSession? = null

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
            ACTION_START -> startApprovedSession(intent)
            ACTION_STOP -> stopActiveSession("stopped_by_remote_user")
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        val id = activeSessionId
        activeSessionId = null
        ScreenShareRuntime.clear(id)

        hostSession?.close()
        hostSession = null

        if (id != null) {
            SessionCoordinator.close(id)
            BackendSessionCloser.close(this, id)
        }

        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun startApprovedSession(intent: Intent) {
        val sessionId = intent.getStringExtra(EXTRA_SESSION_ID) ?: run {
            stopSelf()
            return
        }

        val active = activeSessionId
        if (active != null) {
            if (active != sessionId) {
                BackendSessionCloser.close(this, sessionId)
            }
            return
        }

        val resultCode = intent.getIntExtra(
            EXTRA_RESULT_CODE,
            Int.MIN_VALUE
        )

        val captureData = if (Build.VERSION.SDK_INT >= 33) {
            intent.getParcelableExtra(
                EXTRA_CAPTURE_DATA,
                Intent::class.java
            )
        } else {
            @Suppress("DEPRECATION")
            intent.getParcelableExtra(EXTRA_CAPTURE_DATA)
        }

        if (resultCode == Int.MIN_VALUE || captureData == null) {
            SessionCoordinator.close(sessionId)
            BackendSessionCloser.close(this, sessionId)
            stopSelf()
            return
        }

        activeSessionId = sessionId
        ScreenShareRuntime.activate(sessionId)

        val foregroundStarted = runCatching {
            startVisibleForeground()
        }.isSuccess
        if (!foregroundStarted) {
            ScreenShareRuntime.clear(sessionId)
            activeSessionId = null
            BackendSessionCloser.close(this, sessionId)
            SessionCoordinator.close(sessionId)
            stopSelf()
            return
        }

        val grant = ProjectionGrant(
            sessionId = sessionId,
            resultCode = resultCode,
            data = captureData
        )

        val stateOk = runCatching {
            SessionCoordinator.transition(
                sessionId,
                SessionState.SCREEN_CONSENT
            )
            SessionCoordinator.transition(
                sessionId,
                SessionState.CONNECTING
            )
        }.isSuccess

        if (!stateOk) {
            stopActiveSession("invalid_local_session_state")
            return
        }

        publishScreenReadyAndStartTransport(
            sessionId = sessionId,
            grant = grant
        )
    }

    private fun publishScreenReadyAndStartTransport(
        sessionId: String,
        grant: ProjectionGrant
    ) {
        scope.launch {
            val gateway = CloudflarePairingGateway(
                this@ScreenShareService
            )
            var attempt = 0

            while (
                activeSessionId == sessionId &&
                attempt < SCREEN_READY_PUBLISH_ATTEMPTS
            ) {
                val published = runCatching {
                    gateway.markScreenReady(sessionId)
                }.isSuccess

                if (published) {
                    mainHandler.post {
                        if (activeSessionId == sessionId) {
                            startTransport(sessionId, grant)
                        }
                    }
                    return@launch
                }

                attempt += 1
                if (
                    attempt >= SCREEN_READY_PUBLISH_ATTEMPTS ||
                    activeSessionId != sessionId
                ) {
                    break
                }

                val backoffMs =
                    (
                        SCREEN_READY_RETRY_BASE_MS *
                            (1L shl (attempt - 1).coerceAtMost(3))
                    ).coerceAtMost(
                        SCREEN_READY_RETRY_MAX_MS
                    )
                delay(backoffMs)
            }

            mainHandler.post {
                if (activeSessionId == sessionId) {
                    stopActiveSession(
                        "backend_screen_ready_failed"
                    )
                }
            }
        }
    }

    private fun startTransport(
        sessionId: String,
        grant: ProjectionGrant
    ) {
        if (
            activeSessionId != sessionId ||
            hostSession != null
        ) {
            return
        }

        var createdSession: HostWebRtcSession? = null
        hostSession = runCatching {
            HostWebRtcSession(
                context = this,
                sessionId = sessionId,
                projectionGrant = grant,
                listener = object : HostWebRtcSession.Listener {
                    override fun onLive() {
                        mainHandler.post {
                            if (activeSessionId == sessionId) {
                                updateForegroundNotification(isLive = true)
                            }
                        }
                        publishBackendLive(sessionId)
                    }

                    override fun onConnectivityChanged(
                        connected: Boolean
                    ) = Unit

                    override fun onProjectionStopped() {
                        mainHandler.post {
                            stopActiveSession(
                                "screen_projection_stopped"
                            )
                        }
                    }

                    override fun onRemoteDisconnect() {
                        mainHandler.post {
                            stopActiveSession(
                                "controller_disconnected"
                            )
                        }
                    }

                    override fun onLocalControlUnavailable() {
                        mainHandler.post {
                            stopActiveSession(
                                "accessibility_control_unavailable"
                            )
                        }
                    }

                    override fun onRecoverableError(
                        error: Throwable
                    ) {
                        /*
                         * WebRTC owns bounded SDP/ICE/TURN recovery.
                         * Keep MediaProjection and the foreground service
                         * alive while that recovery budget is running.
                         */
                    }

                    override fun onTerminalError(
                        error: Throwable
                    ) {
                        mainHandler.post {
                            stopActiveSession(
                                "webrtc_transport_failed"
                            )
                        }
                    }
                }
            ).also {
                createdSession = it
                it.start()
            }
        }.getOrElse {
            runCatching { createdSession?.close() }
            stopActiveSession("webrtc_start_failed")
            null
        }
    }

    private fun publishBackendLive(sessionId: String) {
        scope.launch {
            var attempt = 0

            while (
                activeSessionId == sessionId &&
                attempt < BACKEND_LIVE_PUBLISH_ATTEMPTS
            ) {
                val published = runCatching {
                    CloudflarePairingGateway(
                        this@ScreenShareService
                    ).markLive(sessionId)
                }.isSuccess

                if (published) {
                    return@launch
                }

                attempt += 1
                if (attempt >= BACKEND_LIVE_PUBLISH_ATTEMPTS) {
                    return@launch
                }

                val backoffMs =
                    (
                        BACKEND_LIVE_RETRY_BASE_MS *
                            (1L shl (attempt - 1).coerceAtMost(3))
                    ).coerceAtMost(BACKEND_LIVE_RETRY_MAX_MS)
                delay(backoffMs)
            }
        }
    }

    private fun stopActiveSession(reason: String) {
        val sessionId = activeSessionId
        activeSessionId = null
        ScreenShareRuntime.clear(sessionId)

        hostSession?.close()
        hostSession = null

        if (sessionId != null) {
            SessionCoordinator.close(sessionId)

            BackendSessionCloser.close(this, sessionId)
        }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startVisibleForeground() {
        val notification = buildNotification(isLive = false)
        if (Build.VERSION.SDK_INT >= 29) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PROJECTION
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    private fun updateForegroundNotification(isLive: Boolean) {
        getSystemService(NotificationManager::class.java)
            .notify(
                NOTIFICATION_ID,
                buildNotification(isLive)
            )
    }

    private fun buildNotification(isLive: Boolean): Notification {
        val contentIntent = PendingIntent.getActivity(
            this,
            100,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE or
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        val stopIntent = Intent(
            this,
            ScreenShareService::class.java
        ).apply {
            action = ACTION_STOP
        }

        val stopPendingIntent = PendingIntent.getService(
            this,
            101,
            stopIntent,
            PendingIntent.FLAG_IMMUTABLE or
                PendingIntent.FLAG_UPDATE_CURRENT
        )

        val title =
            if (isLive) {
                "Aaris Remote is sharing"
            } else {
                "Aaris Remote is preparing"
            }
        val message =
            if (isLive) {
                "Remote support is live. Tap STOP any time."
            } else {
                "Setting up the secure connection. Tap STOP any time."
            }

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(
                android.R.drawable.presence_video_online
            )
            .setContentTitle(title)
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
                    "Remote support session",
                    NotificationManager.IMPORTANCE_HIGH
                ).apply {
                    description =
                        "Visible whenever remote support is active"
                    setShowBadge(false)
                }
            )
    }

    companion object {
        const val ACTION_START =
            "com.aaris.remoteassist.action.START_SCREEN_SHARE"
        const val ACTION_STOP =
            "com.aaris.remoteassist.action.STOP_SCREEN_SHARE"
        const val EXTRA_SESSION_ID = "session_id"
        const val EXTRA_RESULT_CODE = "result_code"
        const val EXTRA_CAPTURE_DATA = "capture_data"

        private const val CHANNEL_ID = "remote_session"
        private const val NOTIFICATION_ID = 4107
        private const val SCREEN_READY_PUBLISH_ATTEMPTS = 4
        private const val SCREEN_READY_RETRY_BASE_MS = 500L
        private const val SCREEN_READY_RETRY_MAX_MS = 4_000L
        private const val BACKEND_LIVE_PUBLISH_ATTEMPTS = 7
        private const val BACKEND_LIVE_RETRY_BASE_MS = 750L
        private const val BACKEND_LIVE_RETRY_MAX_MS = 6_000L
    }
}
