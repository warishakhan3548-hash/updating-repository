package com.aaris.remoteassist.capture

/**
 * Counts fresh producer frames before RTP adaptation and emits a throttled
 * source-motion pulse. The pulse is deliberately timestamp-only: no pixel
 * readback, hashing, allocation, or CPU image conversion sits on the capture
 * thread.
 */
internal data class CaptureCadenceWindow(
    val fps: Double,
    val maxGapMs: Double?,
    val frames: Int
)

internal class CaptureActivityTracker {
    private var lastTimestampNs = Long.MIN_VALUE
    private var sampledAtMs: Long? = null
    private var frames = 0
    private var maxInterFrameGapNs = 0L

    // Remember measured motion across a health-window boundary. Otherwise a
    // capture hitch that straddles sample() disappears from maxGapMs entirely.
    // A boundary candidate is admitted only after the next natural frame
    // confirms that the producer resumed delivering motion.
    private var previousWindowHadMotion = false
    private var pendingBoundaryGapNs = 0L

    private var motionStreak = 0
    private var lastMotionPulseTimestampNs = Long.MIN_VALUE / 2

    /**
     * @return true when several genuinely fresh frames prove that the source is
     * moving. forceFrame duplicates reuse the old timestamp and never qualify.
     */
    @Synchronized
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
         * Across sample() boundaries we still have the previous natural
         * timestamp, but not a same-window pair. A confirmed moving stream can
         * hide a 140-350 ms capture stall exactly at this boundary. Carry its
         * candidate into the new window, and promote it only if a second fresh
         * frame follows promptly. Long static/idle intervals, nonmonotonic
         * timestamps, lone resume frames, and synthetic duplicate timestamps
         * must never masquerade as moving-producer jitter.
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
                maxInterFrameGapNs = maxOf(maxInterFrameGapNs, deltaNs)
            }
            if (
                pendingBoundaryGapNs > 0L &&
                deltaNs in 1L..MAX_MOTION_FRAME_INTERVAL_NS
            ) {
                maxInterFrameGapNs =
                    maxOf(maxInterFrameGapNs, pendingBoundaryGapNs)
            }
            pendingBoundaryGapNs = 0L
        }

        lastTimestampNs = timestampNs
        frames = (frames + 1).coerceAtMost(2048)

        motionStreak =
            if (deltaNs in 1L..MAX_MOTION_FRAME_INTERVAL_NS) {
                (motionStreak + 1).coerceAtMost(MOTION_STREAK_FRAMES)
            } else {
                1
            }

        if (motionStreak < MOTION_STREAK_FRAMES) return false

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

    @Synchronized
    fun sample(nowMs: Long): CaptureCadenceWindow? {
        val previous = sampledAtMs
        val elapsed = previous?.let { nowMs - it }
        if (elapsed != null && elapsed in 0L until 500L) return null

        val count = frames
        val maxGapNs = maxInterFrameGapNs
        previousWindowHadMotion =
            elapsed != null &&
                elapsed in 500L..6000L &&
                count >= MOTION_STREAK_FRAMES &&
                motionStreak >= MOTION_STREAK_FRAMES
        frames = 0
        maxInterFrameGapNs = 0L
        pendingBoundaryGapNs = 0L
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
    }

    @Synchronized
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
