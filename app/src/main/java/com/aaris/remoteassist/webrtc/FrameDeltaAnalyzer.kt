package com.aaris.remoteassist.webrtc

import kotlin.math.abs
import kotlin.math.max
import kotlin.math.min

data class DeltaRegion(
    val x: Int,
    val y: Int,
    val width: Int,
    val height: Int
) {
    val area: Long
        get() = width.toLong() * height.toLong()
}

data class FrameDeltaPlan(
    val shiftY: Int,
    val regions: List<DeltaRegion>,
    val changedFraction: Double,
    val forceKeyframe: Boolean
)

/**
 * Cheap luma-only change detector for the compatibility stream.
 *
 * It is deliberately conservative: uncertain scrolling or broad animation
 * falls back to a full JPEG anchor instead of risking visually incorrect
 * patches. A strong vertical translation match allows shift-and-patch, while
 * ordinary UI changes are transmitted as merged dirty regions.
 */
object FrameDeltaAnalyzer {
    private const val TILE_SIZE = 96
    private const val TILE_SAMPLE_STEP = 8
    private const val TILE_DIRTY_AVG_DIFF = 10.0
    private const val FORCE_KEYFRAME_FRACTION = 0.58
    private const val MAX_REGIONS = 12

    private const val SHIFT_SEARCH_STEP = 8
    private const val SHIFT_SAMPLE_STEP = 32
    private const val MAX_SHIFT_PX = 480
    private const val MIN_SHIFT_PX = 16
    private const val MIN_SHIFT_OVERLAP_FRACTION = 0.60
    private const val MAX_STRONG_SHIFT_SCORE = 18.0
    private const val SHIFT_SCORE_RATIO = 0.58

    fun analyze(
        previousY: ByteArray,
        currentY: ByteArray,
        width: Int,
        height: Int
    ): FrameDeltaPlan {
        require(width > 1 && height > 1)
        require(previousY.size >= width * height)
        require(currentY.size >= width * height)

        val zero = dirtyPlan(
            previousY = previousY,
            currentY = currentY,
            width = width,
            height = height,
            shiftY = 0
        )

        val candidateShift = estimateVerticalShift(
            previousY = previousY,
            currentY = currentY,
            width = width,
            height = height
        )

        val chosen =
            if (candidateShift != 0) {
                val shifted = dirtyPlan(
                    previousY = previousY,
                    currentY = currentY,
                    width = width,
                    height = height,
                    shiftY = candidateShift
                )
                if (
                    shifted.changedFraction + 0.08 <
                    zero.changedFraction
                ) {
                    shifted
                } else {
                    zero
                }
            } else {
                zero
            }

        if (chosen.changedFraction <= 0.0) {
            return FrameDeltaPlan(
                shiftY = 0,
                regions = emptyList(),
                changedFraction = 0.0,
                forceKeyframe = false
            )
        }

        var regions = chosen.regions
        if (regions.size > MAX_REGIONS) {
            regions = listOf(boundingRegion(regions))
        }

        val regionArea = regions.sumOf(DeltaRegion::area)
        val canvasArea = width.toLong() * height.toLong()
        val boundingFraction =
            if (canvasArea == 0L) 1.0
            else regionArea.toDouble() / canvasArea.toDouble()

        val forceKeyframe =
            chosen.changedFraction >= FORCE_KEYFRAME_FRACTION ||
                boundingFraction >= 0.72

        return FrameDeltaPlan(
            shiftY = chosen.shiftY,
            regions = if (forceKeyframe) emptyList() else regions,
            changedFraction = chosen.changedFraction,
            forceKeyframe = forceKeyframe
        )
    }

    private data class DirtyResult(
        val shiftY: Int,
        val regions: List<DeltaRegion>,
        val changedFraction: Double
    )

    private fun dirtyPlan(
        previousY: ByteArray,
        currentY: ByteArray,
        width: Int,
        height: Int,
        shiftY: Int
    ): DirtyResult {
        val columns = (width + TILE_SIZE - 1) / TILE_SIZE
        val rows = (height + TILE_SIZE - 1) / TILE_SIZE
        val dirty = BooleanArray(columns * rows)
        var dirtyArea = 0L

        for (row in 0 until rows) {
            val top = row * TILE_SIZE
            val bottom = min(height, top + TILE_SIZE)
            for (column in 0 until columns) {
                val left = column * TILE_SIZE
                val right = min(width, left + TILE_SIZE)
                if (
                    tileIsDirty(
                        previousY = previousY,
                        currentY = currentY,
                        width = width,
                        left = left,
                        top = top,
                        right = right,
                        bottom = bottom,
                        shiftY = shiftY
                    )
                ) {
                    dirty[row * columns + column] = true
                    dirtyArea +=
                        (right - left).toLong() *
                            (bottom - top).toLong()
                }
            }
        }

        val regions = mergeDirtyTiles(
            dirty = dirty,
            columns = columns,
            rows = rows,
            width = width,
            height = height
        )
        val canvasArea = width.toLong() * height.toLong()

        return DirtyResult(
            shiftY = shiftY,
            regions = regions,
            changedFraction =
                if (canvasArea == 0L) 1.0
                else dirtyArea.toDouble() / canvasArea.toDouble()
        )
    }

