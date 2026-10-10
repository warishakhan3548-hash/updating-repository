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

        if (deltaNs != Long.MAX_VALUE) {
            maxInterFrameGapNs = maxOf(maxInterFrameGapNs, deltaNs)
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
        frames = 0
        maxInterFrameGapNs = 0L
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
        const val MOTION_STREAK_FRAMES = 3

        // PassiveMotionPriority keeps a 3 s tail, so sub-second pulses are more
        // than sufficient and keep capture-thread -> main-thread traffic tiny.
        const val MOTION_PULSE_INTERVAL_NS = 750_000_000L
    }
}
