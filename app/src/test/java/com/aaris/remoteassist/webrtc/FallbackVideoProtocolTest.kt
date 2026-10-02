package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FallbackVideoProtocolTest {
    @Test
    fun reassemblesChunkedJpegFrame() {
        val jpeg = ByteArray(31_337) { index ->
            (index % 251).toByte()
        }

        val packets = FallbackVideoProtocol.encodeFrame(
            frameId = 7L,
            width = 960,
            height = 540,
            rotation = 90,
            jpeg = jpeg
        )

        assertTrue(packets.size > 1)

        val reassembler =
            FallbackVideoProtocol.Reassembler()

        var result: FallbackVideoFrame? = null
        packets.forEach { packet ->
            result = reassembler.offer(packet) ?: result
        }

        val frame = checkNotNull(result)
        assertEquals(7L, frame.frameId)
        assertEquals(960, frame.width)
        assertEquals(540, frame.height)
        assertEquals(90, frame.rotation)
        assertArrayEquals(jpeg, frame.jpeg)
    }

    @Test
    fun highTierRecoveryFrameFitsGeometryAndBudget() {
        val jpeg = ByteArray(720_000) { index ->
            (index % 239).toByte()
        }

        val packets = FallbackVideoProtocol.encodeFrame(
            frameId = 8L,
            width = 1080,
            height = 2400,
            rotation = 0,
            jpeg = jpeg
        )

        assertEquals(60, packets.size)

        val reassembler =
            FallbackVideoProtocol.Reassembler()
        var result: FallbackVideoFrame? = null
        packets.forEach { packet ->
            result = reassembler.offer(packet) ?: result
        }

        val frame = checkNotNull(result)
        assertEquals(1080, frame.width)
        assertEquals(2400, frame.height)
        assertArrayEquals(jpeg, frame.jpeg)
    }

    @Test
    fun incompleteOldFrameIsDroppedWhenNewerFrameArrives() {
        val oldPackets =
            FallbackVideoProtocol.encodeFrame(
                frameId = 10L,
                width = 320,
                height = 240,
                rotation = 0,
                jpeg = ByteArray(24_500) { 1 }
            )
        val newPackets =
            FallbackVideoProtocol.encodeFrame(
                frameId = 11L,
                width = 320,
                height = 240,
                rotation = 0,
                jpeg = ByteArray(900) { 2 }
            )

        val reassembler =
            FallbackVideoProtocol.Reassembler()

        assertNull(reassembler.offer(oldPackets.first()))

        var newFrame: FallbackVideoFrame? = null
        newPackets.forEach { packet ->
            newFrame =
                reassembler.offer(packet)
                    ?: newFrame
        }

        assertEquals(11L, checkNotNull(newFrame).frameId)

        // Late chunks from frame 10 must never replace newer pixels.
        assertNull(reassembler.offer(oldPackets.last()))
    }
}
