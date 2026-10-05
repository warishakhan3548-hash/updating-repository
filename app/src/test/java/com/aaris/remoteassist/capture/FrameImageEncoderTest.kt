package com.aaris.remoteassist.capture

import java.nio.ByteBuffer
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
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

    @Test fun normalizedRegionMapsToBoundedPixelCrop() {
        val rect =
            FrameImageEncoder.cropBounds(
                region =
                    AiImageRegion(
                        left = 0.10,
                        top = 0.20,
                        right = 0.60,
                        bottom = 0.80
                    ),
                width = 101,
                height = 203
            )

        assertTrue(rect.left == 10)
        assertTrue(rect.top == 40)
        assertTrue(rect.right == 61)
        assertTrue(rect.bottom == 163)
        assertTrue(rect.right > rect.left)
        assertTrue(rect.bottom > rect.top)
    }

    @Test fun directNv21FastPathIsLimitedToTransformFreeFrames() {
        val frame =
            AiRawFrame(
                nv21 = ByteArray(12),
                width = 4,
                height = 2,
                rotation = 0,
                receivedAtMs = 0
            )

        assertTrue(
            FrameImageEncoder.canUseDirectNv21Path(
                frame = frame,
                maxSide = 4,
                masks = emptyList(),
                hideAll = false
            )
        )
        assertFalse(
            FrameImageEncoder.canUseDirectNv21Path(
                frame = frame.copy(rotation = 90),
                maxSide = 4,
                masks = emptyList(),
                hideAll = false
            )
        )
        assertFalse(
            FrameImageEncoder.canUseDirectNv21Path(
                frame = frame,
                maxSide = 2,
                masks = emptyList(),
                hideAll = false
            )
        )
        assertFalse(
            FrameImageEncoder.canUseDirectNv21Path(
                frame = frame,
                maxSide = 4,
                masks = listOf(android.graphics.Rect(0, 0, 1, 1)),
                hideAll = false
            )
        )
        assertFalse(
            FrameImageEncoder.canUseDirectNv21Path(
                frame = frame,
                maxSide = 4,
                masks = emptyList(),
                hideAll = true
            )
        )
    }
}
