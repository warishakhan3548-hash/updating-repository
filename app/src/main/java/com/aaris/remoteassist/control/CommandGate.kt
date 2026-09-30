package com.aaris.remoteassist.control

import com.aaris.remoteassist.session.SessionRuntime
import java.util.concurrent.atomic.AtomicLong

object CommandGate {
    private val lastSequence = AtomicLong(-1L)

    fun accept(command: RemoteCommand): Boolean {
        if (!SessionRuntime.isAuthorized(
                command.sessionId,
                command.leaseSecret,
                command.generation
            )
        ) return false

        while (true) {
            val previous = lastSequence.get()
            if (command.sequence <= previous) return false
            if (lastSequence.compareAndSet(previous, command.sequence)) return true
        }
    }

    fun reset() {
        lastSequence.set(-1L)
    }
}
