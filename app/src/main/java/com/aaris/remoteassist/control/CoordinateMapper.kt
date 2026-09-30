package com.aaris.remoteassist.control

data class FloatRect(
    val left: Float,
    val top: Float,
    val right: Float,
    val bottom: Float
) {
    val width: Float get() = right - left
    val height: Float get() = bottom - top

    fun contains(x: Float, y: Float): Boolean =
        x >= left && x <= right && y >= top && y <= bottom
}

data class RemoteDisplay(
    val widthPx: Int,
    val heightPx: Int,
    val generation: Int
) {
    init {
        require(widthPx > 0 && heightPx > 0)
        require(generation >= 0)
    }
}

data class RemotePoint(
    val xPx: Float,
    val yPx: Float,
    val nx: Float,
    val ny: Float,
    val generation: Int
)

object CoordinateMapper {
    fun map(
        controllerX: Float,
        controllerY: Float,
        renderedRemoteRect: FloatRect,
        remote: RemoteDisplay
    ): RemotePoint? {
        if (renderedRemoteRect.width <= 0f || renderedRemoteRect.height <= 0f) return null
        if (!renderedRemoteRect.contains(controllerX, controllerY)) return null

        val nx = ((controllerX - renderedRemoteRect.left) / renderedRemoteRect.width)
            .coerceIn(0f, 1f)
        val ny = ((controllerY - renderedRemoteRect.top) / renderedRemoteRect.height)
            .coerceIn(0f, 1f)

        return RemotePoint(
            xPx = nx * (remote.widthPx - 1),
            yPx = ny * (remote.heightPx - 1),
            nx = nx,
            ny = ny,
            generation = remote.generation
        )
    }
}
