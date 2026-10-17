package com.aaris.remoteassist.capture

import java.util.concurrent.atomic.AtomicLong
import java.util.concurrent.atomic.AtomicReference

/** Keep a still screen observable without polling pixels or duplicating moving frames. */
internal class CaptureRefreshPolicy {
    private data class InteractionArm(
        val appliedAtMs: Long,
        val sampleGeneration: Long
    )

    /*
     * onSample() runs on SurfaceTextureHelper's latency-critical capture lane,
     * while Accessibility command completion arms causal refreshes from the
     * Android main thread. A monitor shared by those two 60 Hz-class paths can
     * turn ordinary lock handoff into capture jitter. Keep the producer callback
     * non-blocking: scalar evidence lives in atomics and the rare interaction
     * arm is one immutable CAS-owned record.
     */
    private val lastSampleAtMs = AtomicLong(NO_TIME)
    private val lastRequestAtMs = AtomicLong(NO_TIME)
    private val sampleGeneration = AtomicLong(0L)
    private val lastTextureTimestampNs = AtomicLong(NO_TEXTURE_TIMESTAMP)
    private val interactionArm = AtomicReference<InteractionArm?>(null)

    fun onSample(nowMs: Long, textureTimestampNs: Long? = null) {
        lastSampleAtMs.set(nowMs)

        if (textureTimestampNs != null) {
            val previous =
                lastTextureTimestampNs.getAndSet(textureTimestampNs)
            if (textureTimestampNs == previous) {
                return
            }
        }

        val generation =
            sampleGeneration.updateAndGet { previous ->
                if (previous == Long.MAX_VALUE) 1L else previous + 1L
            }

        interactionArm.get()?.let { armed ->
            if (armed.sampleGeneration != generation) {
                interactionArm.compareAndSet(armed, null)
            }
        }
    }

    /**
     * Arms one bounded post-input freshness pull.
     *
     * While the current capture generation is still waiting for its probe, keep
     * the first applied-input timestamp. Replacing it with every CONTINUE sample
     * turns a display-tick probe into a debounce and can postpone freshness for
     * the entire duration of a fast swipe.
     */
    fun onInteractionApplied(nowMs: Long) {
        if (lastSampleAtMs.get() == NO_TIME) return

        while (true) {
            val generation = sampleGeneration.get()
            val current = interactionArm.get()
            if (
                current != null &&
                current.sampleGeneration == generation
            ) {
                return
            }

            val next =
                InteractionArm(
                    appliedAtMs = nowMs,
                    sampleGeneration = generation
                )
            if (interactionArm.compareAndSet(current, next)) {
                return
            }
        }
    }

    /**
     * After one display tick, pull the current SurfaceTexture only if no natural
     * MediaProjection frame arrived after the applied input. Each interaction
     * arms at most one synthetic sample, so rapid touches cannot build a queue.
     */
    fun shouldRefreshForInteraction(nowMs: Long): Boolean {
        while (true) {
            val armed = interactionArm.get() ?: return false
            if (nowMs < armed.appliedAtMs) return false

            if (sampleGeneration.get() != armed.sampleGeneration) {
                if (interactionArm.compareAndSet(armed, null)) {
                    return false
                }
                continue
            }

            if (nowMs - armed.appliedAtMs < INTERACTION_GRACE_MS) {
                return false
            }

            if (!interactionArm.compareAndSet(armed, null)) {
                continue
            }

            lastRequestAtMs.set(nowMs)
            return true
        }
    }

    fun shouldRefresh(nowMs: Long): Boolean {
        while (true) {
            val sample = lastSampleAtMs.get()
            if (sample == NO_TIME) return false

            val request = lastRequestAtMs.get()
            val previous =
                maxOf(
                    sample,
                    if (request == NO_TIME) sample else request
                )
            if (nowMs - previous < INTERVAL_MS) return false

            if (sample != lastSampleAtMs.get()) {
                continue
            }
            if (lastRequestAtMs.compareAndSet(request, nowMs)) {
                return true
            }
        }
    }

    companion object {
        const val INTERVAL_MS = 1_000L
        const val INTERACTION_GRACE_MS = 6L

        private const val NO_TIME = Long.MIN_VALUE
        private const val NO_TEXTURE_TIMESTAMP = Long.MIN_VALUE
    }
}
