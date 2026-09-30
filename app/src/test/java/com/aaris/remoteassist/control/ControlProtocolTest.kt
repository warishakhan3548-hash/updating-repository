package com.aaris.remoteassist.control

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

class ControlProtocolTest {
    @Test
    fun helloRoundTrips() {
        val source = ControlPacket.Hello(
            leaseSecret = 42L,
            generation = 7,
            widthPx = 1080,
            heightPx = 2400
        )

        assertEquals(
            source,
            ControlProtocol.decode(ControlProtocol.encode(source))
        )
    }

    @Test
    fun tapRoundTripsWithSmallQuantizationError() {
        val source = ControlPacket.Tap(
            leaseSecret = 91L,
            generation = 4,
            sequence = 99L,
            nx = 0.3333f,
            ny = 0.7777f
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        ) as ControlPacket.Tap

        assertEquals(source.leaseSecret, decoded.leaseSecret)
        assertEquals(source.generation, decoded.generation)
        assertEquals(source.sequence, decoded.sequence)
        assertEquals(source.nx, decoded.nx, 0.00002f)
        assertEquals(source.ny, decoded.ny, 0.00002f)
    }

    @Test
    fun recentsRoundTrips() {
        val source = ControlPacket.Recents(
            leaseSecret = 11L,
            generation = 2,
            sequence = 7L
        )

        assertEquals(
            source,
            ControlProtocol.decode(ControlProtocol.encode(source))
        )
    }

    @Test
    fun textRoundTripsAndConvertsToCommand() {
        val source = ControlPacket.Text(
            leaseSecret = 12L,
            generation = 3,
            sequence = 8L,
            text = "Hello नमस्ते"
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        )
        assertEquals(source, decoded)

        val command = ControlProtocol.toRemoteCommand(
            sessionId = "s1",
            packet = source,
            widthPx = 100,
            heightPx = 200
        )
        assertTrue(command is SetTextCommand)
        assertEquals(
            source.text,
            (command as SetTextCommand).text
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun oversizedTextFailsClosed() {
        ControlProtocol.encode(
            ControlPacket.Text(
                leaseSecret = 1L,
                generation = 1,
                sequence = 1L,
                text = "x".repeat(3000)
            )
        )
    }

    @Test
    fun packetConvertsToRemotePixels() {
        val command = ControlProtocol.toRemoteCommand(
            sessionId = "s1",
            packet = ControlPacket.Tap(
                leaseSecret = 5L,
                generation = 3,
                sequence = 8L,
                nx = 0.5f,
                ny = 0.25f
            ),
            widthPx = 1000,
            heightPx = 2000
        )

        assertNotNull(command)
        assertTrue(command is TapCommand)

        val tap = command as TapCommand
        assertEquals(499.5f, tap.xPx, 0.01f)
        assertEquals(499.75f, tap.yPx, 0.01f)
    }
}
