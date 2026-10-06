package com.aaris.remoteassist.capture

import java.io.Closeable
import java.util.concurrent.CopyOnWriteArraySet
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.webrtc.VideoFrame
import org.webrtc.VideoSink

/**
 * Keeps non-RTP consumers completely off the MediaProjection / SurfaceTexture
 * callback.
 *
 * The mailbox holds at most one retained frame. If an auxiliary consumer is
 * slower than capture, the pending frame is replaced with the newest one
 * instead of forming a queue of obsolete screenshots. Primary RTP is always
 * admitted before this dispatcher is touched.
 *
 * The executor is lazy: no worker thread is created until an auxiliary sink is
 * actually attached and a frame arrives, so the normal healthy primary path
 * pays only an empty-set check.
 */
internal class LatestFrameSnapshotDispatcher(
    private val sinks: CopyOnWriteArraySet<VideoSink>
) : Closeable {
    private val closed = AtomicBoolean(false)
    private val draining = AtomicBoolean(false)
    private val pending = AtomicReference<VideoFrame?>(null)
    private val worker =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                runnable,
                "AarisSnapshotDispatch"
            ).apply {
                priority = Thread.NORM_PRIORITY - 1
            }
        }

    fun offer(frame: VideoFrame) {
        if (closed.get() || sinks.isEmpty()) return

        frame.retain()
        if (closed.get()) {
            frame.release()
            return
        }

        pending.getAndSet(frame)?.release()
        scheduleDrain()
    }

    private fun scheduleDrain() {
        if (closed.get()) {
            pending.getAndSet(null)?.release()
            return
        }
        if (!draining.compareAndSet(false, true)) return

        try {
            worker.execute(::drain)
        } catch (_: RejectedExecutionException) {
            draining.set(false)
            pending.getAndSet(null)?.release()
        }
    }

    private fun drain() {
        try {
            while (!closed.get()) {
                val frame = pending.getAndSet(null) ?: break
                try {
                    for (sink in sinks) {
                        if (closed.get()) break
                        runCatching { sink.onFrame(frame) }
                    }
                } finally {
                    frame.release()
                }
            }
        } finally {
            draining.set(false)
            /*
             * A producer may replace pending after this worker observed null
             * but before draining=false became visible. Re-check once so that
             * race cannot strand the newest retained frame.
             */
            if (!closed.get() && pending.get() != null) {
                scheduleDrain()
            }
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        pending.getAndSet(null)?.release()
        worker.shutdownNow()
    }
}
