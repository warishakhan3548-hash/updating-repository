package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import com.aaris.remoteassist.capture.CaptureTier
import kotlin.math.max
import kotlin.math.roundToInt

/**
 * Converts the clarity-first capture profile into a latency-first interaction
 * profile without ever resizing Android's MediaProjection surface itself.
 *
 * Remote control is different from passive screen sharing: while a finger,
 * fling, launcher transition or page animation is moving pixels, a fresh
 * slightly softer frame is more useful than a perfect old frame. The source
 * keeps its stable virtual-display geometry; only VideoSource adaptation is
 * allowed to reduce the encode pixel budget during the short interaction tail.
 */
internal object RealtimeMotionPolicy {
    private const val STANDARD_MOTION_LONG_SIDE_PX = 1_920
    private const val HIGH_MOTION_LONG_SIDE_PX = 2_400

    fun apply(
        base: CaptureProfile,
        interactionActive: Boolean,
        cadenceCap: Int
    ): CaptureProfile {
        /*
         * The fast presentation governor starts at the clarity profile's idle
         * cadence, then may raise its cap only after repeated healthy rendered
         * windows. Let that measured cap unlock motionFps even without a finger
         * down so passive 60 Hz content (video/game animation) is not permanently
         * stuck at the idle 45 Hz ceiling. Static screens do not manufacture
         * frames, and any failed high-cadence probe is already backed off by the
         * governor.
         */
        val targetFps =
            minOf(base.motionFps, cadenceCap)
                .coerceAtLeast(1)

        if (!interactionActive) {
            // Ambient cadence probes keep full text/UI resolution. Only active
            // control is allowed to trade spatial detail for motion freshness.
            return if (targetFps == base.fps) base else base.copy(fps = targetFps)
        }

        val motionLongSide = when (base.tier) {
            CaptureTier.LOW -> 720
            CaptureTier.BALANCED -> 1_200
            CaptureTier.STANDARD -> STANDARD_MOTION_LONG_SIDE_PX
            CaptureTier.HIGH -> HIGH_MOTION_LONG_SIDE_PX
        }

        val currentLongSide = max(base.captureWidthPx, base.captureHeightPx)
        if (currentLongSide <= motionLongSide) {
            return if (targetFps == base.fps) base else base.copy(fps = targetFps)
        }

        val scale = motionLongSide.toDouble() / currentLongSide.toDouble()

        fun scaledEven(value: Int): Int {
            val rounded = (value * scale).roundToInt().coerceAtLeast(2)
            return if (rounded % 2 == 0) rounded else rounded - 1
        }

        return base.copy(
            captureWidthPx = scaledEven(base.captureWidthPx),
            captureHeightPx = scaledEven(base.captureHeightPx),
            fps = targetFps
        )
    }
}
