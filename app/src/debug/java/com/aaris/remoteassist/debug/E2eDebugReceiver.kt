package com.aaris.remoteassist.debug

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.SystemClock
import com.aaris.remoteassist.diagnostics.ConnectionFlightRecorder
import java.io.File

/**
 * Debug-only metrics exporter used by CI dual-emulator tests.
 * Release builds do not contain this receiver.
 */
class E2eDebugReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != ACTION_DUMP) return

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
        val sessionId =
            prefs.getString(
                KEY_ACTIVE_HOST_SESSION,
                null
            )
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
                appendLine("elapsed_ms=$elapsed")
                appendLine("frame_callbacks=${state.frameCallbacks}")
                appendLine("draw_calls=${state.drawCalls}")
                appendLine("touch_events=${state.touchEvents}")
                appendLine("gesture_starts=${state.gestureStarts}")
                appendLine("gesture_ends=${state.gestureEnds}")
                appendLine("last_x=${state.lastX}")
                appendLine("last_y=${state.lastY}")
                appendLine("last_touch_age_ms=" +
                    if (state.lastTouchAtMs > 0L) {
                        (now - state.lastTouchAtMs).coerceAtLeast(0L)
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
        resultCode = android.app.Activity.RESULT_OK
        resultData = "wrote:$label"
    }

    private companion object {
        const val ACTION_DUMP =
            "com.aaris.remoteassist.debug.DUMP_E2E"
        const val EXTRA_LABEL = "label"
        const val KEY_ACTIVE_HOST_SESSION =
            "active_host_session"
    }
}
