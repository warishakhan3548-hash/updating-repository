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
    val tier: CaptureTier,
    val motionFps: Int = fps
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
         * contract. That gives capable >=6 GB devices extra detail on QHD-class
         * panels while keeping black-screen recovery valid for every tier.
         */
        private const val STANDARD_CAPTURE_LONG_SIDE = 2400
        private const val HIGH_CAPTURE_LONG_SIDE =
            CaptureVideoContract.MAX_FALLBACK_SAFE_LONG_SIDE_PX

        private const val LOW_FPS = 15
        private const val BALANCED_FPS = 24

        /*
         * Idle here means "no remote finger is down", not "the screen is
         * static". Games, video, progress animations and inertial scrolling can
         * keep changing after input has stopped. Keeping capable phones at a
         * display-class ambient ceiling prevents those pixels from falling back
         * to a visibly choppy 30 Hz stream. The cadence governor remains the
         * authority: it can immediately step 60/45 down when encoder, queue,
         * network or receiver presentation pressure says that the path cannot
         * sustain it.
         */
        private const val STANDARD_FPS = 45
        private const val HIGH_FPS = 60

        // Motion is bursty: use higher cadence while the controller is actively
        // touching or while the resulting fling/animation is settling.
        // Constrained tiers remain conservative; STANDARD/HIGH can match a
        // common 60Hz phone display when the encoder and path are healthy.
        private const val LOW_MOTION_FPS = 20
        private const val BALANCED_MOTION_FPS = 30
        private const val STANDARD_MOTION_FPS = 60
        private const val HIGH_MOTION_FPS = 60

        /*
         * These are encoder ceilings, not forced send rates. WebRTC congestion
         * control still chooses the actual bitrate from current path capacity.
         * STANDARD gets enough headroom for native 1080x2400 text/UI detail;
         * constrained links remain protected by CaptureQualityGovernor and the
         * sender's own congestion control.
         */
        private const val LOW_BITRATE_BPS = 1_200_000
        private const val BALANCED_BITRATE_BPS = 3_000_000
        private const val STANDARD_BITRATE_BPS = 10_000_000
        private const val HIGH_BITRATE_BPS = 12_000_000

        private const val LOW_MEMORY_BYTES = 3L * 1024L * 1024L * 1024L
        private const val HIGH_MEMORY_BYTES = 6L * 1024L * 1024L * 1024L

        fun recommendedTier(context: Context): CaptureTier {
            val manager =
                context.getSystemService(ActivityManager::class.java)
            val memoryInfo = ActivityManager.MemoryInfo()
            val totalMemory =
                runCatching {
                    manager?.getMemoryInfo(memoryInfo)
                    memoryInfo.totalMem
                }.getOrDefault(0L)

            return recommendedTierForDevice(
                isLowRamDevice = manager?.isLowRamDevice == true,
                totalMemoryBytes = totalMemory
            )
        }

        internal fun recommendedTierForDevice(
            isLowRamDevice: Boolean,
            totalMemoryBytes: Long
        ): CaptureTier {
            if (isLowRamDevice) {
                return CaptureTier.LOW
            }

            return when {
                /*
                 * Unknown hardware must fail safe rather than accidentally
                 * assuming a STANDARD encoder budget. BALANCED still delivers
                 * usable 24 fps video while protecting unusual/vendor devices.
                 */
                totalMemoryBytes <= 0L ->
                    CaptureTier.BALANCED
                totalMemoryBytes <= LOW_MEMORY_BYTES ->
                    CaptureTier.LOW
                totalMemoryBytes >= HIGH_MEMORY_BYTES ->
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

            val motionFps =
                when (tier) {
                    CaptureTier.LOW -> LOW_MOTION_FPS
                    CaptureTier.BALANCED -> BALANCED_MOTION_FPS
                    CaptureTier.STANDARD -> STANDARD_MOTION_FPS
                    CaptureTier.HIGH -> HIGH_MOTION_FPS
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
                tier = tier,
                motionFps = motionFps
            )
        }
    }
}
