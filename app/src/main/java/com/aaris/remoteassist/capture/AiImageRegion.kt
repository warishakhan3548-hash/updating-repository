package com.aaris.remoteassist.capture

import kotlin.math.ceil
import kotlin.math.max

/**
 * Normalized crop in the upright, full-display coordinate space exposed by the
 * AI control contract.
 *
 * The region is a delivery optimization only. Action coordinates and
 * stale-target validation remain bound to the full display.
 */
data class AiImageRegion(
    val left: Double,
    val top: Double,
    val right: Double,
    val bottom: Double
) {
    init {
        require(left.isFinite() && top.isFinite() && right.isFinite() && bottom.isFinite())
        require(left in 0.0..1.0 && top in 0.0..1.0)
        require(right in 0.0..1.0 && bottom in 0.0..1.0)
        require(right > left && bottom > top)
        require(right - left >= MIN_REGION_SPAN)
        require(bottom - top >= MIN_REGION_SPAN)
    }

    val widthFraction: Double
        get() = right - left

    val heightFraction: Double
        get() = bottom - top

    /**
     * A crop cannot invent detail that was discarded before capture. Request a
     * sharper full source when zooming, bounded by the existing AI capture cap.
     */
    fun requiredSourceLongEdge(
        deliveryLongEdgePx: Int,
        analysisLongEdgePx: Int,
        sourceLongEdgeCapPx: Int
    ): Int {
        require(deliveryLongEdgePx > 0)
        require(analysisLongEdgePx > 0)
        require(sourceLongEdgeCapPx >= analysisLongEdgePx)

        val dominantFraction =
            max(widthFraction, heightFraction)
                .coerceIn(MIN_REGION_SPAN, 1.0)
        val zoomSource =
            ceil(deliveryLongEdgePx.toDouble() / dominantFraction)
                .toInt()

        return maxOf(
            analysisLongEdgePx,
            zoomSource
        ).coerceAtMost(sourceLongEdgeCapPx)
    }

    companion object {
        const val MIN_REGION_SPAN = 0.05
    }
}
