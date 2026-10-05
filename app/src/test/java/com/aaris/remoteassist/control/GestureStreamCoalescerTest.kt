package com.aaris.remoteassist.control

import org.junit.Assert.assertEquals
import org.junit.Test

class GestureStreamCoalescerTest {
    @Test
    fun supersededContinueGeometryIsCarriedIntoNewestSegment() {
        val previous = command(
            sequence = 1L,
            phase = GestureStreamPhase.CONTINUE,
            values = listOf(1f, 2f),
            durationMs = 24L
        )
        val incoming = command(
            sequence = 2L,
            phase = GestureStreamPhase.CONTINUE,
            values = listOf(3f, 4f),
            durationMs = 20L
        )

        val merged =
            GestureStreamCoalescer.merge(
                superseded = listOf(previous),
                incoming = incoming
            )

        assertEquals(2L, merged.sequence)
        assertEquals(GestureStreamPhase.CONTINUE, merged.phase)
        assertEquals(
            listOf(1f, 2f, 3f, 4f),
            merged.points.map { it.xPx }
        )
        assertEquals(44L, merged.durationMs)
    }

    @Test
    fun authoritativeEndKeepsQueuedCurveBeforeFinalPoint() {
        val previous = command(
            sequence = 10L,
            phase = GestureStreamPhase.CONTINUE,
            values = listOf(10f, 20f, 30f),
            durationMs = 36L
        )
        val end = command(
            sequence = 11L,
            phase = GestureStreamPhase.END,
            values = listOf(40f),
            durationMs = 18L
        )

        val merged =
            GestureStreamCoalescer.merge(
                superseded = listOf(previous),
                incoming = end
            )

        assertEquals(GestureStreamPhase.END, merged.phase)
        assertEquals(
            listOf(10f, 20f, 30f, 40f),
            merged.points.map { it.xPx }
        )
        assertEquals(54L, merged.durationMs)
    }

    @Test
    fun mergedBacklogStaysInsideSixteenPointAndDurationBounds() {
        val first = command(
            sequence = 20L,
            phase = GestureStreamPhase.CONTINUE,
            values = (0..15).map(Int::toFloat),
            durationMs = 80L
        )
        val second = command(
            sequence = 21L,
            phase = GestureStreamPhase.CONTINUE,
            values = (16..31).map(Int::toFloat),
            durationMs = 80L
        )
        val incoming = command(
            sequence = 22L,
            phase = GestureStreamPhase.END,
            values = listOf(32f),
            durationMs = 80L
        )

        val merged =
            GestureStreamCoalescer.merge(
                superseded = listOf(first, second),
                incoming = incoming
            )

        assertEquals(16, merged.points.size)
        assertEquals(0f, merged.points.first().xPx)
        assertEquals(32f, merged.points.last().xPx)
        assertEquals(120L, merged.durationMs)
    }

    @Test
    fun incompatibleQueuedStreamCannotContaminateIncomingGesture() {
        val other = command(
            sequence = 30L,
            phase = GestureStreamPhase.CONTINUE,
            values = listOf(5f, 6f),
            durationMs = 30L,
            streamId = 99L
        )
        val incoming = command(
            sequence = 31L,
            phase = GestureStreamPhase.END,
            values = listOf(7f),
            durationMs = 20L,
            streamId = 7L
        )

        assertEquals(
            incoming,
            GestureStreamCoalescer.merge(
                superseded = listOf(other),
                incoming = incoming
            )
        )
    }

    private fun command(
        sequence: Long,
        phase: GestureStreamPhase,
        values: List<Float>,
        durationMs: Long,
        streamId: Long = 7L
    ): GestureStreamCommand =
        GestureStreamCommand(
            sessionId = "session",
            leaseSecret = 42L,
            generation = 3,
            sequence = sequence,
            streamId = streamId,
            phase = phase,
            points = values.map { value ->
                RemotePathPoint(
                    xPx = value,
                    yPx = value + 0.5f
                )
            },
            durationMs = durationMs
        )
}
