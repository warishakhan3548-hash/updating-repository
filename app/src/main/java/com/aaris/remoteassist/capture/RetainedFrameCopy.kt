package com.aaris.remoteassist.capture

import org.webrtc.VideoFrame

/** Consumes ONE owned frame reference. Release its GPU texture before JPEG/delta work. */
internal object RetainedFrameCopy {
    fun <T> use(frame: VideoFrame, maxSide: Int = Int.MAX_VALUE, encode: (VideoFrame.I420Buffer, Int) -> T): T? {
        val rotation = frame.rotation
        var scaled: VideoFrame.Buffer? = null
        val cpu = try {
            val source = frame.buffer
            val ratio = minOf(1.0, maxSide.toDouble() / maxOf(source.width, source.height))
            if (ratio < 1.0) scaled = source.cropAndScale(0, 0, source.width, source.height,
                (source.width * ratio).toInt().let { it / 2 * 2 }.coerceAtLeast(2),
                (source.height * ratio).toInt().let { it / 2 * 2 }.coerceAtLeast(2))
            (scaled ?: source).toI420()
        } finally {
            try { scaled?.release() } finally { frame.release() }
        }
        if (cpu == null) return null
        return try { encode(cpu, rotation) } finally { cpu.release() }
    }
}
