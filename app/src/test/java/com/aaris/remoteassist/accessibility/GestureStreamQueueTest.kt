package com.aaris.remoteassist.accessibility

import android.app.KeyguardManager
import android.graphics.PathMeasure
import android.os.Looper
import com.aaris.remoteassist.control.CommandGate
import com.aaris.remoteassist.control.GestureStreamCommand
import com.aaris.remoteassist.control.GestureStreamPhase
import com.aaris.remoteassist.control.RemoteCommand
import com.aaris.remoteassist.control.RemotePathPoint
import com.aaris.remoteassist.control.TapCommand
import com.aaris.remoteassist.session.LiveLease
import com.aaris.remoteassist.session.SessionRuntime
import java.time.Duration
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.annotation.GraphicsMode
import org.robolectric.annotation.LooperMode
import org.robolectric.util.ReflectionHelpers

@RunWith(RobolectricTestRunner::class)
@Config(sdk = [28], manifest = Config.NONE)
@GraphicsMode(GraphicsMode.Mode.NATIVE)
@LooperMode(LooperMode.Mode.PAUSED)
class GestureStreamQueueTest {
    private lateinit var service: AssistAccessibilityService
    private lateinit var lease: LiveLease
    private val results = mutableMapOf<Long, Boolean>()

    @Before
    fun setUp() {
        CommandGate.reset()
        lease = SessionRuntime.activate("gesture-queue-test", 7)
        service = Robolectric.buildService(AssistAccessibilityService::class.java).create().get()
        ReflectionHelpers.callInstanceMethod<Unit>(service, "onServiceConnected")
        val keyguard = service.getSystemService(KeyguardManager::class.java)
        shadowOf(keyguard).setKeyguardLocked(false)
        shadowOf(keyguard).setIsDeviceLocked(false)
        idle()
    }

    @After
    fun tearDown() {
        service.onDestroy()
        SessionRuntime.reset()
        CommandGate.reset()
    }

