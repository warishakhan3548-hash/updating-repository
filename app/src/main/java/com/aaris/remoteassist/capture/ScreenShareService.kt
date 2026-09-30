package com.aaris.remoteassist.capture

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder
import com.aaris.remoteassist.accessibility.AssistAccessibilityService
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.pairing.FirebasePairingGateway
import com.aaris.remoteassist.session.SessionRuntime
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

class ScreenShareService : Service() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)
    private var sessionId: String? = null

    override fun onCreate() {
        super.onCreate()
        getSystemService(NotificationManager::class.java).createNotificationChannel(
            NotificationChannel(
                CHANNEL_ID,
                "Live remote support",
                NotificationManager.IMPORTANCE_LOW
            )
        )
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                val id = intent.getStringExtra(EXTRA_SESSION_ID) ?: return START_NOT_STICKY
                sessionId = id
                startVisibleSession(id)
                AssistAccessibilityService.showStopOverlay(id)
                // The MediaProjection consent Intent is intentionally retained for the
                // WebRTC screen capturer, which must consume it exactly once.
                ProjectionGrantStore.put(
                    sessionId = id,
                    resultCode = intent.getIntExtra(EXTRA_RESULT_CODE, 0),
                    permissionData = intent.permissionIntent()
                        ?: return stopAndReturn()
                )
            }
            ACTION_STOP -> stopSession(intent.getStringExtra(EXTRA_SESSION_ID))
        }
        return START_NOT_STICKY
    }

    private fun startVisibleSession(sessionId: String) {
        val stopPendingIntent = PendingIntent.getService(
            this,
            91,
            stopIntent(this, sessionId),
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("Aaris Remote is live")
            .setContentText("Your screen is ready to share.")
            .setSmallIcon(android.R.drawable.presence_video_online)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    null,
                    "STOP",
                    stopPendingIntent
                ).build()
            )
            .build()

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

    private fun stopSession(requestedId: String?) {
        val id = requestedId ?: sessionId
        ProjectionGrantStore.clear(id)
        SessionRuntime.reset()
        CommandGate.reset()
        AssistAccessibilityService.removeStopOverlay()
        stopForeground(STOP_FOREGROUND_REMOVE)

        if (id == null) {
            stopSelf()
            return
        }

        scope.launch {
            runCatching { FirebasePairingGateway().close(id) }
            stopSelf()
        }
    }

    private fun stopAndReturn(): Int {
        stopSession(sessionId)
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        AssistAccessibilityService.removeStopOverlay()
        scope.cancel()
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    @Suppress("DEPRECATION")
    private fun Intent.permissionIntent(): Intent? =
        if (Build.VERSION.SDK_INT >= 33) {
            getParcelableExtra(EXTRA_PERMISSION_DATA, Intent::class.java)
        } else {
            getParcelableExtra(EXTRA_PERMISSION_DATA)
        }

    companion object {
        private const val CHANNEL_ID = "live_remote_support"
        private const val NOTIFICATION_ID = 4107

        private const val ACTION_START = "com.aaris.remoteassist.START_SHARE"
        private const val ACTION_STOP = "com.aaris.remoteassist.STOP_SHARE"
        private const val EXTRA_SESSION_ID = "sessionId"
        private const val EXTRA_CONTROLLER_UID = "controllerUid"
        private const val EXTRA_RESULT_CODE = "resultCode"
        private const val EXTRA_PERMISSION_DATA = "permissionData"

        fun start(
            context: Context,
            sessionId: String,
            controllerUid: String,
            resultCode: Int,
            permissionData: Intent
        ) {
            val intent = Intent(context, ScreenShareService::class.java)
                .setAction(ACTION_START)
                .putExtra(EXTRA_SESSION_ID, sessionId)
                .putExtra(EXTRA_CONTROLLER_UID, controllerUid)
                .putExtra(EXTRA_RESULT_CODE, resultCode)
                .putExtra(EXTRA_PERMISSION_DATA, permissionData)
            if (Build.VERSION.SDK_INT >= 26) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        }

        fun stopIntent(context: Context, sessionId: String): Intent =
            Intent(context, ScreenShareService::class.java)
                .setAction(ACTION_STOP)
                .putExtra(EXTRA_SESSION_ID, sessionId)
    }
}
