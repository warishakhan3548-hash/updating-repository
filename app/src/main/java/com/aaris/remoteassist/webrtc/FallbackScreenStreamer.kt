package com.aaris.remoteassist.webrtc

import android.graphics.ImageFormat
import android.graphics.Rect
import android.graphics.YuvImage
import java.io.ByteArrayOutputStream
import java.nio.ByteBuffer
import java.util.concurrent.Executors
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicLong
import org.webrtc.VideoFrame
import org.webrtc.VideoSink
import org.webrtc.VideoTrack

/**
 * Low-FPS compatibility stream used only when primary RTP video is black.
 *
 * It consumes the SAME already-consented MediaProjection-backed VideoTrack,
 * converts an occasional frame to JPEG and sends it over a separate unordered
 * DataChannel. This avoids creating a second VirtualDisplay (important on
 * Android 14+) and cannot block the control channel.
 */
class FallbackScreenStreamer(
    private val track: VideoTrack,
    private val sendPacket: (ByteArray) -> Boolean,
    private val onDiagnostic: (String) -> Unit
) : AutoCloseable {
    private val enabled = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)
    private val encoding = AtomicBoolean(false)
    private val lastFrameAtMs = AtomicLong(0L)
    private val frameSequence = AtomicLong(0L)
    private val worker =
        Executors.newSingleThreadExecutor { runnable ->
            Thread(
                runnable,
                "AarisFallbackVideo"
            ).apply {
                priority = Thread.NORM_PRIORITY - 1
            }
        }

    private val sink = VideoSink { frame ->
        if (
            closed.get() ||
            !enabled.get()
        ) {
            return@VideoSink
        }

        val now = System.nanoTime() / 1_000_000L
        val previous = lastFrameAtMs.get()
        if (
            previous != 0L &&
            now - previous < FRAME_INTERVAL_MS
        ) {
            return@VideoSink
        }
        if (!lastFrameAtMs.compareAndSet(previous, now)) {
            return@VideoSink
        }
        if (!encoding.compareAndSet(false, true)) {
            return@VideoSink
        }

        frame.retain()
        worker.execute {
            try {
                encodeAndSend(frame)
            } finally {
                frame.release()
                encoding.set(false)
            }
        }
    }

    init {
        track.addSink(sink)
    }

    fun enable() {
        if (
            closed.get() ||
            !enabled.compareAndSet(false, true)
        ) {
            return
        }

        onDiagnostic(
            "Compatibility screen stream ENABLED over fallback DataChannel"
        )
    }

    fun disable() {
        if (enabled.compareAndSet(true, false)) {
            onDiagnostic(
                "Compatibility screen stream disabled"
            )
        }
    }

    private fun encodeAndSend(frame: VideoFrame) {
        if (
            closed.get() ||
            !enabled.get()
        ) {
            return
        }

        val i420 = frame.buffer.toI420() ?: return
        try {
            val width = i420.width
            val height = i420.height
            if (
                width <= 1 ||
                height <= 1 ||
                width > MAX_DIMENSION ||
                height > MAX_DIMENSION
            ) {
                return
            }

            val nv21 = toNv21(i420)
            val output =
                ByteArrayOutputStream(
                    minOf(
                        MAX_JPEG_ESTIMATE_BYTES,
                        width * height / 2
                    )
                )

            val encoded = YuvImage(
                nv21,
                ImageFormat.NV21,
                width,
                height,
                null
            ).compressToJpeg(
                Rect(0, 0, width, height),
                JPEG_QUALITY,
                output
            )
            if (!encoded) return

            val jpeg = output.toByteArray()
            if (
                jpeg.isEmpty() ||
                jpeg.size > MAX_JPEG_BYTES
            ) {
                return
            }

            val id = frameSequence.incrementAndGet()
            val packets =
                FallbackVideoProtocol.encodeFrame(
                    frameId = id,
                    width = width,
                    height = height,
                    rotation =
                        normalizeRotation(frame.rotation),
                    jpeg = jpeg
                )

            var allSent = true
            for (packet in packets) {
                if (!sendPacket(packet)) {
                    /*
                     * One missing chunk makes this best-effort JPEG frame
                     * undecodable. Stop immediately instead of filling the
                     * unordered DataChannel with chunks the receiver can never
                     * assemble. The next sampled frame is more valuable.
                     */
                    allSent = false
                    break
                }
            }

            if (
                allSent &&
                id == 1L
            ) {
                onDiagnostic(
                    "First compatibility JPEG frame sent (" +
                        jpeg.size +
                        " bytes)"
                )
            }
        } finally {
            i420.release()
        }
    }

    private fun toNv21(
        buffer: VideoFrame.I420Buffer
    ): ByteArray {
        val width = buffer.width
        val height = buffer.height
        val chromaWidth = (width + 1) / 2
        val chromaHeight = (height + 1) / 2
        val ySize = width * height
        val result =
            ByteArray(
                ySize +
                    (chromaWidth * chromaHeight * 2)
            )

        copyPlane(
            source = buffer.dataY,
            sourceStride = buffer.strideY,
            planeWidth = width,
            planeHeight = height,
            destination = result,
            destinationOffset = 0,
            destinationStride = width
        )

        val u = buffer.dataU.duplicate()
        val v = buffer.dataV.duplicate()
        var out = ySize

        for (row in 0 until chromaHeight) {
            val uRow = row * buffer.strideU
            val vRow = row * buffer.strideV

            for (column in 0 until chromaWidth) {
                result[out++] = v.get(vRow + column)
                result[out++] = u.get(uRow + column)
            }
        }

        return result
    }

    private fun copyPlane(
        source: ByteBuffer,
        sourceStride: Int,
        planeWidth: Int,
        planeHeight: Int,
        destination: ByteArray,
        destinationOffset: Int,
        destinationStride: Int
    ) {
        val src = source.duplicate()
        var dstRow = destinationOffset

        for (row in 0 until planeHeight) {
            val srcRow = row * sourceStride
            for (column in 0 until planeWidth) {
                destination[dstRow + column] =
                    src.get(srcRow + column)
            }
            dstRow += destinationStride
        }
    }

    private fun normalizeRotation(value: Int): Int =
        when (((value % 360) + 360) % 360) {
            in 45..134 -> 90
            in 135..224 -> 180
            in 225..314 -> 270
            else -> 0
        }

    override fun close() {
        if (!closed.compareAndSet(false, true)) return

        enabled.set(false)
        runCatching { track.removeSink(sink) }
        worker.shutdownNow()
    }

    companion object {
        /*
         * HIGH capture tops out at a 2400 px long side. Keep the fallback
         * safety bound above that tier so a capable phone never loses its black
         * screen recovery solely because the primary capture is high quality.
         */
        private const val MAX_DIMENSION = 2560
        private const val FRAME_INTERVAL_MS = 450L
        private const val JPEG_QUALITY = 62
        private const val MAX_JPEG_BYTES = 720_000
        private const val MAX_JPEG_ESTIMATE_BYTES = 320_000
    }
}
