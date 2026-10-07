package com.aaris.remoteassist.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.aaris.remoteassist.backend.CloudflareBackend
import com.aaris.remoteassist.diagnostics.ConnectionFlightRecorder
import com.aaris.remoteassist.session.SessionCoordinator
import java.io.File
import java.util.concurrent.Executors

/**
 * Debug-only metrics exporter used by CI dual-emulator tests.
 * Release builds do not contain this receiver.
 */
class E2eDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DUMP) return

        val pending = goAsync()
        val appContext = context.applicationContext
        EXECUTOR.execute {
            try {
                dump(appContext, intent)
            } finally {
                pending.finish()
            }
        }
    }

    private fun dump(context: Context, intent: Intent) {
        val label =
            intent.getStringExtra(EXTRA_LABEL)
                ?.replace(Regex("[^A-Za-z0-9_.-]"), "_")
                ?.take(48)
                ?.takeIf(String::isNotBlank)
                ?: "sample"

        val prefs =
            context.getSharedPreferences(
                "setup",
                Context.MODE_PRIVATE
            )
        val hostSession =
            prefs.getString(
                KEY_ACTIVE_HOST_SESSION,
                null
            )
        val controllerSession =
            prefs.getString(
                KEY_PENDING_CONTROLLER_SESSION,
                null
            )
        val sessionId =
            hostSession ?: controllerSession
        val local =
            SessionCoordinator.snapshot()
        val backendState =
            sessionId?.let { id ->
                runCatching {
                    CloudflareBackend
                        .sessionRequest(
                            context = context,
                            sessionId = id,
                            method = "GET"
                        )
                        .getJSONObject("session")
                        .optString("state", "-")
                }.getOrElse { error ->
                    "ERROR:${error.javaClass.simpleName}:" +
                        error.message.orEmpty().take(160)
                }
            } ?: "-"

        val qd =
            sessionId
                ?.let(ConnectionFlightRecorder::snapshot)
                .orEmpty()

        val state = E2eMotionState
        val now = SystemClock.elapsedRealtime()
        val elapsed =
            if (state.startedAtMs > 0L) {
                (now - state.startedAtMs).coerceAtLeast(0L)
            } else {
                0L
            }

        val body =
            buildString {
                appendLine("label=$label")
                appendLine("session=${sessionId ?: "-"}")
                appendLine("side=" +
                    when {
                        hostSession != null -> "host"
                        controllerSession != null -> "controller"
                        else -> "idle"
                    }
                )
                appendLine("local_state=${local.state}")
                appendLine("local_session=${local.sessionId ?: "-"}")
                appendLine("local_generation=${local.displayGeneration}")
                appendLine("backend_state=$backendState")
                appendLine("elapsed_ms=$elapsed")
                appendLine("frame_callbacks=${state.frameCallbacks}")
                appendLine("draw_calls=${state.drawCalls}")
                appendLine("touch_events=${state.touchEvents}")
                appendLine("gesture_starts=${state.gestureStarts}")
                appendLine("gesture_ends=${state.gestureEnds}")
                appendLine("last_x=${state.lastX}")
                appendLine("last_y=${state.lastY}")
                appendLine(
                    "last_touch_age_ms=" +
                        if (state.lastTouchAtMs > 0L) {
                            (now - state.lastTouchAtMs)
                                .coerceAtLeast(0L)
                        } else {
                            -1L
                        }
                )
                appendLine("---- QD ----")
                append(qd)
            }

        val dir =
            File(
                context.getExternalFilesDir(null),
                "dual-e2e"
            )
        dir.mkdirs()
        File(dir, "$label.txt").writeText(body)
    }

    private companion object {
        const val ACTION_DUMP =
            "com.aaris.remoteassist.debug.DUMP_E2E"
        const val EXTRA_LABEL = "label"
        const val KEY_ACTIVE_HOST_SESSION =
            "active_host_session"
        const val KEY_PENDING_CONTROLLER_SESSION =
            "pending_controller_session"
        val EXECUTOR = Executors.newSingleThreadExecutor()
    }
}
