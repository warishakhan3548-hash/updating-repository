package com.aaris.remoteassist.capture

import android.content.Context
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlin.math.max
import kotlin.math.roundToInt

data class CaptureProfile(
    val displayWidthPx: Int,
    val displayHeightPx: Int,
    val captureWidthPx: Int,
    val captureHeightPx: Int,
    val fps: Int
) {
    companion object {
        private const val MAX_CAPTURE_LONG_SIDE = 1280
        private const val DEFAULT_FPS = 30

        @Suppress("DEPRECATION")
        fun current(context: Context): CaptureProfile {
            val metrics = DisplayMetrics()
            context.getSystemService(WindowManager::class.java)
                .defaultDisplay
                .getRealMetrics(metrics)

            val displayWidth = metrics.widthPixels.coerceAtLeast(1)
            val displayHeight = metrics.heightPixels.coerceAtLeast(1)
            val longSide = max(displayWidth, displayHeight)

            val scale = if (longSide > MAX_CAPTURE_LONG_SIDE) {
                MAX_CAPTURE_LONG_SIDE.toFloat() / longSide.toFloat()
            } else {
                1f
            }

            fun even(value: Int): Int {
                val clamped = value.coerceAtLeast(2)
                return if (clamped % 2 == 0) clamped else clamped - 1
            }

            return CaptureProfile(
                displayWidthPx = displayWidth,
                displayHeightPx = displayHeight,
                captureWidthPx = even((displayWidth * scale).roundToInt()),
                captureHeightPx = even((displayHeight * scale).roundToInt()),
                fps = DEFAULT_FPS
            )
        }
    }
}
