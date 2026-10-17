package com.aaris.remoteassist.control

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/**
 * One-clock applied-ACK-to-next-swap responsiveness proxy.
 *
 * We cannot prove which encoded frame first contains a UI mutation without
 * putting application metadata into the video bitstream. Instead, authoritative
 * commands already receive CommandResult after the host applies them. The first
 * real EGL swap observed after that ACK measures this ordering:
 *
 *   input sent -> host applied -> ACK received -> next EGL swap
 *
 * That swap may still show a frame captured BEFORE the command, especially with
 * receiver buffering. It is neither a bound nor proof of the action becoming
 * visible. Keep the legacy field/wire names for compatibility; diagnostics must
 * call this a proxy. True input-to-photon needs a frame/action correlation marker
 * or an external optical measurement. It remains only a promotion gate.
 */
internal data class InputToGlassSample(
    val sequence: Long,
    val upperBoundMs: Int,
    val commandAckMs: Int,
    val postAckPresentMs: Int
)

internal class InputToGlassTracker {
    /*
     * EglRenderer calls onPresented() on the latency-critical render lane.
     * Pending ACK ownership is therefore lock-free: the common no-input path is
     * one AtomicReference read, and a completed probe is claimed with CAS.
     */
    private val pending = AtomicReference<AppliedCommandAck?>(null)
    private val lastCompletedSequence = AtomicLong(0L)

    /*
     * Rolling diagnostics are deliberately off the render lane. record() is
     * called after ControllerWebRtcSession hops to its main/session handler.
     */
    private val upperBoundSamples = ArrayDeque<Int>()
    private val postAckSamples = ArrayDeque<Int>()

    fun applied(ack: AppliedCommandAck) {
        if (
            ack.ackLatencyMs !in 0..MAX_INPUT_TO_GLASS_MS
        ) {
            return
        }

        while (true) {
            if (ack.sequence <= lastCompletedSequence.get()) return

            val current = pending.get()
            if (current != null && ack.sequence <= current.sequence) {
                return
            }

            // Freshness-first: if two authoritative commands are applied before
            // the next swap, the newer command is the one the user now cares about.
            if (pending.compareAndSet(current, ack)) {
                return
            }
        }
    }

    fun onPresented(presentedAtMs: Long): InputToGlassSample? {
        while (true) {
            val ack = pending.get() ?: return null

            /*
             * A completion can race a newer ACK on another thread. Never let an
             * older sequence survive after the completion watermark advanced.
             */
            if (ack.sequence <= lastCompletedSequence.get()) {
                pending.compareAndSet(ack, null)
                continue
            }

            if (presentedAtMs < ack.acknowledgedAtMs) return null

            val upper = presentedAtMs - ack.sentAtMs
            val postAck = presentedAtMs - ack.acknowledgedAtMs
            if (
                upper !in 0..MAX_INPUT_TO_GLASS_MS ||
                postAck !in 0..MAX_POST_ACK_PRESENT_MS
            ) {
                if (!pending.compareAndSet(ack, null)) {
                    continue
                }
                markCompleted(ack.sequence)
                return null
            }

            val sample =
                InputToGlassSample(
                    sequence = ack.sequence,
                    upperBoundMs = upper.toInt(),
                    commandAckMs = ack.ackLatencyMs.toInt(),
                    postAckPresentMs = postAck.toInt()
                )

            /*
             * Claim exactly the ACK we measured. If a fresher command replaced
             * it while this swap was being processed, retry against that newer
             * command instead of clearing user-relevant evidence.
             */
            if (!pending.compareAndSet(ack, null)) {
                continue
            }

            markCompleted(ack.sequence)
            return sample
        }
    }

    /**
     * Record a completed proxy sample after leaving the EGL render thread.
     */
    @Synchronized
    fun record(sample: InputToGlassSample) {
        upperBoundSamples.addLast(sample.upperBoundMs)
        postAckSamples.addLast(sample.postAckPresentMs)
        while (upperBoundSamples.size > MAX_SAMPLES) {
            upperBoundSamples.removeFirst()
        }
        while (postAckSamples.size > MAX_SAMPLES) {
            postAckSamples.removeFirst()
        }
    }

    @Synchronized
    fun summary(): String {
        if (upperBoundSamples.isEmpty()) {
            return "ACK/swap proxy: waiting for applied input + EGL swap"
        }

        val upper = upperBoundSamples.sorted()
        val postAck = postAckSamples.sorted()
        fun percentile(values: List<Int>, percent: Int): Int =
            values[
                ((values.size * percent + 99) / 100 - 1)
                    .coerceIn(0, values.lastIndex)
            ]

        return "ACK/swap proxy p50=${percentile(upper, 50)}ms " +
            "p95=${percentile(upper, 95)}ms " +
            "postAck p95=${percentile(postAck, 95)}ms " +
            "n=${upper.size}"
    }

    fun reset() {
        pending.set(null)
        lastCompletedSequence.set(0L)
        synchronized(this) {
            upperBoundSamples.clear()
            postAckSamples.clear()
        }
    }

    private fun markCompleted(sequence: Long) {
        while (true) {
            val current = lastCompletedSequence.get()
            if (sequence <= current) return
            if (lastCompletedSequence.compareAndSet(current, sequence)) {
                return
            }
        }
    }

    private companion object {
        const val MAX_INPUT_TO_GLASS_MS = 30_000L
        const val MAX_POST_ACK_PRESENT_MS = 5_000L
        const val MAX_SAMPLES = 64
    }
}
