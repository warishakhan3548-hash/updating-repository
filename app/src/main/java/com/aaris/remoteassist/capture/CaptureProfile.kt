package com.aaris.remoteassist.capture

import android.app.ActivityManager
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
        private const val MAX_CAPTURE_LONG_SIDE = 960
        private const val LOW_RAM_CAPTURE_LONG_SIDE = 720
        private const val DEFAULT_FPS = 20
        private const val LOW_RAM_FPS = 15

        @Suppress("DEPRECATION")
        fun current(context: Context): CaptureProfile {
            val metrics = DisplayMetrics()
            context.getSystemService(WindowManager::class.java)
                .defaultDisplay
                .getRealMetrics(metrics)

            val displayWidth = metrics.widthPixels.coerceAtLeast(1)
            val displayHeight = metrics.heightPixels.coerceAtLeast(1)
            val longSide = max(displayWidth, displayHeight)
            val lowRam = context
                .getSystemService(ActivityManager::class.java)
                ?.isLowRamDevice == true
            val maxCaptureLongSide =
                if (lowRam) {
                    LOW_RAM_CAPTURE_LONG_SIDE
                } else {
                    MAX_CAPTURE_LONG_SIDE
                }

            val scale = if (longSide > maxCaptureLongSide) {
                maxCaptureLongSide.toFloat() / longSide.toFloat()
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
                fps = if (lowRam) LOW_RAM_FPS else DEFAULT_FPS
            )
        }
    }
}
