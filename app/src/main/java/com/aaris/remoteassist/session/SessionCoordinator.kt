package com.aaris.remoteassist.session

import com.aaris.remoteassist.control.CommandGate
import java.util.concurrent.CopyOnWriteArraySet

object SessionCoordinator {
    private val listeners = CopyOnWriteArraySet<(SessionSnapshot) -> Unit>()

    @Volatile
    private var machine = SessionStateMachine()

    fun snapshot(): SessionSnapshot = machine.snapshot()

    @Synchronized
    fun reset() {
        machine = SessionStateMachine()
        SessionRuntime.reset()
        CommandGate.reset()
        publish(machine.snapshot())
    }

    @Synchronized
    fun prepareReady(): SessionSnapshot {
        val current = machine.snapshot()
        if (current.state == SessionState.CLOSED) {
            machine = SessionStateMachine()
        }

        val next = when (machine.snapshot().state) {
            SessionState.IDLE -> transitionInternal(null, SessionState.READY)
            SessionState.SETUP_REQUIRED -> transitionInternal(null, SessionState.READY)
            SessionState.READY -> machine.snapshot()
            else -> machine.snapshot()
        }
        publish(next)
        return next
    }

    @Synchronized
    fun markSetupRequired(): SessionSnapshot {
        val current = machine.snapshot()
        val next = if (current.state == SessionState.IDLE) {
            transitionInternal(null, SessionState.SETUP_REQUIRED)
        } else {
            current
        }
        publish(next)
        return next
    }

    @Synchronized
    fun transition(sessionId: String?, next: SessionState): SessionSnapshot {
        val updated = transitionInternal(sessionId, next)
        publish(updated)
        return updated
    }

    @Synchronized
    fun activateLive(sessionId: String): LiveLease {
        val current = machine.snapshot()
        require(current.sessionId == sessionId)
        val live = if (current.state == SessionState.CONNECTING) {
            transitionInternal(sessionId, SessionState.LIVE)
        } else {
            require(current.state == SessionState.LIVE)
            current
        }
        val lease = SessionRuntime.activate(
            sessionId = sessionId,
            displayGeneration = live.displayGeneration
        )
        CommandGate.reset()
        publish(live)
        return lease
    }

    @Synchronized
    fun bumpDisplayGeneration(sessionId: String): LiveLease? {
        val current = machine.snapshot()
        if (current.sessionId != sessionId) return null
        if (
            current.state != SessionState.LIVE &&
            current.state != SessionState.CONNECTING
        ) {
            return null
        }

        val lease = SessionRuntime.currentLease() ?: return null
        val updatedSnapshot = machine.bumpDisplayGeneration(
            System.nanoTime() / 1_000_000L
        )
        val updatedLease = SessionRuntime.rotateDisplayGeneration(
            sessionId = sessionId,
            leaseSecret = lease.leaseSecret,
            generation = updatedSnapshot.displayGeneration
        )
        CommandGate.reset()
        publish(updatedSnapshot)
        return updatedLease
    }

    @Synchronized
    fun close(sessionId: String? = null): SessionSnapshot {
        val current = machine.snapshot()
        if (
            sessionId != null &&
            current.sessionId != null &&
            current.sessionId != sessionId
        ) {
            return current
        }

        val closed = if (current.state != SessionState.CLOSED) {
            runCatching {
                transitionInternal(current.sessionId, SessionState.CLOSED)
            }.getOrElse { current }
        } else {
            current
        }

        SessionRuntime.reset()
        CommandGate.reset()
        publish(closed)
        return closed
    }

    fun addListener(listener: (SessionSnapshot) -> Unit) {
        listeners += listener
        listener(machine.snapshot())
    }

    fun removeListener(listener: (SessionSnapshot) -> Unit) {
        listeners -= listener
    }

    private fun transitionInternal(
        sessionId: String?,
        next: SessionState
    ): SessionSnapshot = machine.transition(
        sessionId = sessionId,
        next = next,
        nowElapsedMs = System.nanoTime() / 1_000_000L
    )

    private fun publish(snapshot: SessionSnapshot) {
        listeners.forEach { listener ->
            runCatching { listener(snapshot) }
        }
    }
}