    @Test
    fun delayedOlderMoveCannotEvictNewerQueuedPosition() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(103))
        dispatch(stream(102))

        assertEquals(false, results[102])
        assertNull(results[103])
        completeLatest()
        assertEndpoint(103f)
        completeLatest()
        assertEquals(true, results[103])
    }

    @Test
    fun duplicateMoveCannotEvictTheOriginalQueuedSample() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(103))
        var duplicateApplied: Boolean? = null
        AssistAccessibilityService.dispatch(stream(103)) { duplicateApplied = it }
        idle()

        assertEquals(false, duplicateApplied)
        assertNull(results[103])
        completeLatest()
        assertEndpoint(103f)
        completeLatest()
        assertEquals(true, results[103])
    }

    @Test
    fun newerMoveSupersedesQueuedMotionWithoutClaimingPhysicalApplication() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(102))
        dispatch(stream(103))

        assertEquals(false, results[102])
        assertNull(results[103])
        completeLatest()
        assertEndpoint(103f)
        assertEquals(2, shadowOf(service).gesturesDispatched.size)
    }

    @Test
    fun invalidLeaseSessionGenerationAndPreconditionCannotEvictAuthorizedMotion() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(103))
        dispatch(stream(104).copy(leaseSecret = lease.leaseSecret xor 1L))
        dispatch(stream(105).copy(sessionId = "other-session"))
        dispatch(stream(106).copy(generation = lease.displayGeneration + 1))
        dispatch(stream(107), precondition = { false })

        for (sequence in 104L..107L) assertEquals(false, results[sequence])
        assertNull(results[103])
        completeLatest()
        assertEndpoint(103f)
        completeLatest()
        assertEquals(true, results[103])
    }

    @Test
    fun endSupersedesPendingMovesAndRejectsLateMotionWithoutLosingBoundaries() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(101))
        dispatch(stream(103, GestureStreamPhase.END))
        dispatch(stream(102))
        dispatch(stream(104, GestureStreamPhase.START, streamId = 2L))
        dispatch(stream(105, streamId = 2L))
        dispatch(stream(106, GestureStreamPhase.END, streamId = 2L))

        assertEquals(false, results[101])
        assertEquals(false, results[102])
        assertEquals(false, results[105])
        completeLatest()
        assertEndpoint(103f)
        completeLatest()
        assertEndpoint(104f)
        completeLatest()
        assertEndpoint(106f)
        completeLatest()
        for (sequence in listOf(100L, 103L, 104L, 106L)) {
            assertEquals(true, results[sequence])
        }
        assertEquals(4, shadowOf(service).gesturesDispatched.size)
    }

    @Test
    fun earlyFreshMoveDoesNotConsumeReliableStartsReplayClock() {
        dispatch(tap(1))
        dispatch(stream(3))
        dispatch(stream(2, GestureStreamPhase.START))

        completeLatest()

        assertEquals(false, results[3])
        assertEndpoint(2f)
        completeLatest()
        assertEquals(true, results[2])
    }

    @Test
    fun differentStreamCannotCoalesceQueuedMotion() {
        dispatch(stream(100, GestureStreamPhase.START))
        dispatch(stream(101))
        dispatch(stream(102, streamId = 2L))

        assertNull(results[101])
        completeLatest()
        assertEndpoint(101f)
        completeLatest()
        assertEquals(true, results[101])
        assertEquals(false, results[102])
    }

    @Test
    fun delayedPacketFromEndedStreamCannotCancelCurrentReleaseWatchdog() {
        dispatch(stream(100, GestureStreamPhase.START))
        completeLatest()
        dispatch(stream(103, GestureStreamPhase.END))
        completeLatest()
        dispatch(stream(104, GestureStreamPhase.START, streamId = 2L))
        completeLatest()
        dispatch(stream(102))

        assertEquals(false, results[102])
        assertEquals(3, shadowOf(service).gesturesDispatched.size)
        shadowOf(Looper.getMainLooper()).idleFor(Duration.ofMillis(1_800L))

        assertEquals(4, shadowOf(service).gesturesDispatched.size)
        assertNull(ReflectionHelpers.getField<Any?>(service, "activeGestureStream"))
    }

    @Test
    fun executionRechecksPreconditionAfterWaitingInQueue() {
        dispatch(tap(1))
        var permitted = true
        dispatch(stream(2, GestureStreamPhase.START), precondition = { permitted })
        permitted = false

        completeLatest()

        assertEquals(false, results[2])
        assertEquals(1, shadowOf(service).gesturesDispatched.size)
    }

    @Test
    fun stopRevokesQueuedGestureBeforeInjection() {
        dispatch(tap(1))
        dispatch(stream(2, GestureStreamPhase.START))
        SessionRuntime.reset()

        completeLatest()

        assertEquals(false, results[2])
        assertEquals(1, shadowOf(service).gesturesDispatched.size)
    }

    private fun stream(
        sequence: Long,
        phase: GestureStreamPhase = GestureStreamPhase.CONTINUE,
        streamId: Long = 1L
    ) = GestureStreamCommand(
        sessionId = lease.sessionId,
        leaseSecret = lease.leaseSecret,
        generation = lease.displayGeneration,
        sequence = sequence,
        streamId = streamId,
        phase = phase,
        points = if (phase == GestureStreamPhase.START) {
            listOf(
                RemotePathPoint(sequence.toFloat() - 0.5f, 200f),
                RemotePathPoint(sequence.toFloat(), 200f)
            )
        } else {
            listOf(RemotePathPoint(sequence.toFloat(), 200f))
        },
        durationMs = 16L
    )

    private fun tap(sequence: Long) = TapCommand(
        sessionId = lease.sessionId,
        leaseSecret = lease.leaseSecret,
        generation = lease.displayGeneration,
        sequence = sequence,
        xPx = 50f,
        yPx = 200f
    )

    private fun dispatch(command: RemoteCommand, precondition: () -> Boolean = { true }) {
        assertTrue(AssistAccessibilityService.dispatch(command, precondition) {
            results[command.sequence] = it
        })
        idle()
    }

    private fun completeLatest() {
        val gesture = shadowOf(service).gesturesDispatched.last()
        requireNotNull(gesture.callback()).onCompleted(gesture.description())
        idle()
    }

    private fun assertEndpoint(expectedX: Float) {
        val gesture = shadowOf(service).gesturesDispatched.last().description()
        val path = PathMeasure(gesture.getStroke(0).path, false)
        val position = FloatArray(2)
        assertTrue(path.getPosTan(path.length, position, null))
        assertEquals(expectedX, position[0], 0.01f)
    }

    private fun idle() {
        shadowOf(Looper.getMainLooper()).idle()
    }
}
