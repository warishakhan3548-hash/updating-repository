package com.aaris.remoteassist.capture

import org.junit.Assert.*
import org.junit.Test
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame
import java.nio.ByteBuffer

class RetainedFrameCopyTest {
    private class Source : VideoFrame.Buffer {
        var refs = 1
        var cpuReleased = false
        var crop: List<Int>? = null
        override fun getWidth() = 1080
        override fun getHeight() = 2400
        override fun retain() { refs++ }
        override fun release() { refs--; check(refs >= 0) }
        override fun cropAndScale(x: Int, y: Int, w: Int, h: Int, outW: Int, outH: Int): VideoFrame.Buffer {
            crop = listOf(x, y, w, h, outW, outH)
            retain()
            return this
        }
        override fun toI420(): VideoFrame.I420Buffer = JavaI420Buffer.wrap(2, 2,
            ByteBuffer.allocateDirect(4), 2, ByteBuffer.allocateDirect(1), 1, ByteBuffer.allocateDirect(1), 1,
            Runnable { cpuReleased = true })
    }

    @Test fun jpegWorkDoesNotHoldTheProducerTexture() {
        val source = Source()
        val result = RetainedFrameCopy.use(VideoFrame(source, 90, 100), maxSide = 1600) { _, rotation ->
            assertEquals("Surface producer must be free BEFORE JPEG/delta/network work", 0, source.refs)
            assertFalse(source.cpuReleased)
            assertEquals(90, rotation)
            "encoded"
        }
        assertEquals("encoded", result)
        assertEquals(listOf(0, 0, 1080, 2400, 720, 1600), source.crop)
        assertTrue(source.cpuReleased)
    }

    @Test fun failedEncodingStillReleasesCpuAndTextureReferences() {
        val source = Source()
        try {
            RetainedFrameCopy.use(VideoFrame(source, 0, 100)) { _, _ -> throw IllegalArgumentException("encode failed") }
            fail("Expected encoder failure")
        } catch (_: IllegalArgumentException) { }
        assertEquals(0, source.refs)
        assertTrue(source.cpuReleased)
        assertNull("Idle detail uses the original source", source.crop)
    }
}
