package com.aaris.remoteassist.ui

import com.aaris.remoteassist.webrtc.PresentationCadenceWindow
import kotlin.math.abs
import kotlin.math.max

/**
 * Converts measured controller EGL presentation cadence into a stable Android
 * Surface frame-rate hint.
 *
 * This is advisory only: it never paces WebRTC, drops frames or overrides the
 * display mode. Android remains free to choose a compatible refresh rate. The
 * governor emits only after multiple clean presentation windows and rate-limits
 * changes so a decoder/GPU hitch cannot make the display flap between modes.
 */
internal class SurfaceFrameRateHintGovernor(
    private val initialWindows: Int = DEFAULT_INITIAL_WINDOWS,
    private val switchWindows: Int = DEFAULT_SWITCH_WINDOWS,
    private val minSwitchIntervalMs: Long = DEFAULT_MIN_SWITCH_INTERVAL_MS
) {
    private var currentHint = 0
    private var candidateHint = 0
    private var candidateWindows = 0
    private var lastChangedAtMs = Long.MIN_VALUE / 2
    private var interactionHint = 0

    init {
        require(initialWindows >= 1)
        require(switchWindows >= 1)
        require(minSwitchIntervalMs >= 0L)
    }

    fun observe(
        window: PresentationCadenceWindow,
        nowMs: Long
    ): Int? {
        if (nowMs < 0L) return null

        val measuredHint = stableCadence(window)
        if (measuredHint == null) {
            resetCandidate()
            return null
        }

        if (measuredHint == currentHint) {
            resetCandidate()
            return null
        }

        if (candidateHint != measuredHint) {
            candidateHint = measuredHint
            candidateWindows = 1
        } else {
            candidateWindows += 1
        }

        val requiredWindows =
            if (currentHint == 0) initialWindows else switchWindows
        if (candidateWindows < requiredWindows) return null

        if (
            currentHint != 0 &&
            nowMs - lastChangedAtMs < minSwitchIntervalMs
        ) {
            return null
        }

        currentHint = measuredHint
        lastChangedAtMs = nowMs
        resetCandidate()

        /*
         * Interaction does not own an independent 60 Hz policy anymore. Keep
         * the Surface hint aligned to cadence that real EGL swaps have already
         * proven sustainable. A change still needs the same multi-window and
         * rate-limit evidence, so this cannot flap during a short gesture.
         */
        if (interactionHint > 0) {
            if (interactionHint != currentHint) {
                interactionHint = currentHint
                return currentHint
            }
            return null
        }
        return currentHint
    }

    /**
     * Keep Android on the cadence already proven by real presentation while
     * the user is manipulating the remote screen. If no cadence has been
     * learned yet, fall back to the bounded realtime ceiling.
     *
     * This is only a Surface scheduling hint. It does not raise WebRTC's
     * encoder target, create frames, or bypass the unified media controller.
     */
    fun beginInteraction(
        maxFps: Int = MAX_INTERACTION_HINT_FPS
    ): Int? {
        if (maxFps <= 0) return null

        val ceiling = minOf(maxFps, MAX_INTERACTION_HINT_FPS)
        val learned =
            currentHint.takeIf { it in 1..ceiling }
        val target =
            learned
                ?: CADENCE_RUNGS.lastOrNull { it <= ceiling }
                ?: return null
        val previous = currentHintFps()
        interactionHint = target
        resetCandidate()
        return target.takeIf { it != previous }
    }

    /**
     * Drop the temporary interaction override and immediately restore the
     * cadence learned from real EGL swaps. Returning 0 tells the Surface owner
     * to clear an otherwise stale high-refresh request.
     */
    fun endInteraction(): Int? {
        if (interactionHint == 0) return null

        val previous = currentHintFps()
        interactionHint = 0
        resetCandidate()
        return currentHint.takeIf { it != previous }
    }

    fun currentHintFps(): Int =
        interactionHint.takeIf { it > 0 } ?: currentHint

    /**
     * Forget an established cadence after a stream stop/replacement.
     *
     * Returns true only when Android may still hold a non-zero preference that
     * the Surface owner should clear with setFrameRate(0).
     */
    fun reset(): Boolean {
        val hadHint = currentHintFps() > 0
        currentHint = 0
        interactionHint = 0
        lastChangedAtMs = Long.MIN_VALUE / 2
        resetCandidate()
        return hadHint
    }

    private fun stableCadence(
        window: PresentationCadenceWindow
    ): Int? {
        if (window.renderedFrames < MIN_PRESENTED_FRAMES) return null

        val measuredFps = window.fps
        if (
            !measuredFps.isFinite() ||
            measuredFps < MIN_MEASURED_FPS ||
            measuredFps > MAX_MEASURED_FPS
        ) {
            return null
        }

        val nearest =
            CADENCE_RUNGS.minByOrNull { rung ->
                abs(measuredFps - rung.toDouble())
            } ?: return null

        val allowedError =
            max(
                MIN_FPS_TOLERANCE,
                nearest * RELATIVE_FPS_TOLERANCE
            )
        if (abs(measuredFps - nearest) > allowedError) return null

        val framePeriodMs = 1_000.0 / nearest.toDouble()
        val allowedGapMs =
            max(
                MIN_STABLE_GAP_MS,
                framePeriodMs * MAX_STABLE_GAP_FRAME_MULTIPLIER
            )
        if (window.maxGapMs > allowedGapMs) return null

        return nearest
    }

    private fun resetCandidate() {
        candidateHint = 0
        candidateWindows = 0
    }

    private companion object {
        val CADENCE_RUNGS = intArrayOf(15, 20, 24, 30, 45, 60)

        const val MAX_INTERACTION_HINT_FPS = 60
        const val MIN_PRESENTED_FRAMES = 5
        const val MIN_MEASURED_FPS = 10.0
        const val MAX_MEASURED_FPS = 72.0
        const val MIN_FPS_TOLERANCE = 2.5
        const val RELATIVE_FPS_TOLERANCE = 0.12
        const val MIN_STABLE_GAP_MS = 72.0
        const val MAX_STABLE_GAP_FRAME_MULTIPLIER = 2.75

        const val DEFAULT_INITIAL_WINDOWS = 3
        const val DEFAULT_SWITCH_WINDOWS = 4
        const val DEFAULT_MIN_SWITCH_INTERVAL_MS = 2_500L
    }
}
