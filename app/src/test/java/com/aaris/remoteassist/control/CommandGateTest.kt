package com.aaris.remoteassist.control

import com.aaris.remoteassist.session.SessionRuntime
import org.junit.After
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test

class CommandGateTest {
    private lateinit var leaseSessionId: String
    private var leaseSecret: Long = 0L
    private var generation: Int = 0

    @Before
    fun setUp() {
        CommandGate.reset()
        SessionRuntime.reset()
        leaseSessionId = "command-gate-test"
        generation = 7
        leaseSecret =
            SessionRuntime.activate(
                sessionId = leaseSessionId,
                displayGeneration = generation,
                leaseMs = 60_000L
            ).leaseSecret
    }

    @After
    fun tearDown() {
        CommandGate.reset()
        SessionRuntime.reset()
    }

    @Test
    fun freshContinueArrivingBeforeStartDoesNotPoisonAuthoritativeClock() {
        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 2L,
                    phase = GestureStreamPhase.CONTINUE
                )
            )
        )

        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 1L,
                    phase = GestureStreamPhase.START
                )
            )
        )

        assertFalse(
            CommandGate.accept(
                streamCommand(
                    sequence = 2L,
                    phase = GestureStreamPhase.CONTINUE
                )
            )
        )

        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 3L,
                    phase = GestureStreamPhase.CONTINUE
                )
            )
        )

        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 4L,
                    phase = GestureStreamPhase.END
                )
            )
        )

        assertTrue(
            CommandGate.accept(
                TapCommand(
                    sessionId = leaseSessionId,
                    leaseSecret = leaseSecret,
                    generation = generation,
                    sequence = 5L,
                    xPx = 100f,
                    yPx = 200f
                )
            )
        )
    }

    @Test
    fun replayProtectionRemainsIndependentOnBothLanes() {
        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 10L,
                    phase = GestureStreamPhase.START
                )
            )
        )
        assertFalse(
            CommandGate.accept(
                streamCommand(
                    sequence = 10L,
                    phase = GestureStreamPhase.END
                )
            )
        )

        assertTrue(
            CommandGate.accept(
                streamCommand(
                    sequence = 20L,
                    phase = GestureStreamPhase.CONTINUE
                )
            )
        )
        assertFalse(
            CommandGate.accept(
                streamCommand(
                    sequence = 19L,
                    phase = GestureStreamPhase.CONTINUE
                )
            )
        )
    }

    private fun streamCommand(
        sequence: Long,
        phase: GestureStreamPhase
    ) = GestureStreamCommand(
        sessionId = leaseSessionId,
        leaseSecret = leaseSecret,
        generation = generation,
        sequence = sequence,
        streamId = 42L,
        phase = phase,
        points = listOf(
            RemotePathPoint(100f, 200f)
        ),
        durationMs = 32L
    )
}
