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
    fun recentsRoundTripsAndMapsToGlobalAction() {
        val source = ControlPacket.Recents(
            leaseSecret = 77L,
            generation = 2,
            sequence = 11L
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        )
        assertEquals(source, decoded)

        val command = ControlProtocol.toRemoteCommand(
            sessionId = "s-recents",
            packet = source,
            widthPx = 1080,
            heightPx = 2400
        )

        assertTrue(command is GlobalActionCommand)
        assertEquals(
            GlobalAction.RECENTS,
            (command as GlobalActionCommand).action
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
