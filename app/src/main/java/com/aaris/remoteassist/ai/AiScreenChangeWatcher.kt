package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import kotlinx.coroutines.delay

data class AiWaitRegion(
    val left: Double,
    val top: Double,
    val right: Double,
    val bottom: Double
) {
    init {
        require(listOf(left, top, right, bottom).all { it.isFinite() && it in 0.0..1.0 })
        require(left < right && top < bottom)
    }
}

data class AiWaitBaseline(
    val packageName: String,
    val windowId: Int,
    val displayWidthPx: Int,
    val displayHeightPx: Int,
    val rotation: Int,
    val fingerprint: ByteArray,
    val createdAtMs: Long
)

data class AiWaitResult(
    val changed: Boolean,
    val reason: String,
    val changeRatio: Double? = null,
    val waitedMs: Long = 0L
)

/**
 * Event-driven observation primitive. Samples on-device and sends no intermediate
 * screenshots to the cloud. A caller receives a fresh observation only after a
 * meaningful visual/window transition; timeouts can return metadata only.
 */
class AiScreenChangeWatcher(
    private val ownPackage: String,
    private val freshFrame: suspend () -> AiRawFrame,
    private val display: () -> CaptureProfile,
    private val uiSnapshot: () -> AiUiSnapshot?,
    private val now: () -> Long,
    private val pause: suspend (Long) -> Unit = { delay(it) }
) {
    suspend fun awaitChange(
        baseline: AiWaitBaseline,
        waitMs: Long,
        minChangeRatio: Double,
        region: AiWaitRegion? = null
    ): AiWaitResult {
        val start = now()
        val deadline = start + waitMs.coerceIn(MIN_WAIT_MS, MAX_WAIT_MS)
        val threshold = minChangeRatio.coerceIn(MIN_CHANGE_RATIO, MAX_CHANGE_RATIO)
        var lastRatio: Double? = null

        while (now() < deadline) {
            val profile = display()
            if (profile.displayWidthPx != baseline.displayWidthPx ||
                profile.displayHeightPx != baseline.displayHeightPx) {
                return AiWaitResult(true, "CAPTURE_GEOMETRY_CHANGED", lastRatio, now() - start)
            }

            val ui = uiSnapshot()
                ?: return AiWaitResult(true, "DEVICE_LOCKED_OR_ACCESSIBILITY_OFF", lastRatio, now() - start)
            if (ui.packageName != baseline.packageName || ui.windowId != baseline.windowId) {
                return AiWaitResult(true, "WINDOW_CHANGED", 1.0, now() - start)
            }
            if (ui.sensitiveFocus || ui.packageName == ownPackage) {
                return AiWaitResult(true, "PRIVACY_CONTEXT_CHANGED", 1.0, now() - start)
            }

            val frame = freshFrame()
            if (frame.rotation != baseline.rotation) {
                return AiWaitResult(true, "CAPTURE_GEOMETRY_CHANGED", lastRatio, now() - start)
            }
            val uprightWidth = if (frame.rotation % 180 == 0) frame.width else frame.height
            val uprightHeight = if (frame.rotation % 180 == 0) frame.height else frame.width
            if (kotlin.math.abs(
                    uprightWidth.toDouble() / uprightHeight -
                        profile.displayWidthPx.toDouble() / profile.displayHeightPx
                ) > 0.015) {
                return AiWaitResult(true, "CAPTURE_GEOMETRY_CHANGED", lastRatio, now() - start)
            }

            val fingerprint = AiVisualFingerprint.sample(frame.nv21, frame.width, frame.height, frame.rotation)
            val ratio = if (region == null) {
                AiVisualFingerprint.differenceRatio(baseline.fingerprint, fingerprint)
            } else {
                AiVisualFingerprint.differenceRatioRect(
                    baseline.fingerprint,
                    fingerprint,
                    region.left,
                    region.top,
                    region.right,
                    region.bottom
                )
            }
            lastRatio = ratio
            if (ratio != null && ratio >= threshold) {
                return AiWaitResult(true, if (region == null) "SCREEN_CHANGED" else "REGION_CHANGED", ratio, now() - start)
            }
            pause(SAMPLE_INTERVAL_MS)
        }

        return AiWaitResult(false, "WAIT_TIMEOUT", lastRatio, now() - start)
    }

    companion object {
        private const val SAMPLE_INTERVAL_MS = 125L
        private const val MIN_WAIT_MS = 250L
        private const val MAX_WAIT_MS = 12_000L
        private const val MIN_CHANGE_RATIO = 0.01
        private const val MAX_CHANGE_RATIO = 0.80
    }
}
