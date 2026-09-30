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
        remoteHeight: Int
    ): NormalizedRemotePoint? {
        if (
            viewWidth <= 0f ||
            viewHeight <= 0f ||
            remoteWidth <= 0 ||
            remoteHeight <= 0 ||
            !touchX.isFinite() ||
            !touchY.isFinite()
        ) {
            return null
        }

        val remoteAspect =
            remoteWidth.toFloat() /
                remoteHeight.toFloat()
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

        if (
            touchX < left ||
            touchX > left + contentWidth ||
            touchY < top ||
            touchY > top + contentHeight
        ) {
            return null
        }

        return NormalizedRemotePoint(
            x = (
                (touchX - left) / contentWidth
            ).coerceIn(0f, 1f),
            y = (
                (touchY - top) / contentHeight
            ).coerceIn(0f, 1f)
        )
    }
}
