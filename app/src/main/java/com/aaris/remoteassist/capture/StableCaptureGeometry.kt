package com.aaris.remoteassist.capture

/**
 * A transactional MediaProjection producer-geometry change.
 *
 * Planning is side-effect free. [StableCaptureGeometry.commit] advances the
 * authoritative producer geometry only after ScreenCapturerAndroid accepts the
 * matching VirtualDisplay change. That keeps a failed vendor resize retryable
 * instead of silently recording geometry that never reached the producer.
 */
internal data class StableCaptureGeometryPlan(
    val previousDisplayWidth: Int,
    val previousDisplayHeight: Int,
    val previousWidth: Int,
    val previousHeight: Int,
    val displayWidth: Int,
    val displayHeight: Int,
    val width: Int,
    val height: Int
) {
    val changed: Boolean
        get() = width != previousWidth || height != previousHeight

    /**
     * Growing (or equal-area reshaping such as portrait <-> landscape) must make
     * producer pixels available before VideoSource is allowed to demand the new
     * output geometry. Spatial relief does the inverse: cap downstream demand
     * first, then shrink the producer.
     */
    val producerBeforeOutput: Boolean
        get() {
            if (!changed) return false
            val previousPixels =
                previousWidth.toLong() * previousHeight.toLong()
            val nextPixels =
                width.toLong() * height.toLong()
            return nextPixels >= previousPixels
        }
}

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

    /**
     * Compute the next producer geometry without mutating the committed state.
     *
     * This separation is important because ScreenCapturerAndroid ultimately
     * delegates to vendor display/codec plumbing that can reject or throw during
     * a live resize. The caller can therefore leave this plan uncommitted and
     * retry the exact producer transition on the next policy pass.
     */
    fun planUpdate(
        profile: CaptureProfile,
        allowAdaptiveResize: Boolean
    ): StableCaptureGeometryPlan {
        // Preserve the exact initial rounded dimensions on the legacy path.
        // Recomputing an unchanged display with floor rounding can otherwise
        // turn a cadence-only update into a VirtualDisplay recreation.
        if (
            !allowAdaptiveResize &&
            profile.displayWidthPx == displayWidth &&
            profile.displayHeightPx == displayHeight
        ) {
            return plan(
                nextDisplayWidth = displayWidth,
                nextDisplayHeight = displayHeight,
                nextWidth = width,
                nextHeight = height
            )
        }

        val nextDisplayWidth = profile.displayWidthPx
        val nextDisplayHeight = profile.displayHeightPx

        val requestedWidth: Int
        val requestedHeight: Int
        if (allowAdaptiveResize) {
            requestedWidth = profile.captureWidthPx
            requestedHeight = profile.captureHeightPx
        } else {
            requestedWidth = nextDisplayWidth
            requestedHeight = nextDisplayHeight
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

        return plan(
            nextDisplayWidth = nextDisplayWidth,
            nextDisplayHeight = nextDisplayHeight,
            nextWidth = even(requestedWidth),
            nextHeight = even(requestedHeight)
        )
    }

    /**
     * Commit only the exact plan produced from the current geometry.
     *
     * The stale-plan guard makes this ownership explicit and protects future
     * callers if display/profile updates ever arrive from more than one lane.
     */
    fun commit(plan: StableCaptureGeometryPlan) {
        require(
            plan.previousDisplayWidth == displayWidth &&
                plan.previousDisplayHeight == displayHeight &&
                plan.previousWidth == width &&
                plan.previousHeight == height
        ) {
            "Stale capture geometry plan"
        }

        displayWidth = plan.displayWidth
        displayHeight = plan.displayHeight
        width = plan.width
        height = plan.height
    }

    private fun plan(
        nextDisplayWidth: Int,
        nextDisplayHeight: Int,
        nextWidth: Int,
        nextHeight: Int
    ): StableCaptureGeometryPlan =
        StableCaptureGeometryPlan(
            previousDisplayWidth = displayWidth,
            previousDisplayHeight = displayHeight,
            previousWidth = width,
            previousHeight = height,
            displayWidth = nextDisplayWidth,
            displayHeight = nextDisplayHeight,
            width = nextWidth,
            height = nextHeight
        )
}
