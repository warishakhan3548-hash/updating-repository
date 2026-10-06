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
    val maxRenderGapMs: Int? = null,
    val presentationAgeMs: Int? = null,
    val displayRefreshRateHz: Double? = null,
    val jitterTargetMs: Double? = null
) {
    val fps: Double get() = frames * 1000.0 / intervalMs

    /**
     * Receiver freshness budget. WebRTC may intentionally grow its target
     * jitter-buffer residence before the measured emitted-frame residence has
     * caught up. For remoting, the larger valid value is the useful early
     * warning because both represent time a fresh frame can spend waiting
     * before decode/render.
     */
    val playoutDelayMs: Double?
        get() {
            val actual =
                jitterMs?.takeIf { it.isFinite() && it >= 0.0 }
            val target =
                jitterTargetMs?.takeIf { it.isFinite() && it >= 0.0 }
            return when {
                actual == null -> target
                target == null -> actual
                else -> maxOf(actual, target)
            }
        }
    val presentedFps: Double?
        get() {
            val interval = presentationIntervalMs ?: return null
            val count = presentedFrames ?: return null
            if (interval <= 0 || count < 0) return null
            return count * 1000.0 / interval
        }

    fun compact(): String {
        val presentation = presentedFps?.roundToInt()?.let {
            " present=${it}fps gap=${maxRenderGapMs}ms"
        } ?: presentationAgeMs?.let {
            " present=alive age=${it}ms"
        }.orEmpty()
        val target = jitterTargetMs?.roundToInt()?.let { " target=${it}ms" }.orEmpty()
        return "${fps.roundToInt()}fps ${bitrateBps / 1000}kbps codec=${processingMs?.roundToInt()}ms jitter=${jitterMs?.roundToInt()}ms$target drop=$dropped freeze=$freezes queue=${sendQueueMs?.roundToInt()}ms$presentation"
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
        val emitted =
            if (
                current.jitterEmittedCount != null &&
                old.jitterEmittedCount != null
            ) {
                current.jitterEmittedCount - old.jitterEmittedCount
            } else {
                0L
            }
        return current.copy(
            recent = VideoHealthWindow(
                intervalMs = interval.roundToInt(),
                frames = frames.toInt(),
                processingMs =
                    average(
                        current.processingTotalSeconds,
                        old.processingTotalSeconds,
                        frames
                    ),
                jitterMs =
                    average(
                        current.jitterTotalSeconds,
                        old.jitterTotalSeconds,
                        emitted
                    ),
                dropped = count(current.framesDropped, old.framesDropped),
                freezes = count(current.freezeCount, old.freezeCount),
                bitrateBps = (bytes * 8000.0 / interval).toLong(),
                sendQueueMs =
                    average(
                        current.sendDelayTotalSeconds,
                        old.sendDelayTotalSeconds,
                        packets
                    ),
                jitterTargetMs =
                    average(
                        current.jitterTargetTotalSeconds,
                        old.jitterTargetTotalSeconds,
                        emitted
                    )
            )
        )
    }
}
