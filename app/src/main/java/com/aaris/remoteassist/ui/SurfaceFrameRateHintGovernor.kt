package com.aaris.remoteassist.ui

import com.aaris.remoteassist.webrtc.PresentationCadenceWindow
import kotlin.math.max

/**
 * Keeps the controller's display scheduling stable for an interactive stream.
 *
 * The observed VIDEO cadence is not the display's sustainable refresh rate:
 * native WebRTC may temporarily deliver 15/24/30 fps due to network or codec
 * pressure, then recover on the next gesture. Voting for every measured rate
 * may switch the display exactly when the stream needs spare presentation
 * capacity, amplifying perceived judder on some Android devices.
 *
 * Request a 60 Hz-class Surface hint once per live stream. Android may ignore
 * the request or choose a supported refresh rate. Media timing, frame dropping,
 * WebRTC bitrate control and native playout remain untouched.
 */
internal class SurfaceFrameRateHintGovernor(
    private val initialWindows: Int = DEFAULT_INITIAL_WINDOWS
) {
    private var currentHint = 0
    private var cleanWindows = 0

    init {
        require(initialWindows >= 1)
    }

    /** Passive streaming can establish the one-time hint without a touch. */
    fun observe(window: PresentationCadenceWindow, nowMs: Long): Int? {
        if (nowMs < 0 || currentHint != 0) return null

        val fps = window.fps
        val clean =
            window.renderedFrames >= MIN_PRESENTED_FRAMES &&
                fps.isFinite() &&
                fps in MIN_MEASURED_FPS..MAX_MEASURED_FPS &&
                window.maxGapMs <= max(
                    MAX_STABLE_GAP_MS,
                    1_000.0 / fps * MAX_STABLE_GAP_FRAME_MULTIPLIER
                )
        cleanWindows = if (clean) cleanWindows + 1 else 0
        if (cleanWindows < initialWindows) return null

        currentHint = PREFERRED_SURFACE_FPS
        return currentHint
    }

    /**
     * The first gesture may precede any measured presentation windows.
     * Request the display-class hint immediately, but never toggle it on
     * finger-up. Honor a smaller caller ceiling without switching again.
     */
    fun beginInteraction(maxFps: Int = PREFERRED_SURFACE_FPS): Int? {
        if (maxFps <= 0 || currentHint != 0) return null
        currentHint = minOf(maxFps, PREFERRED_SURFACE_FPS)
        cleanWindows = 0
        return currentHint
    }

    /** The hint is stream-owned, not touch-owned. */
    fun endInteraction(): Int? = null

    fun currentHintFps(): Int = currentHint

    /** Clear the Surface preference only when the stream resets/ends. */
    fun reset(): Boolean {
        val hadHint = currentHint > 0
        currentHint = 0
        cleanWindows = 0
        return hadHint
    }

    private companion object {
        const val PREFERRED_SURFACE_FPS = 60
        const val DEFAULT_INITIAL_WINDOWS = 3
        const val MIN_PRESENTED_FRAMES = 5
        const val MIN_MEASURED_FPS = 10.0
        const val MAX_MEASURED_FPS = 72.0
        const val MAX_STABLE_GAP_MS = 72.0
        const val MAX_STABLE_GAP_FRAME_MULTIPLIER = 2.75
    }
}
