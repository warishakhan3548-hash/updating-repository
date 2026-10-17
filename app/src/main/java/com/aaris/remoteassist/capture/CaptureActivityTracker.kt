package com.aaris.remoteassist.capture

import java.util.concurrent.locks.ReentrantLock

/**
 * Counts fresh producer frames before RTP adaptation and emits a throttled
 * source-motion pulse. The pulse is deliberately timestamp-only: no pixel
 * readback, hashing, allocation, or CPU image conversion sits on the capture
 * thread.
 *
 * Producer motion state is owned exclusively by SurfaceTextureHelper's capture
 * lane. Window telemetry is best-effort: the producer uses tryLock() and may
 * skip one observation while the policy lane snapshots a window, but it never
 * waits behind diagnostics. Live RTP has already been admitted before this
 * tracker runs, so telemetry contention cannot become user-visible frame jitter.
 */
internal data class CaptureCadenceWindow(
    val fps: Double,
    val maxGapMs: Double?,
    val frames: Int
)

internal class CaptureActivityTracker {
    /*
     * Producer-owned state. onFrame() is called serially by the capturer lane;
     * policy sampling never reads these fields directly.
     */
    private var lastTimestampNs = Long.MIN_VALUE
    private var motionStreak = 0
    private var lastMotionPulseTimestampNs = Long.MIN_VALUE / 2

    /*
     * Cross-thread telemetry state. Policy sampling may briefly hold this lock.
     * The capture lane only tryLocks it, making observability lossy under an
     * exact collision rather than making media delivery blocking.
     */
    private val telemetryLock = ReentrantLock()
    private var sampledAtMs: Long? = null
    private var frames = 0
    private var maxInterFrameGapNs = 0L
    private var windowEndsInMotion = false

    // Remember measured motion across a health-window boundary. Otherwise a
    // capture hitch that straddles sample() disappears from maxGapMs entirely.
    // A boundary candidate is admitted only after the next natural frame
    // confirms that the producer resumed delivering motion.
    private var previousWindowHadMotion = false
    private var pendingBoundaryGapNs = 0L

    /**
     * @return true when several genuinely fresh frames prove that the source is
     * moving. forceFrame duplicates reuse the old timestamp and never qualify.
     */
    fun onFrame(timestampNs: Long): Boolean {
        if (timestampNs <= 0 || timestampNs == lastTimestampNs) return false

        val previousTimestampNs = lastTimestampNs
        val deltaNs =
            if (previousTimestampNs > 0 && timestampNs > previousTimestampNs) {
                timestampNs - previousTimestampNs
            } else {
                Long.MAX_VALUE
            }

        /*
         * Motion detection is producer-owned and therefore never waits for the
         * policy thread. This is the freshness signal that keeps capture/render
         * scheduling hot during scrolling, video and game animation.
         */
        lastTimestampNs = timestampNs
        motionStreak =
            if (deltaNs in 1L..MAX_MOTION_FRAME_INTERVAL_NS) {
                (motionStreak + 1).coerceAtMost(MOTION_STREAK_FRAMES)
            } else {
                1
            }
        val movingNow = motionStreak >= MOTION_STREAK_FRAMES

        /*
         * Telemetry must never sit in front of the next capturer callback.
         * Missing one accounting sample at the exact half-second snapshot
         * boundary is preferable to delaying a live texture. The following
         * natural frame still carries the real producer timestamp, so future
         * motion/stall evidence remains conservative rather than fabricated.
         */
        if (telemetryLock.tryLock()) {
            try {
                /*
                 * Across sample() boundaries we still have the previous natural
                 * timestamp, but not a same-window pair. A confirmed moving
                 * stream can hide a 140-350 ms capture stall exactly at this
                 * boundary. Carry its candidate into the new window, and promote
                 * it only if a second fresh frame follows promptly.
                 */
                if (frames == 0) {
                    pendingBoundaryGapNs =
                        if (
                            previousWindowHadMotion &&
                            deltaNs in MIN_BOUNDARY_HITCH_NS..MAX_BOUNDARY_HITCH_NS
                        ) {
                            deltaNs
                        } else {
                            0L
                        }
                } else {
                    if (deltaNs != Long.MAX_VALUE) {
                        maxInterFrameGapNs =
                            maxOf(maxInterFrameGapNs, deltaNs)
                    }
                    if (
                        pendingBoundaryGapNs > 0L &&
                        deltaNs in 1L..MAX_MOTION_FRAME_INTERVAL_NS
                    ) {
                        maxInterFrameGapNs =
                            maxOf(
                                maxInterFrameGapNs,
                                pendingBoundaryGapNs
                            )
                    }
                    pendingBoundaryGapNs = 0L
                }

                frames = (frames + 1).coerceAtMost(2048)
                windowEndsInMotion = movingNow
            } finally {
                telemetryLock.unlock()
            }
        }

        if (!movingNow) return false

        if (
            lastMotionPulseTimestampNs > 0 &&
            timestampNs - lastMotionPulseTimestampNs in
                0L until MOTION_PULSE_INTERVAL_NS
        ) {
            return false
        }

        lastMotionPulseTimestampNs = timestampNs
        return true
    }

    fun sample(nowMs: Long): CaptureCadenceWindow? {
        telemetryLock.lock()
        try {
            val previous = sampledAtMs
            val elapsed = previous?.let { nowMs - it }
            if (elapsed != null && elapsed in 0L until 500L) return null

            val count = frames
            val maxGapNs = maxInterFrameGapNs
            previousWindowHadMotion =
                elapsed != null &&
                    elapsed in 500L..6000L &&
                    count >= MOTION_STREAK_FRAMES &&
                    windowEndsInMotion
            frames = 0
            maxInterFrameGapNs = 0L
            pendingBoundaryGapNs = 0L
            windowEndsInMotion = false
            sampledAtMs = nowMs

            return if (elapsed != null && elapsed in 500L..6000L) {
                CaptureCadenceWindow(
                    fps = count * 1000.0 / elapsed,
                    maxGapMs =
                        maxGapNs
                            .takeIf { it > 0L }
                            ?.div(1_000_000.0),
                    frames = count
                )
            } else {
                null
            }
        } finally {
            telemetryLock.unlock()
        }
    }

    fun sampleFps(nowMs: Long): Double? =
        sample(nowMs)?.fps

    private companion object {
        // Three frames inside this spacing detect normal 12/24/30/60 Hz motion
        // quickly without treating sparse static refreshes as sustained motion.
        const val MAX_MOTION_FRAME_INTERVAL_NS = 125_000_000L
        // MotionVideoBudget considers >=140 ms a producer hitch. Restrict
        // cross-window evidence to a short interruption, not a static screen.
        const val MIN_BOUNDARY_HITCH_NS = 140_000_000L
        const val MAX_BOUNDARY_HITCH_NS = 350_000_000L
        const val MOTION_STREAK_FRAMES = 3

        // PassiveMotionPriority keeps a 3 s tail, so sub-second pulses are more
        // than sufficient and keep capture-thread -> main-thread traffic tiny.
        const val MOTION_PULSE_INTERVAL_NS = 750_000_000L
    }
}
