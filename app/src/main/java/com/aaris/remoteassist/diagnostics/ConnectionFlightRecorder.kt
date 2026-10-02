package com.aaris.remoteassist.diagnostics

import android.os.SystemClock
import java.util.ArrayDeque
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArraySet

/**
 * In-process connection flight recorder shared by the foreground Activity,
 * MediaProjection service and WebRTC sessions.
 *
 * It deliberately stores only stage names/timing. No pairing codes, tokens,
 * SDP bodies, ICE addresses or remote screen content are recorded.
 */
object ConnectionFlightRecorder {
    private data class Trace(
        val startedAtMs: Long,
        val lines: ArrayDeque<String>
    )

    private val traces = ConcurrentHashMap<String, Trace>()
    private val listeners =
        CopyOnWriteArraySet<(String, String) -> Unit>()

    @Synchronized
    fun reset(sessionId: String, side: String) {
        val trace = Trace(
            startedAtMs = SystemClock.elapsedRealtime(),
            lines = ArrayDeque()
        )
        traces[sessionId] = trace
        appendLocked(
            sessionId = sessionId,
            trace = trace,
            message = "$side monitor started",
            failure = false
        )
    }

    fun pass(sessionId: String, message: String) {
        append(sessionId, message, false)
    }

    fun fail(sessionId: String, message: String) {
        append(sessionId, message, true)
    }

    fun snapshot(sessionId: String): String =
        synchronized(this) {
            traces[sessionId]
                ?.lines
                ?.joinToString("\n")
                .orEmpty()
        }

    fun addListener(
        listener: (sessionId: String, report: String) -> Unit
    ) {
        listeners += listener
    }

    fun removeListener(
        listener: (sessionId: String, report: String) -> Unit
    ) {
        listeners -= listener
    }

    @Synchronized
    private fun append(
        sessionId: String,
        message: String,
        failure: Boolean
    ) {
        val trace = traces.getOrPut(sessionId) {
            Trace(
                startedAtMs = SystemClock.elapsedRealtime(),
                lines = ArrayDeque()
            )
        }
        appendLocked(sessionId, trace, message, failure)
    }

    private fun appendLocked(
        sessionId: String,
        trace: Trace,
        message: String,
        failure: Boolean
    ) {
        val elapsedMs =
            (SystemClock.elapsedRealtime() - trace.startedAtMs)
                .coerceAtLeast(0L)
        val seconds = elapsedMs / 1_000L
        val tenths = (elapsedMs % 1_000L) / 100L
        val marker = if (failure) "✕" else "✓"
        val line = "[+$seconds.$tenths s] $marker $message"

        if (trace.lines.lastOrNull() == line) return
        trace.lines.addLast(line)
        while (trace.lines.size > MAX_LINES) {
            trace.lines.removeFirst()
        }

        val report = trace.lines.joinToString("\n")
        listeners.forEach { listener ->
            runCatching { listener(sessionId, report) }
        }
    }

    private const val MAX_LINES = 12
}
