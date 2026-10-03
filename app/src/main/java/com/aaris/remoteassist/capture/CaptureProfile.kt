package com.aaris.remoteassist.capture

import android.app.ActivityManager
import android.content.Context
import android.util.DisplayMetrics
import android.view.WindowManager
import kotlin.math.max
import kotlin.math.roundToInt

enum class CaptureTier {
    LOW,
    BALANCED,
    STANDARD,
    HIGH;

    fun lower(): CaptureTier? =
        when (this) {
            HIGH -> STANDARD
            STANDARD -> BALANCED
            BALANCED -> LOW
            LOW -> null
        }

    fun higher(): CaptureTier? =
        when (this) {
            LOW -> BALANCED
            BALANCED -> STANDARD
            STANDARD -> HIGH
            HIGH -> null
        }
}

data class CaptureProfile(
    val displayWidthPx: Int,
    val displayHeightPx: Int,
    val captureWidthPx: Int,
    val captureHeightPx: Int,
    val fps: Int,
    val maxVideoBitrateBps: Int,
    val tier: CaptureTier
) {
    companion object {
        private const val LOW_CAPTURE_LONG_SIDE = 720
        private const val BALANCED_CAPTURE_LONG_SIDE = 1200

        /*
         * STANDARD is the normal 4 GB-class path. A 2160 ceiling forced a
         * 1080x2400 host to 972x2160 and made the controller upscale every
         * frame again, so even a perfect network could never look fully native.
         * 2400 keeps the dominant modern phone geometry pixel-for-pixel while
         * the governor can still step down immediately when the encoder or path
         * is genuinely constrained.
         *
         * HIGH stays distinct without violating the compatibility-video safety
         * contract, whose current hard dimension ceiling is 2560. That gives
         * capable >=6 GB devices extra detail on QHD-class panels while keeping
         * black-screen recovery valid for every capture tier.
         */
        private const val STANDARD_CAPTURE_LONG_SIDE = 2400
        private const val HIGH_CAPTURE_LONG_SIDE = 2560

        private const val LOW_FPS = 15
        private const val BALANCED_FPS = 24
        private const val STANDARD_FPS = 30
        private const val HIGH_FPS = 30

        /*
         * These are encoder ceilings, not forced send rates. WebRTC congestion
         * control still chooses the actual bitrate from current path capacity.
         * STANDARD gets enough headroom for native 1080x2400 text/UI detail;
         * constrained links remain protected by CaptureQualityGovernor and the
         * sender's own congestion control.
         */
        private const val LOW_BITRATE_BPS = 1_200_000
        private const val BALANCED_BITRATE_BPS = 3_000_000
        private const val STANDARD_BITRATE_BPS = 7_200_000
        private const val HIGH_BITRATE_BPS = 8_000_000

        private const val LOW_MEMORY_BYTES = 3L * 1024L * 1024L * 1024L
        private const val HIGH_MEMORY_BYTES = 6L * 1024L * 1024L * 1024L

        fun recommendedTier(context: Context): CaptureTier {
            val manager =
                context.getSystemService(ActivityManager::class.java)
            if (manager?.isLowRamDevice == true) {
                return CaptureTier.LOW
            }

            val memoryInfo = ActivityManager.MemoryInfo()
            val totalMemory =
                runCatching {
                    manager?.getMemoryInfo(memoryInfo)
                    memoryInfo.totalMem
                }.getOrDefault(0L)

            return when {
                totalMemory <= 0L ->
                    CaptureTier.BALANCED
                totalMemory <= LOW_MEMORY_BYTES ->
                    CaptureTier.LOW
                totalMemory >= HIGH_MEMORY_BYTES ->
                    CaptureTier.HIGH
                else ->
                    CaptureTier.STANDARD
            }
        }

        @Suppress("DEPRECATION")
        fun current(
            context: Context,
            tier: CaptureTier = recommendedTier(context)
        ): CaptureProfile {
            val metrics = DisplayMetrics()
            context.getSystemService(WindowManager::class.java)
                .defaultDisplay
                .getRealMetrics(metrics)

            return forDisplay(
                displayWidthPx = metrics.widthPixels.coerceAtLeast(1),
                displayHeightPx = metrics.heightPixels.coerceAtLeast(1),
                tier = tier
            )
        }

        internal fun forDisplay(
            displayWidthPx: Int,
            displayHeightPx: Int,
            tier: CaptureTier
        ): CaptureProfile {
            val displayWidth = displayWidthPx.coerceAtLeast(1)
            val displayHeight = displayHeightPx.coerceAtLeast(1)
            val longSide = max(displayWidth, displayHeight)

            val maxCaptureLongSide =
                when (tier) {
                    CaptureTier.LOW -> LOW_CAPTURE_LONG_SIDE
                    CaptureTier.BALANCED -> BALANCED_CAPTURE_LONG_SIDE
                    CaptureTier.STANDARD -> STANDARD_CAPTURE_LONG_SIDE
                    CaptureTier.HIGH -> HIGH_CAPTURE_LONG_SIDE
                }

            val scale =
                if (longSide > maxCaptureLongSide) {
                    maxCaptureLongSide.toFloat() /
                        longSide.toFloat()
                } else {
                    1f
                }

            fun even(value: Int): Int {
                val clamped = value.coerceAtLeast(2)
                return if (clamped % 2 == 0) {
                    clamped
                } else {
                    clamped - 1
                }
            }

            val fps =
                when (tier) {
                    CaptureTier.LOW -> LOW_FPS
                    CaptureTier.BALANCED -> BALANCED_FPS
                    CaptureTier.STANDARD -> STANDARD_FPS
                    CaptureTier.HIGH -> HIGH_FPS
                }

            val maxVideoBitrateBps =
                when (tier) {
                    CaptureTier.LOW -> LOW_BITRATE_BPS
                    CaptureTier.BALANCED -> BALANCED_BITRATE_BPS
                    CaptureTier.STANDARD -> STANDARD_BITRATE_BPS
                    CaptureTier.HIGH -> HIGH_BITRATE_BPS
                }

            return CaptureProfile(
                displayWidthPx = displayWidth,
                displayHeightPx = displayHeight,
                captureWidthPx =
                    even((displayWidth * scale).roundToInt()),
                captureHeightPx =
                    even((displayHeight * scale).roundToInt()),
                fps = fps,
                maxVideoBitrateBps = maxVideoBitrateBps,
                tier = tier
            )
        }
    }
}
