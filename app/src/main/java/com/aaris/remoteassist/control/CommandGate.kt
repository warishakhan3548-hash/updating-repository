package com.aaris.remoteassist.control

import com.aaris.remoteassist.session.SessionRuntime
import java.util.concurrent.atomic.AtomicLong

object CommandGate {
    /*
     * Authoritative controls (START/END, taps, navigation, text, etc.) and
     * freshness-only live drag CONTINUE packets intentionally have independent
     * replay/order clocks.
     *
     * This is required once live CONTINUE packets use an unordered,
     * non-retransmitted SCTP lane: a newer expendable position may legitimately
     * arrive before an older reliable START. Letting that expendable packet
     * advance the authoritative clock would make the later START look stale and
     * break the whole gesture. Keeping separate monotonic clocks preserves the
     * security/replay gate while allowing low-latency motion delivery.
     */
    private val lastAuthoritativeSequence = AtomicLong(-1L)
    private val lastFreshSequence = AtomicLong(-1L)

    fun accept(command: RemoteCommand): Boolean {
        if (!SessionRuntime.isAuthorized(
                command.sessionId,
                command.leaseSecret,
                command.generation
            )
        ) return false

        val sequenceClock =
            if (
                command is GestureStreamCommand &&
                command.phase == GestureStreamPhase.CONTINUE
            ) {
                lastFreshSequence
            } else {
                lastAuthoritativeSequence
            }

        while (true) {
            val previous = sequenceClock.get()
            if (command.sequence <= previous) return false
            if (
                sequenceClock.compareAndSet(
                    previous,
                    command.sequence
                )
            ) {
                return true
            }
        }
    }

    fun reset() {
        lastAuthoritativeSequence.set(-1L)
        lastFreshSequence.set(-1L)
    }
}
