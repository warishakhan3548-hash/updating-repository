package com.aaris.remoteassist.capture

import java.nio.ByteBuffer
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.webrtc.JavaI420Buffer
import org.webrtc.VideoFrame

class CpuFrameCopyTest {
    private class Source : VideoFrame.Buffer {
        var refs = 1
        var cpuReleased = false
        var crop: List<Int>? = null

        override fun getWidth() = 1080
        override fun getHeight() = 2400
        override fun retain() { refs++ }
        override fun release() { refs--; check(refs >= 0) }
        override fun cropAndScale(
            x: Int,
            y: Int,
            w: Int,
            h: Int,
            outW: Int,
            outH: Int
        ): VideoFrame.Buffer {
            crop = listOf(x, y, w, h, outW, outH)
            retain()
            return this
        }

        override fun toI420(): VideoFrame.I420Buffer =
            JavaI420Buffer.wrap(
                2,
                2,
                ByteBuffer.allocateDirect(4),
                2,
                ByteBuffer.allocateDirect(1),
                1,
                ByteBuffer.allocateDirect(1),
                1,
                Runnable { cpuReleased = true }
            )
    }

    @Test
    fun backgroundCopyOwnsCpuButNoAdditionalProducerTextureReference() {
        val source = Source()
        val copy = CpuFrameCopy.capture(
            VideoFrame(source, 90, 100),
            maxSide = 1600
        )

        assertNotNull(copy)
        assertEquals(
            "Only the capturer callback may own the producer reference",
            1,
            source.refs
        )
        assertEquals(
            listOf(0, 0, 1080, 2400, 720, 1600),
            source.crop
        )
        assertEquals(90, copy!!.rotation)
        assertFalse(source.cpuReleased)

        copy.close()
        assertTrue(source.cpuReleased)
        assertEquals(1, source.refs)
    }

    @Test
    fun closeIsIdempotentAndDoesNotReleaseCapturerOwnedFrame() {
        val source = Source()
        val copy = checkNotNull(
            CpuFrameCopy.capture(VideoFrame(source, 0, 100))
        )

        copy.close()
        copy.close()

        assertTrue(source.cpuReleased)
        assertEquals(1, source.refs)
    }
}
