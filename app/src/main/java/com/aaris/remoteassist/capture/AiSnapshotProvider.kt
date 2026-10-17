package com.aaris.remoteassist.capture

import android.os.SystemClock
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.webrtc.VideoSink

data class AiRawFrame(val nv21: ByteArray, val width: Int, val height: Int, val rotation: Int, val receivedAtMs: Long)

/**
 * The texture-to-I420 handoff must finish inside the capturer callback: retaining
 * a SurfaceTexture frame asynchronously would prevent the next capture frame.
 * The expensive planar-to-NV21 CPU conversion, however, has no GL dependency.
 * Complete it on a single independent worker so AI screenshot requests cannot
 * monopolize the real-time WebRTC capture callback.
 *
 * Only one request can be outstanding; the worker queue cannot grow with FPS.
 */
class AiSnapshotProvider(private val track: ScreenCaptureTrack) : AutoCloseable {
    private data class Pending(val result: CompletableDeferred<AiRawFrame>)
    private val pending = AtomicReference<Pending?>(null)
    private val closed = AtomicBoolean(false)
    private val conversionInFlight = AtomicBoolean(false)
    private val sinkLock = Any()
    private var sinkAttached = false
    private val converter = Executors.newSingleThreadExecutor { task ->
        Thread(task, "AarisAiSnapshotConversion").apply {
            priority = Thread.NORM_PRIORITY - 1
        }
    }

    private val sink = VideoSink { frame ->
        if (closed.get()) return@VideoSink
        val request = pending.get() ?: return@VideoSink
        if (!conversionInFlight.compareAndSet(false, true)) return@VideoSink
        if (!pending.compareAndSet(request, null)) {
            conversionInFlight.set(false)
            return@VideoSink
        }
        val rotation = frame.rotation

        // Never enqueue frame.buffer or the original GPU-backed VideoFrame.
        // toI420() yields an independently owned CPU buffer.
        val cpu = try {
            frame.buffer.toI420()
                ?: throw IllegalStateException("CAPTURE_UNAVAILABLE")
        } catch (error: Throwable) {
            request.result.completeExceptionally(error)
            conversionInFlight.set(false)
            return@VideoSink
        }

        try {
            converter.execute {
                try {
                    if (closed.get()) {
                        request.result.cancel()
                    } else {
                        request.result.complete(
                            AiRawFrame(
                                FrameImageEncoder.toNv21(cpu),
                                cpu.width,
                                cpu.height,
                                rotation,
                                SystemClock.elapsedRealtime()
                            )
                        )
                    }
                } catch (error: Throwable) {
                    request.result.completeExceptionally(error)
                } finally {
                    cpu.release()
                    conversionInFlight.set(false)
                }
            }
        } catch (error: RejectedExecutionException) {
            cpu.release()
            conversionInFlight.set(false)
            request.result.completeExceptionally(error)
        }
    }

    /*
     * Keep AI completely off the steady-state 30/45/60 fps capture fan-out.
     * The sink is needed only while one explicit screenshot request is waiting.
     * CopyOnWriteArraySet mutation happens at request boundaries, never per frame.
     */
    private fun attachSinkIfNeeded(): Boolean =
        synchronized(sinkLock) {
            if (closed.get()) {
                false
            } else {
                if (!sinkAttached) {
                    track.addSnapshotSink(sink)
                    sinkAttached = true
                }
                true
            }
        }

    private fun detachSinkIfNeeded() {
        synchronized(sinkLock) {
            if (!sinkAttached) return
            track.removeSnapshotSink(sink)
            sinkAttached = false
        }
    }

    suspend fun fresh(): AiRawFrame {
        check(!closed.get()) { "CAPTURE_STOPPED" }
        check(!conversionInFlight.get()) { "CAPTURE_BUSY" }
        val waiter = CompletableDeferred<AiRawFrame>()
        val request = Pending(waiter)
        check(pending.compareAndSet(null, request)) { "CAPTURE_BUSY" }
        return try {
            check(attachSinkIfNeeded()) { "CAPTURE_STOPPED" }
            track.requestSnapshot()
            withTimeout(2500) { waiter.await() }
        } finally {
            pending.compareAndSet(request, null)
            detachSinkIfNeeded()
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        detachSinkIfNeeded()
        pending.getAndSet(null)?.result?.cancel()
        // Do not use shutdownNow(): a queued task owns a CPU I420 buffer and
        // its finally block must release it, even after the provider closes.
        converter.shutdown()
    }
}
