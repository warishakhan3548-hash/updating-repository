package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class FallbackDeltaProtocolTest {
    @Test
    fun reassemblesAtomicMultiPatchDelta() {
        val first = ByteArray(18_500) { (it % 251).toByte() }
        val second = ByteArray(9_300) { (it % 239).toByte() }
        val frame = FallbackDeltaFrame(
            frameId = 12L,
            baseFrameId = 11L,
            width = 1080,
            height = 2400,
            rotation = 0,
            shiftX = 0,
            shiftY = -96,
            patches = listOf(
                FallbackDeltaPatch(0, 2304, 1080, 96, first),
                FallbackDeltaPatch(0, 0, 192, 192, second)
            )
        )

        val packets = FallbackDeltaProtocol.encode(frame)
        assertTrue(packets.size > 1)

        val reassembler = FallbackDeltaProtocol.Reassembler()
        var result: FallbackDeltaFrame? = null
        packets.forEach { packet ->
            result = reassembler.offer(packet) ?: result
        }

        val decoded = checkNotNull(result)
        assertEquals(12L, decoded.frameId)
        assertEquals(11L, decoded.baseFrameId)
        assertEquals(-96, decoded.shiftY)
        assertEquals(2, decoded.patches.size)
        assertArrayEquals(first, decoded.patches[0].jpeg)
        assertArrayEquals(second, decoded.patches[1].jpeg)
    }

    @Test
    fun newerDeltaSupersedesIncompleteOlderDelta() {
        val oldPackets = FallbackDeltaProtocol.encode(
            FallbackDeltaFrame(
                frameId = 20L,
                baseFrameId = 19L,
                width = 400,
                height = 800,
                rotation = 0,
                shiftX = 0,
                shiftY = 0,
                patches = listOf(
                    FallbackDeltaPatch(
                        0,
                        0,
                        400,
                        400,
                        ByteArray(30_000) { 1 }
                    )
                )
            )
        )
        val freshPackets = FallbackDeltaProtocol.encode(
            FallbackDeltaFrame(
                frameId = 21L,
                baseFrameId = 20L,
                width = 400,
                height = 800,
                rotation = 0,
                shiftX = 0,
                shiftY = 0,
                patches = listOf(
                    FallbackDeltaPatch(
                        0,
                        0,
                        100,
                        100,
                        ByteArray(700) { 2 }
                    )
                )
            )
        )

        val reassembler = FallbackDeltaProtocol.Reassembler()
        assertNull(reassembler.offer(oldPackets.first()))

        var fresh: FallbackDeltaFrame? = null
        freshPackets.forEach { packet ->
            fresh = reassembler.offer(packet) ?: fresh
        }
        assertEquals(21L, checkNotNull(fresh).frameId)

        assertNull(reassembler.offer(oldPackets.last()))
    }
}
