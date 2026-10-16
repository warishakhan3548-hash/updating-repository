package com.aaris.remoteassist.capture

/**
 * Owns the MediaProjection producer surface geometry.
 *
 * Before Android 12, WebRTC recreates the VirtualDisplay for every format
 * change and some OEMs can mirror it with the wrong scale. Keep the original
 * source pixel budget on those devices and resize only for real display
 * geometry changes.
 *
 * Android 12+ uses VirtualDisplay.resize() in ScreenCapturerAndroid. There the
 * producer may follow the application's already-hysteresis-gated spatial
 * envelope so pixel relief happens before texture production, not only after a
 * full-size frame reaches VideoSource.
 */
internal class StableCaptureGeometry(initial: CaptureProfile) {
    private val sourceLongSide = maxOf(initial.captureWidthPx, initial.captureHeightPx)
    private var displayWidth = initial.displayWidthPx
    private var displayHeight = initial.displayHeightPx

    var width = initial.captureWidthPx
        private set

    var height = initial.captureHeightPx
        private set

    fun update(
        profile: CaptureProfile,
        allowAdaptiveResize: Boolean
    ): Boolean {
        // Preserve the exact initial rounded dimensions on the legacy path.
        // Recomputing an unchanged display with floor rounding can otherwise
        // turn a cadence-only update into a VirtualDisplay recreation.
        if (
            !allowAdaptiveResize &&
            profile.displayWidthPx == displayWidth &&
            profile.displayHeightPx == displayHeight
        ) {
            return false
        }
        displayWidth = profile.displayWidthPx
        displayHeight = profile.displayHeightPx

        val requestedWidth: Int
        val requestedHeight: Int
        if (allowAdaptiveResize) {
            requestedWidth = profile.captureWidthPx
            requestedHeight = profile.captureHeightPx
        } else {
            requestedWidth = displayWidth
            requestedHeight = displayHeight
        }

        val requestedLongSide =
            maxOf(requestedWidth, requestedHeight)
                .coerceAtLeast(1)
        val scale =
            minOf(
                1.0,
                sourceLongSide.toDouble() / requestedLongSide.toDouble()
            )

        fun even(value: Int): Int =
            ((value * scale).toInt() / 2 * 2)
                .coerceAtLeast(2)

        val nextWidth = even(requestedWidth)
        val nextHeight = even(requestedHeight)
        val changed = nextWidth != width || nextHeight != height
        width = nextWidth
        height = nextHeight
        return changed
    }
}
