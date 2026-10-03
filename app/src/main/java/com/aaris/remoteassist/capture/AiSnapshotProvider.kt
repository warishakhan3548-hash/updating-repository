package com.aaris.remoteassist.capture

import android.os.SystemClock
import java.util.concurrent.atomic.AtomicReference
import kotlinx.coroutines.CompletableDeferred
import kotlinx.coroutines.withTimeout
import org.webrtc.VideoSink

data class AiRawFrame(val nv21: ByteArray, val width: Int, val height: Int, val rotation: Int, val receivedAtMs: Long)

/** Copies only requested frames. Never retain a SurfaceTexture frame across callbacks:
 * retaining it as a "latest frame" can stop WebRTC's producer from delivering the next one. */
class AiSnapshotProvider(private val track: ScreenCaptureTrack) : AutoCloseable {
    private data class Pending(val result: CompletableDeferred<AiRawFrame>)
    private val pending = AtomicReference<Pending?>(null)
    private val sink = VideoSink { frame ->
        val request = pending.get() ?: return@VideoSink
        if (!pending.compareAndSet(request, null)) return@VideoSink
        val waiter = request.result
        val i420 = frame.buffer.toI420()
        if (i420 == null) waiter.completeExceptionally(IllegalStateException("CAPTURE_UNAVAILABLE")) else {
            try {
                waiter.complete(AiRawFrame(FrameImageEncoder.toNv21(i420), i420.width, i420.height, frame.rotation, SystemClock.elapsedRealtime()))
            } catch (error: Throwable) { waiter.completeExceptionally(error) }
            finally { i420.release() }
        }
    }
    init { track.addSnapshotSink(sink) }
    suspend fun fresh(): AiRawFrame {
        val waiter = CompletableDeferred<AiRawFrame>()
        val request = Pending(waiter)
        check(pending.compareAndSet(null, request)) { "CAPTURE_BUSY" }
        return try {
            track.requestSnapshot()
            withTimeout(2500) { waiter.await() }
        } finally { pending.compareAndSet(request, null) }
    }
    override fun close() {
        track.removeSnapshotSink(sink)
        pending.getAndSet(null)?.result?.cancel()
    }
}
