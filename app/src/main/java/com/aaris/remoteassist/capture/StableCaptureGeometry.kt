package com.aaris.remoteassist.capture

/** Network/FPS adaptation must not resize Android's mirrored display surface. */
internal class StableCaptureGeometry(initial: CaptureProfile) {
    private val sourceLongSide = maxOf(initial.captureWidthPx, initial.captureHeightPx)
    private var displayWidth = initial.displayWidthPx
    private var displayHeight = initial.displayHeightPx
    var width = initial.captureWidthPx
        private set
    var height = initial.captureHeightPx
        private set

    fun updateDisplay(profile: CaptureProfile): Boolean {
        if (profile.displayWidthPx == displayWidth && profile.displayHeightPx == displayHeight) return false
        displayWidth = profile.displayWidthPx
        displayHeight = profile.displayHeightPx
        val scale = minOf(1.0, sourceLongSide.toDouble() / maxOf(displayWidth, displayHeight))
        val nextWidth = ((displayWidth * scale).toInt() / 2 * 2).coerceAtLeast(2)
        val nextHeight = ((displayHeight * scale).toInt() / 2 * 2).coerceAtLeast(2)
        val changed = nextWidth != width || nextHeight != height
        width = nextWidth; height = nextHeight
        return changed
    }
}
