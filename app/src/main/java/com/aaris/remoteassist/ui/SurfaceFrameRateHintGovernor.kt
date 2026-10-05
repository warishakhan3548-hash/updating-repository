package com.aaris.remoteassist.ui

import com.aaris.remoteassist.webrtc.PresentationCadenceWindow
import kotlin.math.abs
import kotlin.math.max

/**
 * Converts measured controller EGL presentation cadence into a stable Android
 * Surface frame-rate hint.
 *
 * This is intentionally advisory: it does not pace WebRTC, drop frames or
 * override the display mode. Android remains free to choose a compatible
 * refresh rate. The governor only emits after multiple clean presentation
 * windows and rate-limits changes so one decoder/GPU hitch cannot make the
 * physical display flap between modes.
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
        return currentHint
    }

    fun currentHintFps(): Int = currentHint

    fun reset() {
        currentHint = 0
        lastChangedAtMs = Long.MIN_VALUE / 2
        resetCandidate()
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

        /*
         * We hint the producer's known cadence ladder rather than every noisy
         * fractional sample. The tolerance is intentionally narrow enough that
         * a chronically overloaded 60-fps stream is not mislabeled as healthy
         * 60, while allowing normal short-window scheduling jitter.
         */
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
