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
    private data class Pending(
        val result: CompletableDeferred<AiRawFrame>,
        val maxSide: Int
    )
    private val pending = AtomicReference<Pending?>(null)
    private val closed = AtomicBoolean(false)
    private val conversionInFlight = AtomicBoolean(false)
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
        /*
         * Never enqueue frame.buffer or the original GPU-backed VideoFrame.
         * Ownership still has to cross the texture boundary synchronously, but
         * normal AI/fingerprint work does not need a 2400px readback. Scale the
         * texture first and then copy only the requested pixel budget to I420.
         * CpuFrameCopy returns an independently owned buffer and preserves
         * rotation while keeping the SurfaceTexture producer releasable before
         * this callback returns.
         */
        val cpu = try {
            CpuFrameCopy.capture(
                frame = frame,
                maxSide = request.maxSide
            ) ?: throw IllegalStateException("CAPTURE_UNAVAILABLE")
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
                                FrameImageEncoder.toNv21(cpu.buffer),
                                cpu.buffer.width,
                                cpu.buffer.height,
                                cpu.rotation,
                                SystemClock.elapsedRealtime()
                            )
                        )
                    }
                } catch (error: Throwable) {
                    request.result.completeExceptionally(error)
                } finally {
                    cpu.close()
                    conversionInFlight.set(false)
                }
            }
        } catch (error: RejectedExecutionException) {
            cpu.close()
            conversionInFlight.set(false)
            request.result.completeExceptionally(error)
        }
    }

    init { track.addSnapshotSink(sink) }

    suspend fun fresh(): AiRawFrame =
        captureFresh(NORMAL_MAX_SIDE)

    suspend fun freshDetail(): AiRawFrame =
        captureFresh(DETAIL_MAX_SIDE)

    private suspend fun captureFresh(maxSide: Int): AiRawFrame {
        check(!closed.get()) { "CAPTURE_STOPPED" }
        check(!conversionInFlight.get()) { "CAPTURE_BUSY" }
        require(maxSide >= 2) { "INVALID_SNAPSHOT_SIZE" }
        val waiter = CompletableDeferred<AiRawFrame>()
        val request =
            Pending(
                result = waiter,
                maxSide = maxSide
            )
        check(pending.compareAndSet(null, request)) { "CAPTURE_BUSY" }
        return try {
            track.requestSnapshot()
            withTimeout(2500) { waiter.await() }
        } finally {
            pending.compareAndSet(request, null)
        }
    }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return
        track.removeSnapshotSink(sink)
        pending.getAndSet(null)?.result?.cancel()
        // Do not use shutdownNow(): a queued task owns a CPU I420 buffer and
        // its finally block must release it, even after the provider closes.
        converter.shutdown()
    }

    private companion object {
        // Matches the cloud observation encoder's ordinary/detail ceilings.
        const val NORMAL_MAX_SIDE = 1_280
        const val DETAIL_MAX_SIDE = 2_400
    }
}
