package com.aaris.remoteassist.webrtc

import kotlin.math.roundToInt

/** Interval deltas, never lifetime averages masquerading as current pressure. */
data class VideoHealthWindow(
    val intervalMs: Int,
    val frames: Int,
    val processingMs: Double?,
    val jitterMs: Double?,
    val dropped: Int?,
    val freezes: Int?,
    val bitrateBps: Long = 0,
    val sendQueueMs: Double? = null,
    val presentationIntervalMs: Int? = null,
    val presentedFrames: Int? = null,
    val maxRenderGapMs: Int? = null
) {
    val fps: Double get() = frames * 1000.0 / intervalMs
    val presentedFps: Double?
        get() {
            val interval = presentationIntervalMs ?: return null
            val count = presentedFrames ?: return null
            if (interval <= 0 || count < 0) return null
            return count * 1000.0 / interval
        }

    fun compact(): String {
        val presentation = presentedFps?.roundToInt()?.let { " present=${it}fps gap=${maxRenderGapMs}ms" }.orEmpty()
        return "${fps.roundToInt()}fps ${bitrateBps / 1000}kbps codec=${processingMs?.roundToInt()}ms jitter=${jitterMs?.roundToInt()}ms drop=$dropped freeze=$freezes queue=${sendQueueMs?.roundToInt()}ms$presentation"
    }
}

class VideoHealthWindowTracker {
    private var previous: VideoHealthSnapshot? = null

    @Synchronized fun sample(current: VideoHealthSnapshot): VideoHealthSnapshot {
        val old = previous
        previous = current
        if (old == null || current.streamId != old.streamId || current.direction != old.direction || current.codec != old.codec) return current
        val interval = (current.timestampUs - old.timestampUs) / 1000.0
        if (!interval.isFinite() || interval !in 500.0..6000.0) return current
        val frames = if (current.direction == "outbound") current.frames - old.frames else current.framesSecondary - old.framesSecondary
        val bytes = current.bytes - old.bytes
        val packets = current.packets - old.packets
        if (frames !in 0..2048 || bytes < 0 || packets < 0) return current
        fun average(total: Double?, before: Double?, count: Long): Double? {
            if (total == null || before == null || count <= 0) return null
            val delta = total - before
            return (delta * 1000 / count).takeIf { delta >= 0 && it.isFinite() && it in 0.0..5000.0 }
        }
        fun count(total: Long?, before: Long?): Int? = if (total == null || before == null) null else
            (total - before).takeIf { it in 0..2048 }?.toInt()
        return current.copy(recent = VideoHealthWindow(interval.roundToInt(), frames.toInt(),
            average(current.processingTotalSeconds, old.processingTotalSeconds, frames),
            average(current.jitterTotalSeconds, old.jitterTotalSeconds,
                if (current.jitterEmittedCount != null && old.jitterEmittedCount != null) current.jitterEmittedCount - old.jitterEmittedCount else 0),
            count(current.framesDropped, old.framesDropped), count(current.freezeCount, old.freezeCount),
            (bytes * 8000.0 / interval).toLong(), average(current.sendDelayTotalSeconds, old.sendDelayTotalSeconds, packets)))
    }
}
