package com.aaris.remoteassist.capture

import java.util.concurrent.atomic.AtomicBoolean
import org.webrtc.VideoFrame

/**
 * Owns an I420 copy that is independent of the capture SurfaceTexture.
 *
 * The GPU-to-CPU handoff is intentionally completed while the capturer callback
 * still owns the source frame. Background fallback work may keep this CPU buffer,
 * but it must never retain the SurfaceTexture producer across callbacks.
 */
internal class CpuFrameCopy private constructor(
    val buffer: VideoFrame.I420Buffer,
    val rotation: Int
) : AutoCloseable {
    private val closed = AtomicBoolean(false)

    override fun close() {
        if (closed.compareAndSet(false, true)) {
            buffer.release()
        }
    }

    companion object {
        fun capture(
            frame: VideoFrame,
            maxSide: Int = Int.MAX_VALUE
        ): CpuFrameCopy? {
            val source = frame.buffer
            val ratio =
                minOf(
                    1.0,
                    maxSide.toDouble() /
                        maxOf(source.width, source.height)
                )
            var scaled: VideoFrame.Buffer? = null
            val cpu = try {
                if (ratio < 1.0) {
                    val outputWidth =
                        (source.width * ratio)
                            .toInt()
                            .let { it / 2 * 2 }
                            .coerceAtLeast(2)
                    val outputHeight =
                        (source.height * ratio)
                            .toInt()
                            .let { it / 2 * 2 }
                            .coerceAtLeast(2)
                    scaled =
                        source.cropAndScale(
                            0,
                            0,
                            source.width,
                            source.height,
                            outputWidth,
                            outputHeight
                        )
                }
                (scaled ?: source).toI420()
            } finally {
                scaled?.release()
            } ?: return null

            return CpuFrameCopy(
                buffer = cpu,
                rotation = frame.rotation
            )
        }
    }
}