    private fun tileIsDirty(
        previousY: ByteArray,
        currentY: ByteArray,
        width: Int,
        left: Int,
        top: Int,
        right: Int,
        bottom: Int,
        shiftY: Int
    ): Boolean {
        var totalDiff = 0L
        var samples = 0

        var y = top
        while (y < bottom) {
            val sourceY = y - shiftY
            if (sourceY !in 0 until (currentY.size / width)) {
                return true
            }

            var x = left
            while (x < right) {
                val current =
                    currentY[y * width + x].toInt() and 0xff
                val previous =
                    previousY[sourceY * width + x].toInt() and 0xff
                totalDiff += abs(current - previous)
                samples += 1
                x += TILE_SAMPLE_STEP
            }
            y += TILE_SAMPLE_STEP
        }

        if (samples == 0) return false
        return totalDiff.toDouble() / samples.toDouble() >=
            TILE_DIRTY_AVG_DIFF
    }

    private fun mergeDirtyTiles(
        dirty: BooleanArray,
        columns: Int,
        rows: Int,
        width: Int,
        height: Int
    ): List<DeltaRegion> {
        val regions = ArrayList<DeltaRegion>()

        for (row in 0 until rows) {
            var column = 0
            while (column < columns) {
                if (!dirty[row * columns + column]) {
                    column += 1
                    continue
                }

                val start = column
                while (
                    column + 1 < columns &&
                    dirty[row * columns + column + 1]
                ) {
                    column += 1
                }
                val end = column

                val x = start * TILE_SIZE
                val right = min(width, (end + 1) * TILE_SIZE)
                val y = row * TILE_SIZE
                val bottom = min(height, y + TILE_SIZE)

                val mergeIndex =
                    regions.indexOfLast { region ->
                        region.x == x &&
                            region.width == right - x &&
                            region.y + region.height == y
                    }

                if (mergeIndex >= 0) {
                    val previous = regions[mergeIndex]
                    regions[mergeIndex] =
                        previous.copy(
                            height = bottom - previous.y
                        )
                } else {
                    regions +=
                        DeltaRegion(
                            x = evenFloor(x),
                            y = evenFloor(y),
                            width = evenExtent(
                                start = evenFloor(x),
                                endExclusive = right,
                                limit = width
                            ),
                            height = evenExtent(
                                start = evenFloor(y),
                                endExclusive = bottom,
                                limit = height
                            )
                        )
                }
                column += 1
            }
        }

        return regions.filter {
            it.width > 0 && it.height > 0
        }
    }

    private fun estimateVerticalShift(
        previousY: ByteArray,
        currentY: ByteArray,
        width: Int,
        height: Int
    ): Int {
        val maxShift = min(MAX_SHIFT_PX, height / 3)
        if (maxShift < MIN_SHIFT_PX) return 0

        val zeroScore = shiftScore(
            previousY,
            currentY,
            width,
            height,
            sourceOffsetY = 0
        ) ?: return 0

        var bestSourceOffset = 0
        var bestScore = Double.POSITIVE_INFINITY

        var offset = -maxShift
        while (offset <= maxShift) {
            if (abs(offset) >= MIN_SHIFT_PX) {
                val score =
                    shiftScore(
                        previousY,
                        currentY,
                        width,
                        height,
                        sourceOffsetY = offset
                    )
                if (score != null && score < bestScore) {
                    bestScore = score
                    bestSourceOffset = offset
                }
            }
            offset += SHIFT_SEARCH_STEP
        }

        if (
            bestSourceOffset == 0 ||
            !bestScore.isFinite() ||
            bestScore > MAX_STRONG_SHIFT_SCORE ||
            zeroScore <= 0.0 ||
            bestScore > zeroScore * SHIFT_SCORE_RATIO
        ) {
            return 0
        }

        // current(y) ~= previous(y + sourceOffset), therefore the old bitmap
        // must move by -sourceOffset to predict the current frame.
        return -bestSourceOffset
    }

    private fun shiftScore(
        previousY: ByteArray,
        currentY: ByteArray,
        width: Int,
        height: Int,
        sourceOffsetY: Int
    ): Double? {
        val startY = max(0, -sourceOffsetY)
        val endY = min(height, height - sourceOffsetY)
        val overlap = endY - startY
        if (
            overlap <= 0 ||
            overlap.toDouble() / height.toDouble() <
            MIN_SHIFT_OVERLAP_FRACTION
        ) {
            return null
        }

        var total = 0L
        var samples = 0
        var y = startY + SHIFT_SAMPLE_STEP / 2
        while (y < endY) {
            val sourceY = y + sourceOffsetY
            var x = SHIFT_SAMPLE_STEP / 2
            while (x < width) {
                val current =
                    currentY[y * width + x].toInt() and 0xff
                val previous =
                    previousY[sourceY * width + x].toInt() and 0xff
                total += abs(current - previous)
                samples += 1
                x += SHIFT_SAMPLE_STEP
            }
            y += SHIFT_SAMPLE_STEP
        }

        if (samples < 16) return null
        return total.toDouble() / samples.toDouble()
    }

    private fun boundingRegion(
        regions: List<DeltaRegion>
    ): DeltaRegion {
        val left = regions.minOf { it.x }
        val top = regions.minOf { it.y }
        val right = regions.maxOf { it.x + it.width }
        val bottom = regions.maxOf { it.y + it.height }
        return DeltaRegion(
            x = left,
            y = top,
            width = right - left,
            height = bottom - top
        )
    }

    private fun evenFloor(value: Int): Int =
        value and 1.inv()

    private fun evenExtent(
        start: Int,
        endExclusive: Int,
        limit: Int
    ): Int {
        val clampedEnd = endExclusive.coerceIn(start + 1, limit)
        var size = clampedEnd - start
        if (size % 2 != 0) {
            size =
                if (clampedEnd < limit) size + 1
                else max(2, size - 1)
        }
        return size.coerceAtMost(limit - start)
    }
}
