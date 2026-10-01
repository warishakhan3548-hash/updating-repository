package com.aaris.remoteassist.ui

data class NormalizedRemotePoint(
    val x: Float,
    val y: Float
)

object RemoteViewportMapper {
    fun normalize(
        touchX: Float,
        touchY: Float,
        viewWidth: Float,
        viewHeight: Float,
        remoteWidth: Int,
        remoteHeight: Int,
        frameWidth: Int = remoteWidth,
        frameHeight: Int = remoteHeight,
        clampToContent: Boolean = false
    ): NormalizedRemotePoint? {
        if (
            viewWidth <= 0f ||
            viewHeight <= 0f ||
            remoteWidth <= 0 ||
            remoteHeight <= 0 ||
            frameWidth <= 0 ||
            frameHeight <= 0 ||
            !touchX.isFinite() ||
            !touchY.isFinite()
        ) {
            return null
        }

        val remoteAspect =
            frameWidth.toFloat() /
                frameHeight.toFloat()
        val viewAspect =
            viewWidth / viewHeight

        val left: Float
        val top: Float
        val contentWidth: Float
        val contentHeight: Float

        if (viewAspect > remoteAspect) {
            contentHeight = viewHeight
            contentWidth = viewHeight * remoteAspect
            left = (viewWidth - contentWidth) / 2f
            top = 0f
        } else {
            contentWidth = viewWidth
            contentHeight = viewWidth / remoteAspect
            left = 0f
            top = (viewHeight - contentHeight) / 2f
        }

        val outsideContent =
            touchX < left ||
                touchX > left + contentWidth ||
                touchY < top ||
                touchY > top + contentHeight
        if (outsideContent && !clampToContent) {
            return null
        }

        val mappedX =
            if (clampToContent) {
                touchX.coerceIn(left, left + contentWidth)
            } else {
                touchX
            }
        val mappedY =
            if (clampToContent) {
                touchY.coerceIn(top, top + contentHeight)
            } else {
                touchY
            }

        return NormalizedRemotePoint(
            x = (
                (mappedX - left) / contentWidth
            ).coerceIn(0f, 1f),
            y = (
                (mappedY - top) / contentHeight
            ).coerceIn(0f, 1f)
        )
    }

    fun frameMatchesRemote(
        remoteWidth: Int,
        remoteHeight: Int,
        frameWidth: Int,
        frameHeight: Int,
        tolerance: Float = 0.035f
    ): Boolean {
        if (
            remoteWidth <= 0 ||
            remoteHeight <= 0 ||
            frameWidth <= 0 ||
            frameHeight <= 0
        ) {
            return false
        }

        val remoteAspect =
            remoteWidth.toFloat() / remoteHeight.toFloat()
        val frameAspect =
            frameWidth.toFloat() / frameHeight.toFloat()
        val relativeError =
            kotlin.math.abs(frameAspect - remoteAspect) /
                remoteAspect.coerceAtLeast(0.0001f)

        return relativeError <= tolerance
    }
}
