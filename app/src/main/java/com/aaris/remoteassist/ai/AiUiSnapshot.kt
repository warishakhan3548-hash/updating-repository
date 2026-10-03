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

internal data class AiActionSegment(
    val x: Double,
    val y: Double,
    val toX: Double,
    val toY: Double
)

/**
 * Padded action geometry in full-display coordinates.
 *
 * A tap/ordinary swipe uses one segment. Curved and multi-pointer actions keep
 * every real segment, so stale-screen validation watches the actual paths
 * instead of a broad bounding box or only the first/last point.
 */
data class AiActionScope(
    val x: Double,
    val y: Double,
    val toX: Double = x,
    val toY: Double = y,
    internal val segments: List<AiActionSegment> = emptyList()
) {
    fun contains(px: Double, py: Double): Boolean {
        val active = if (segments.isEmpty()) {
            listOf(AiActionSegment(x, y, toX, toY))
        } else {
            segments
        }
        return active.any { segment ->
            containsSegment(px, py, segment)
        }
    }

    private fun containsSegment(
        px: Double,
        py: Double,
        segment: AiActionSegment
    ): Boolean {
        // Normalize by clearance so a vertical swipe checks a narrow corridor,
        // not every pixel in a large axis-aligned rectangle.
        val dx = (segment.toX - segment.x) / X_CLEARANCE
        val dy = (segment.toY - segment.y) / Y_CLEARANCE
        val vx = (px - segment.x) / X_CLEARANCE
        val vy = (py - segment.y) / Y_CLEARANCE
        val lengthSquared = dx * dx + dy * dy
        val t = if (lengthSquared == 0.0) {
            0.0
        } else {
            ((vx * dx + vy * dy) / lengthSquared).coerceIn(0.0, 1.0)
        }
        val rx = vx - t * dx
        val ry = vy - t * dy
        return rx * rx + ry * ry <= 1.0
    }

    companion object {
        fun path(points: List<Pair<Double, Double>>): AiActionScope {
            require(points.size >= 2)
            return paths(listOf(points))
        }

        fun paths(paths: List<List<Pair<Double, Double>>>): AiActionScope {
            val usable = paths.filter { it.size >= 2 }
            require(usable.isNotEmpty())
            val segments = usable.flatMap { path ->
                path.zipWithNext { from, to ->
                    AiActionSegment(from.first, from.second, to.first, to.second)
                }
            }
            val first = usable.first().first()
            val last = usable.last().last()
            return AiActionScope(
                x = first.first,
                y = first.second,
                toX = last.first,
                toY = last.second,
                segments = segments
            )
        }

        private const val X_CLEARANCE = 0.04
        private const val Y_CLEARANCE = 0.025
    }
}

object AiObservationSignals {
    // Installed and invoked on the main thread; Accessibility events are not retained.
    var changed: (() -> Unit)? = null
}
