package com.aaris.remoteassist.ai

import com.aaris.remoteassist.capture.AiRawFrame
import com.aaris.remoteassist.capture.CaptureProfile
import kotlinx.coroutines.delay

/**
 * A short-lived, one-shot local reflex learned from a model-approved tap.
 *
 * This is intentionally not a background macro recorder. It can only replay one
 * tap when the same guarded local visual state leaves and later reappears in the
 * same app/window/geometry. It expires quickly and is cleared with the AI run.
 */
data class AiLocalReflex(
    val id: String,
    val packageName: String,
    val windowId: Int,
    val displayWidthPx: Int,
    val displayHeightPx: Int,
    val rotation: Int,
    val x: Double,
    val y: Double,
    val targetId: String?,
    val referenceFingerprint: ByteArray,
    val createdAtMs: Long,
    val expiresAtMs: Long
) {
    val scope = AiActionScope(x, y)
}

data class AiReflexMatch(
    val matched: Boolean,
    val reason: String,
    val localDifferenceRatio: Double? = null,
    val matchedFingerprint: ByteArray? = null
)

class AiLocalReflexWatcher(
    private val ownPackage: String,
    private val freshFrame: suspend () -> AiRawFrame,
    private val display: () -> CaptureProfile,
    private val uiSnapshot: () -> AiUiSnapshot?,
    private val now: () -> Long,
    private val pause: suspend (Long) -> Unit = { delay(it) }
) {
    suspend fun awaitMatch(template: AiLocalReflex, waitMs: Long): AiReflexMatch {
        if (now() > template.expiresAtMs) return AiReflexMatch(false, "REFLEX_EXPIRED")
        val deadline = now() + waitMs.coerceIn(MIN_WAIT_MS, MAX_WAIT_MS)
        var departed = false
        var lastRatio: Double? = null

        while (now() < deadline) {
            if (now() > template.expiresAtMs) return AiReflexMatch(false, "REFLEX_EXPIRED", lastRatio)
            val profile = display()
            if (profile.displayWidthPx != template.displayWidthPx || profile.displayHeightPx != template.displayHeightPx) {
                return AiReflexMatch(false, "CAPTURE_GEOMETRY_CHANGED", lastRatio)
            }

            val ui = uiSnapshot() ?: return AiReflexMatch(false, "DEVICE_LOCKED_OR_ACCESSIBILITY_OFF", lastRatio)
            if (ui.sensitiveFocus || ui.packageName == ownPackage) {
                return AiReflexMatch(false, "LOCAL_ONLY_SCREEN", lastRatio)
            }

            if (ui.packageName == template.packageName && ui.windowId == template.windowId) {
                val semanticMatch = semanticGuardMatches(template, ui)
                if (template.targetId != null && !semanticMatch) {
                    // For a semantic button, disappearance inside the same app/window
                    // is itself strong evidence that the remembered ready-state left.
                    departed = true
                    pause(SAMPLE_INTERVAL_MS)
                    continue
                }
                if (!semanticMatch) {
                    pause(SAMPLE_INTERVAL_MS)
                    continue
                }
                val frame = freshFrame()
                val uprightWidth = if (frame.rotation % 180 == 0) frame.width else frame.height
                val uprightHeight = if (frame.rotation % 180 == 0) frame.height else frame.width
                if (frame.rotation != template.rotation ||
                    kotlin.math.abs(uprightWidth.toDouble() / uprightHeight -
                        profile.displayWidthPx.toDouble() / profile.displayHeightPx) > 0.015) {
                    return AiReflexMatch(false, "CAPTURE_GEOMETRY_CHANGED", lastRatio)
                }
                val fingerprint = AiVisualFingerprint.sample(frame.nv21, frame.width, frame.height, frame.rotation)
                val ratio = AiVisualFingerprint.differenceRatio(
                    template.referenceFingerprint,
                    fingerprint,
                    template.scope
                )
                lastRatio = ratio
                if (ratio != null) {
                    if (!departed && ratio >= DEPART_RATIO) {
                        departed = true
                    } else if (departed && ratio <= MATCH_RATIO) {
                        return AiReflexMatch(true, "MATCHED_AFTER_DEPARTURE", ratio, fingerprint)
                    }
                }
            }
            pause(SAMPLE_INTERVAL_MS)
        }
        return AiReflexMatch(false, if (departed) "REFLEX_WAIT_TIMEOUT" else "REFERENCE_NEVER_DEPARTED", lastRatio)
    }

    fun dispatchGuardMatches(template: AiLocalReflex): Boolean {
        if (now() > template.expiresAtMs) return false
        val profile = display()
        val ui = uiSnapshot() ?: return false
        return profile.displayWidthPx == template.displayWidthPx &&
            profile.displayHeightPx == template.displayHeightPx &&
            !ui.sensitiveFocus &&
            ui.packageName != ownPackage &&
            ui.packageName == template.packageName &&
            ui.windowId == template.windowId &&
            semanticGuardMatches(template, ui)
    }

    private fun semanticGuardMatches(template: AiLocalReflex, ui: AiUiSnapshot): Boolean {
        val id = template.targetId ?: return true
        val matches = ui.nodes.filter { node ->
            node.id == id && node.enabled && (node.clickable || node.editable) && node.area > 0L
        }
        return matches.size == 1
    }

    companion object {
        private const val SAMPLE_INTERVAL_MS = 125L
        private const val MIN_WAIT_MS = 250L
        private const val MAX_WAIT_MS = 12_000L
        private const val DEPART_RATIO = 0.14
        private const val MATCH_RATIO = 0.06
    }
}
