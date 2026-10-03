package com.aaris.remoteassist.ai

import android.graphics.Rect
import org.json.JSONArray

data class AiUiSnapshot(
    val packageName: String,
    val hints: JSONArray,
    val masks: List<Rect>,
    val sensitiveFocus: Boolean,
    val truncated: Boolean,
    val windowId: Int = -1,
    val nodes: List<AiUiNode> = emptyList()
)

/** Value-only snapshots; never retain AccessibilityNodeInfo or password text. */
data class AiUiNode(
    val id: String, val role: String, val text: String,
    val left: Int, val top: Int, val right: Int, val bottom: Int,
    val clickable: Boolean, val editable: Boolean, val focused: Boolean,
    val enabled: Boolean, val selectionStart: Int = -1, val selectionEnd: Int = -1,
    val valueDigest: String = ""
) {
    fun contains(x: Double, y: Double) = x >= left && x < right && y >= top && y < bottom
    val area: Long get() = (right - left).toLong().coerceAtLeast(0) * (bottom - top).coerceAtLeast(0)
}

/** A padded touch point/path in full-display coordinates, independent of other animation. */
data class AiActionScope(val x: Double, val y: Double, val toX: Double = x, val toY: Double = y) {
    fun contains(px: Double, py: Double): Boolean {
        // Normalize by clearance so a vertical swipe checks a narrow corridor,
        // not every pixel in a large axis-aligned rectangle.
        val dx = (toX - x) / 0.04; val dy = (toY - y) / 0.025
        val vx = (px - x) / 0.04; val vy = (py - y) / 0.025
        val t = if (dx * dx + dy * dy == 0.0) 0.0 else ((vx * dx + vy * dy) / (dx * dx + dy * dy)).coerceIn(0.0, 1.0)
        return (vx - t * dx) * (vx - t * dx) + (vy - t * dy) * (vy - t * dy) <= 1.0
    }
}

object AiObservationSignals {
    // Installed and invoked on the main thread; Accessibility events are not retained.
    var changed: (() -> Unit)? = null
}
