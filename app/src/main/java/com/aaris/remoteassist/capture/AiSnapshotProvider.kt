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
    private data class Pending(
        val result: CompletableDeferred<AiRawFrame>,
        val maxLongSidePx: Int
    )

    private val pending = AtomicReference<Pending?>(null)

    private val sink = VideoSink { frame ->
        val request = pending.get() ?: return@VideoSink
        if (!pending.compareAndSet(request, null)) return@VideoSink

        val waiter = request.result
        val source = frame.buffer
        val (targetWidth, targetHeight) =
            aiSnapshotDimensions(
                width = source.width,
                height = source.height,
                maxLongSidePx = request.maxLongSidePx
            )

        val scaled = runCatching {
            source.cropAndScale(
                0,
                0,
                source.width,
                source.height,
                targetWidth,
                targetHeight
            )
        }.getOrElse { error ->
            waiter.completeExceptionally(error)
            return@VideoSink
        }

        val i420 = runCatching {
            scaled.toI420()
        }.getOrElse { error ->
            scaled.release()
            waiter.completeExceptionally(error)
            return@VideoSink
        }
        scaled.release()

        if (i420 == null) {
            waiter.completeExceptionally(
                IllegalStateException("CAPTURE_UNAVAILABLE")
            )
        } else {
            try {
                waiter.complete(
                    AiRawFrame(
                        nv21 = FrameImageEncoder.toNv21(i420),
                        width = i420.width,
                        height = i420.height,
                        rotation = frame.rotation,
                        receivedAtMs = SystemClock.elapsedRealtime()
                    )
                )
            } catch (error: Throwable) {
                waiter.completeExceptionally(error)
            } finally {
                i420.release()
            }
        }
    }

    init {
        track.addSnapshotSink(sink)
    }

    suspend fun fresh(
        maxLongSidePx: Int = Int.MAX_VALUE
    ): AiRawFrame {
        val waiter = CompletableDeferred<AiRawFrame>()
        val request =
            Pending(
                result = waiter,
                maxLongSidePx =
                    maxLongSidePx.coerceAtLeast(2)
            )
        check(pending.compareAndSet(null, request)) {
            "CAPTURE_BUSY"
        }
        return try {
            track.requestSnapshot()
            withTimeout(2500) {
                waiter.await()
            }
        } finally {
            pending.compareAndSet(request, null)
        }
    }
    override fun close() {
        track.removeSnapshotSink(sink)
        pending.getAndSet(null)?.result?.cancel()
    }
}

internal fun aiSnapshotDimensions(
    width: Int,
    height: Int,
    maxLongSidePx: Int
): Pair<Int, Int> {
    require(width > 0 && height > 0)
    val boundedLongSide = maxLongSidePx.coerceAtLeast(2)
    val sourceLongSide = maxOf(width, height)
    if (sourceLongSide <= boundedLongSide) {
        return width to height
    }

    val scale =
        boundedLongSide.toDouble() /
            sourceLongSide.toDouble()

    fun scaledEven(value: Int): Int {
        val rounded =
            (value * scale)
                .toInt()
                .coerceAtLeast(2)
        return if (rounded % 2 == 0) {
            rounded
        } else {
            (rounded - 1).coerceAtLeast(2)
        }
    }

    return scaledEven(width) to scaledEven(height)
}
