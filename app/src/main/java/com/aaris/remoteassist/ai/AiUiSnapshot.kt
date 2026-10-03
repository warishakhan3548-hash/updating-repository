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
    val area: Long get() = (right - left).toLong().coerceAtLeast(0) * (bottom - top).toLong().coerceAtLeast(0)
}

/** Padded touch path(s) in full-display coordinates, independent of other animation. */
data class AiActionScope(
    val x: Double,
    val y: Double,
    val toX: Double = x,
    val toY: Double = y,
    val via: List<Pair<Double, Double>> = emptyList(),
    val extraPaths: List<List<Pair<Double, Double>>> = emptyList()
) {
    fun contains(px: Double, py: Double): Boolean {
        val primary = buildList {
            add(x to y)
            addAll(via)
            add(toX to toY)
        }
        return (listOf(primary) + extraPaths).any { path ->
            path.zipWithNext().any { (from, to) ->
                containsSegment(from.first, from.second, to.first, to.second, px, py)
            }
        }
    }

    private fun containsSegment(
        fromX: Double,
        fromY: Double,
        endX: Double,
        endY: Double,
        px: Double,
        py: Double
    ): Boolean {
        // Normalize by clearance so vertical/horizontal paths keep a narrow
        // touch corridor rather than validating the full axis-aligned box.
        val dx = (endX - fromX) / 0.04
        val dy = (endY - fromY) / 0.025
        val vx = (px - fromX) / 0.04
        val vy = (py - fromY) / 0.025
        val lengthSquared = dx * dx + dy * dy
        val t = if (lengthSquared == 0.0) 0.0 else ((vx * dx + vy * dy) / lengthSquared).coerceIn(0.0, 1.0)
        val ex = vx - t * dx
        val ey = vy - t * dy
        return ex * ex + ey * ey <= 1.0
    }

    companion object {
        fun fromPath(points: List<Pair<Double, Double>>): AiActionScope {
            require(points.size >= 2)
            return AiActionScope(
                x = points.first().first,
                y = points.first().second,
                toX = points.last().first,
                toY = points.last().second,
                via = points.subList(1, points.lastIndex)
            )
        }

        fun fromPaths(paths: List<List<Pair<Double, Double>>>): AiActionScope {
            require(paths.isNotEmpty() && paths.all { it.size >= 2 })
            val first = paths.first()
            return AiActionScope(
                x = first.first().first,
                y = first.first().second,
                toX = first.last().first,
                toY = first.last().second,
                via = first.subList(1, first.lastIndex),
                extraPaths = paths.drop(1).map { it.toList() }
            )
        }
    }
}

object AiObservationSignals {
    // Installed and invoked on the main thread; Accessibility events are not retained.
    var changed: (() -> Unit)? = null
}
