package com.aaris.remoteassist.webrtc

/**
 * Keeps the sender in freshness-first mode while the shared screen is visibly
 * moving, even after the remote finger has lifted.
 *
 * ScreenCapturerAndroid naturally produces few/no frames on a static screen.
 * Producer cadence detects motion even when the encoder has already stalled. A
 * short tail covers fling/launcher/video transitions and avoids repeatedly
 * toggling the RTP degradation preference around brief cadence dips.
 */
internal class PassiveMotionPriority(
    private val enterFps: Double = DEFAULT_ENTER_FPS,
    private val holdFps: Double = DEFAULT_HOLD_FPS,
    private val tailMs: Long = DEFAULT_TAIL_MS
) {
    private var active = false
    private var lastMotionAtMs = Long.MIN_VALUE / 2

    init {
        require(enterFps > 0.0)
        require(holdFps > 0.0 && holdFps <= enterFps)
        require(tailMs >= 0L)
    }

    fun observe(
        window: VideoHealthWindow?,
        nowMs: Long,
        sourceFps: Double? = null
    ): Boolean {
        if (nowMs < 0L) return false

        val before = active
        val fps = sourceFps?.takeIf { it.isFinite() && it >= 0.0 } ?: window?.fps ?: 0.0

        if (!active && fps >= enterFps) {
            active = true
            lastMotionAtMs = nowMs
        } else if (active) {
            if (fps >= holdFps) {
                lastMotionAtMs = nowMs
            } else if (nowMs - lastMotionAtMs > tailMs) {
                active = false
            }
        }

        return active != before
    }

    fun isActive(nowMs: Long): Boolean {
        if (
            active &&
            nowMs >= 0L &&
            nowMs - lastMotionAtMs > tailMs
        ) {
            active = false
        }
        return active
    }

    fun reset(): Boolean {
        val changed = active
        active = false
        lastMotionAtMs = Long.MIN_VALUE / 2
        return changed
    }

    private companion object {
        const val DEFAULT_ENTER_FPS = 8.0
        const val DEFAULT_HOLD_FPS = 2.5
        const val DEFAULT_TAIL_MS = 3_000L
    }
}
