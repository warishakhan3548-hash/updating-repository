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
    fun commandResultRoundTrips() {
        val applied = ControlPacket.CommandResult(
            sequence = 41L,
            applied = true
        )
        val rejected = ControlPacket.CommandResult(
            sequence = 42L,
            applied = false
        )

        assertEquals(
            applied,
            ControlProtocol.decode(
                ControlProtocol.encode(applied)
            )
        )
        assertEquals(
            rejected,
            ControlProtocol.decode(
                ControlProtocol.encode(rejected)
            )
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
    fun swipeRoundTrips() {
        val source = ControlPacket.Swipe(
            leaseSecret = 44L,
            generation = 6,
            sequence = 100L,
            fromNx = 0.12f,
            fromNy = 0.22f,
            toNx = 0.88f,
            toNy = 0.72f,
            durationMs = 340
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        ) as ControlPacket.Swipe

        assertEquals(source.leaseSecret, decoded.leaseSecret)
        assertEquals(source.generation, decoded.generation)
        assertEquals(source.sequence, decoded.sequence)
        assertEquals(source.fromNx, decoded.fromNx, 0.00002f)
        assertEquals(source.fromNy, decoded.fromNy, 0.00002f)
        assertEquals(source.toNx, decoded.toNx, 0.00002f)
        assertEquals(source.toNy, decoded.toNy, 0.00002f)
        assertEquals(source.durationMs, decoded.durationMs)
    }

    @Test
    fun gesturePathRoundTripsAndMapsToPixels() {
        val source = ControlPacket.GesturePath(
            leaseSecret = 55L,
            generation = 9,
            sequence = 102L,
            points = listOf(
                ControlPathPoint(0.10f, 0.20f),
                ControlPathPoint(0.35f, 0.45f),
                ControlPathPoint(0.80f, 0.90f)
            ),
            durationMs = 510
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        ) as ControlPacket.GesturePath

        assertEquals(source.leaseSecret, decoded.leaseSecret)
        assertEquals(source.generation, decoded.generation)
        assertEquals(source.sequence, decoded.sequence)
        assertEquals(source.points.size, decoded.points.size)
        assertEquals(
            source.points[1].nx,
            decoded.points[1].nx,
            0.00002f
        )
        assertEquals(
            source.points[2].ny,
            decoded.points[2].ny,
            0.00002f
        )
        assertEquals(source.durationMs, decoded.durationMs)

        val command = ControlProtocol.toRemoteCommand(
            sessionId = "s1",
            packet = decoded,
            widthPx = 1000,
            heightPx = 2000
        )
        assertTrue(command is GesturePathCommand)

        val path = command as GesturePathCommand
        assertEquals(3, path.points.size)
        assertEquals(349.65f, path.points[1].xPx, 0.05f)
        assertEquals(1799.1f, path.points[2].yPx, 0.1f)
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsTooShortGesturePath() {
        ControlProtocol.encode(
            ControlPacket.GesturePath(
                leaseSecret = 1L,
                generation = 1,
                sequence = 1L,
                points = listOf(
                    ControlPathPoint(0.5f, 0.5f)
                ),
                durationMs = 200
            )
        )
    }

    @Test(expected = IllegalArgumentException::class)
    fun rejectsOversizedGesturePath() {
        ControlProtocol.encode(
            ControlPacket.GesturePath(
                leaseSecret = 1L,
                generation = 1,
                sequence = 1L,
                points = List(97) {
                    ControlPathPoint(0.5f, 0.5f)
                },
                durationMs = 200
            )
        )
    }

    @Test
    fun twoFingerRoundTripsAndMapsToPixels() {
        val source = ControlPacket.TwoFinger(
            leaseSecret = 77L,
            generation = 5,
            sequence = 101L,
            firstFromNx = 0.25f,
            firstFromNy = 0.30f,
            firstToNx = 0.15f,
            firstToNy = 0.20f,
            secondFromNx = 0.75f,
            secondFromNy = 0.70f,
            secondToNx = 0.85f,
            secondToNy = 0.80f,
            durationMs = 420
        )

        val decoded = ControlProtocol.decode(
            ControlProtocol.encode(source)
        ) as ControlPacket.TwoFinger

        assertEquals(source.leaseSecret, decoded.leaseSecret)
        assertEquals(source.generation, decoded.generation)
        assertEquals(source.sequence, decoded.sequence)
        assertEquals(source.firstFromNx, decoded.firstFromNx, 0.00002f)
        assertEquals(source.secondToNy, decoded.secondToNy, 0.00002f)
        assertEquals(source.durationMs, decoded.durationMs)

        val command = ControlProtocol.toRemoteCommand(
            sessionId = "s1",
            packet = decoded,
            widthPx = 1000,
            heightPx = 2000
        )
        assertTrue(command is TwoFingerCommand)

        val twoFinger = command as TwoFingerCommand
        assertEquals(249.75f, twoFinger.firstFromXPx, 0.02f)
        assertEquals(1599.2f, twoFinger.secondToYPx, 0.05f)
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
    fun primaryVideoReadyRoundTrips() {
        val source =
            ControlPacket.PrimaryVideoReady(
                leaseSecret = 88L
            )

        assertEquals(
            source,
            ControlProtocol.decode(
                ControlProtocol.encode(source)
            )
        )
    }

    @Test
    fun rejectsWrongProtocolVersion() {
        val encoded = ControlProtocol.encode(
            ControlPacket.Heartbeat(7L)
        )
        encoded[0] = 99
        org.junit.Assert.assertNull(
            ControlProtocol.decode(encoded)
        )
    }

    @Test
    fun rejectsTruncatedCommandPacket() {
        val encoded = ControlProtocol.encode(
            ControlPacket.Tap(
                leaseSecret = 1L,
                generation = 1,
                sequence = 1L,
                nx = 0.5f,
                ny = 0.5f
            )
        )
        org.junit.Assert.assertNull(
            ControlProtocol.decode(
                encoded.copyOf(encoded.size - 1)
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
