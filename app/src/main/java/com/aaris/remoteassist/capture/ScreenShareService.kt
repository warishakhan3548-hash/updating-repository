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
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.session.SessionCoordinator
import com.aaris.remoteassist.session.SessionState
import com.aaris.remoteassist.ui.MainActivity
import com.aaris.remoteassist.webrtc.HostWebRtcSession
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ScreenShareService : Service() {
    private val scope = CoroutineScope(
        SupervisorJob() + Dispatchers.IO
    )

    private val mainHandler = Handler(Looper.getMainLooper())

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

        hostSession?.close()
        hostSession = null

        if (id != null) {
            ProjectionGrantStore.clear(id)
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
            stopSelf()
            return
        }

        activeSessionId = sessionId
        startVisibleForeground()

        val grant = ProjectionGrant(
            sessionId = sessionId,
            resultCode = resultCode,
            data = captureData
        )
        ProjectionGrantStore.offer(
            sessionId,
            resultCode,
            captureData
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

        scope.launch {
            runCatching {
                FirebasePairingGateway(this@ScreenShareService)
                    .markScreenReady(sessionId)
            }.onSuccess {
                mainHandler.post {
                    if (activeSessionId == sessionId) {
                        startTransport(sessionId, grant)
                    }
                }
            }.onFailure {
                mainHandler.post {
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

        hostSession = runCatching {
            HostWebRtcSession(
                context = this,
                sessionId = sessionId,
                projectionGrant = grant,
                listener = object : HostWebRtcSession.Listener {
                    override fun onLive() {
                        scope.launch {
                            runCatching {
                                FirebasePairingGateway(
                                    this@ScreenShareService
                                ).markLive(sessionId)
                            }.onFailure {
                                mainHandler.post {
                                    stopActiveSession(
                                        "backend_live_state_failed"
                                    )
                                }
                            }
                        }
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

                    override fun onError(error: Throwable) {
                        mainHandler.post {
                            stopActiveSession(
                                "webrtc_transport_failed"
                            )
                        }
                    }
                }
            ).also { it.start() }
        }.getOrElse {
            stopActiveSession("webrtc_start_failed")
            null
        }
    }

    private fun stopActiveSession(reason: String) {
        val sessionId = activeSessionId
        activeSessionId = null

        hostSession?.close()
        hostSession = null

        if (sessionId != null) {
            ProjectionGrantStore.clear(sessionId)
            SessionCoordinator.close(sessionId)

            BackendSessionCloser.close(this, sessionId)
        }

        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    private fun startVisibleForeground() {
        val notification = buildNotification()
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

    private fun buildNotification(): Notification {
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

        return Notification.Builder(this, CHANNEL_ID)
            .setSmallIcon(
                android.R.drawable.presence_video_online
            )
            .setContentTitle("Aaris Remote is sharing")
            .setContentText(
                "Screen sharing is active. Tap STOP any time."
            )
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
    }
}
