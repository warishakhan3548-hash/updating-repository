package com.aaris.remoteassist.capture

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Test
import org.webrtc.JavaI420Buffer

class FrameImageEncoderTest {
    @Test fun paddedI420PlanesProducePackedNv21WithoutStrideArtifacts() {
        fun plane(vararg values: Int): ByteBuffer = ByteBuffer.allocateDirect(values.size).apply {
            values.forEach { put(it.toByte()) }; rewind()
        }
        val buffer = JavaI420Buffer.wrap(2, 2, plane(10, 20, 99, 99, 30, 40, 99, 99), 4,
            plane(50, 99), 2, plane(60, 99), 2, null)
        try { assertArrayEquals(byteArrayOf(10, 20, 30, 40, 60, 50), FrameImageEncoder.toNv21(buffer)) }
        finally { buffer.release() }
    }
}
