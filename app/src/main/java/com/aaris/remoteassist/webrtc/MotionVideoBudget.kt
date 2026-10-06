package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import kotlin.math.roundToInt

/**
 * Motion trades pixels before cadence. One-second interval telemetry drives a
 * 720 -> 540 -> 360 -> 240 ladder, with a final 180 short-edge freshness rung
 * only when moving-source evidence proves a bandwidth-limited stale queue.
 * The MediaProjection surface never changes.
 *
 * The key invariant is "new pixels beat old pixels": under congestion we spend
 * resolution before cadence so WebRTC's MAINTAIN_FRAMERATE policy is not
 * accidentally defeated by our own source cap. The cadence governor remains
 * the final escape hatch when even the smallest frame cannot be delivered
 * promptly.
 */
internal class MotionVideoBudget {
    var shortEdge = 720
        private set
    private var holdingResolution = false
    private var lastMotionAtMs = Long.MIN_VALUE / 2
    private var changedAtMs = Long.MIN_VALUE / 2
    private var pressureSamples = 0
    private var healthySamples = 0
    private var lastImplementation: String? = null
    private var lastBandwidthPressureAtMs = Long.MIN_VALUE / 2

    /**
     * New motion should not spend its first one or two telemetry windows trying
     * to push a full 720-short-edge stream through an unknown encoder/path.
     * Warm-start STANDARD/HIGH motion at 540, hold 30 fps, then let measured
     * end-to-end health earn 720 back. Repeated pulses only refresh the hold;
     * they never knock a continuously healthy stream back down after recovery.
     */
    fun primeForMotion(
        profile: CaptureProfile,
        nowMs: Long
    ): Boolean {
        if (nowMs < 0L) return false

        val before = shortEdge to holdingResolution
        val enteringMotion = !holdingResolution
        holdingResolution = true
        lastMotionAtMs = nowMs

        if (enteringMotion) {
            pressureSamples = 0
            healthySamples = 0

            val profileShortEdge =
                minOf(profile.captureWidthPx, profile.captureHeightPx)
            if (
                profileShortEdge > MOTION_WARM_START_SHORT_EDGE &&
                shortEdge > MOTION_WARM_START_SHORT_EDGE
            ) {
                shortEdge = MOTION_WARM_START_SHORT_EDGE
                changedAtMs = nowMs
            }
        }

        return before != (shortEdge to holdingResolution)
    }

    fun observe(
        outbound: VideoHealthSnapshot,
        receiver: VideoHealthWindow?,
        sourceFps: Double?,
        motionActive: Boolean,
        targetFps: Int,
        nowMs: Long
    ): Boolean {
        val before = shortEdge to holdingResolution
        val enteringMotion = !holdingResolution
        if (!motionActive) {
            pressureSamples = 0
            healthySamples = 0
            if (nowMs - lastMotionAtMs >= IDLE_RESTORE_MS) {
                lastBandwidthPressureAtMs = Long.MIN_VALUE / 2
                holdingResolution = false
                shortEdge = 720
            }
            return before != (shortEdge to holdingResolution)
        }
        holdingResolution = true
        lastMotionAtMs = nowMs
        val sender = outbound.recent?.takeIf { it.intervalMs in 500..6000 && it.frames >= 0 }
        if (sender == null) {
            pressureSamples = 0
            healthySamples = 0
            return before != (shortEdge to holdingResolution)
        }

        // Detect the encoder actually in use, not just the negotiated MIME type.
        // Hardware remains preferred; software fallback must stay usable as well.
        val implementation = outbound.codecImplementation?.lowercase()
        if (!implementation.isNullOrBlank() && (implementation != lastImplementation || enteringMotion)) {
            lastImplementation = implementation
            if (listOf("libvpx", "libaom", "openh264", "software").any(implementation::contains) && shortEdge > 540) {
                shortEdge = 540
                changedAtMs = nowMs
                pressureSamples = 0
                healthySamples = 0
                return true
            }
        }

        val goal = targetFps.coerceIn(1, 30)
        val frameMs = 1000.0 / goal
        val encodeMs = sender.processingMs.valid()
        val queueMs = sender.sendQueueMs.valid()
        val received = receiver?.takeIf { it.intervalMs in 500..6000 && it.frames >= 2 }
        val decodeMs = received?.processingMs.valid()
        val jitterMs = received?.jitterMs.valid()
        val underDelivery = sender.fps < goal * 0.85
        val encodePressure = sender.frames >= 2 && underDelivery && (encodeMs ?: 0.0) > frameMs * 0.85
        val queuePressure = (queueMs ?: 0.0) >= 80.0 || (jitterMs ?: 0.0) >= 100.0
        val decodePressure = received != null && (decodeMs ?: 0.0) > frameMs * 0.85 &&
            received.fps < minOf(sender.fps, goal.toDouble()) * 0.85
        val expectedPresentation = minOf(goal.toDouble(), sender.fps, received?.fps ?: 0.0)
        val presentationPressure = expectedPresentation >= 10.0 && received?.presentedFps?.let {
            it < expectedPresentation * 0.8 || (received.maxRenderGapMs ?: 0) >= 150
        } == true
        val measuredSourceFps = sourceFps.valid()
        val movingSource =
            measuredSourceFps?.let { it >= MIN_MOVING_SOURCE_FPS } == true
        val senderLagsMovingSource =
            measuredSourceFps?.let {
                sender.fps < minOf(goal.toDouble(), it) * 0.75
            } == true
        val bandwidthLimited =
            outbound.qualityLimitationReason.equals("bandwidth", ignoreCase = true)
        val bandwidthUnderDelivery =
            movingSource && senderLagsMovingSource && bandwidthLimited
        val bandwidthFreshnessPressure =
            bandwidthUnderDelivery &&
                (
                    (queueMs ?: 0.0) >= NETWORK_QUEUE_PRESSURE_MS ||
                        sender.fps < goal * 0.60
                )
        val severeBandwidthFreshnessPressure =
            bandwidthUnderDelivery &&
                (
                    (queueMs ?: 0.0) >= SEVERE_NETWORK_QUEUE_MS ||
                        sender.fps < goal * 0.45
                )
        if (bandwidthFreshnessPressure) {
            lastBandwidthPressureAtMs = nowMs
        }
        val pressured = encodePressure || queuePressure || decodePressure || presentationPressure ||
            bandwidthUnderDelivery || outbound.qualityLimitationReason == "cpu"

        if (pressured) {
            healthySamples = 0
            pressureSamples++
            val severe = (queueMs ?: 0.0) >= 150.0 ||
                (sender.frames >= 2 && sender.fps <= 10.0 && encodePressure) ||
                severeBandwidthFreshnessPressure
            val settleMs =
                if (severeBandwidthFreshnessPressure) BANDWIDTH_FAST_SETTLE_MS else SETTLE_MS
            if ((severe || pressureSamples >= 2) && nowMs - changedAtMs >= settleMs) {
                val next = when {
                    shortEdge > 540 -> 540
                    shortEdge > 360 -> 360
                    // When a moving source is bandwidth-limited, a 360-wide
                    // frame is still too expensive if the pacer is holding old
                    // packets. Spend pixels before sacrificing temporal motion.
                    shortEdge > 240 &&
                        (encodePressure || decodePressure || bandwidthFreshnessPressure) -> 240
                    // 180 is deliberately reserved for proven, severe
                    // bandwidth staleness. Ordinary RTT/jitter spikes and a
                    // healthy 30 fps sender cannot blur the stream this far.
                    shortEdge > 180 && severeBandwidthFreshnessPressure -> 180
                    else -> shortEdge
                }
                if (next != shortEdge) {
                    shortEdge = next
                    changedAtMs = nowMs
                }
                pressureSamples = 0
            }
        } else {
            pressureSamples = 0
            // A clean RTT or a reduced 15 fps cap is not proof that larger frames fit.
            val receiverHealthy = if (received == null) {
                receiver == null && outbound.qualityLimitationReason == "none" &&
                    outbound.roundTripTimeMs?.let { it in 0..300 } == true
            } else {
                decodeMs != null && decodeMs < frameMs * 0.55 &&
                    jitterMs != null && jitterMs < 40.0 && received.fps >= goal * 0.9 &&
                    (received.dropped ?: 0) == 0 && (received.freezes ?: 0) == 0 &&
                    (received.presentedFps?.let { it >= goal * 0.9 } ?: true) &&
                    (received.maxRenderGapMs ?: 0) < 100
            }
            val healthy = sender.fps >= goal * 0.9 && encodeMs != null && encodeMs < frameMs * 0.5 &&
                queueMs != null && queueMs < 20.0 && receiverHealthy &&
                (outbound.packetLossRatio ?: 0.0) < 0.025
            healthySamples = if (healthy) healthySamples + 1 else 0
            if (healthySamples >= 12 && nowMs - changedAtMs >= 12_000L && shortEdge < 720) {
                shortEdge = when { shortEdge < 360 -> 360; shortEdge < 540 -> 540; else -> 720 }
                changedAtMs = nowMs
                healthySamples = 0
            }
        }
        return before != (shortEdge to holdingResolution)
    }

    fun apply(profile: CaptureProfile, motionActive: Boolean): CaptureProfile {
        if (!motionActive && !holdingResolution) return profile
        val edge = minOf(profile.captureWidthPx, profile.captureHeightPx)
        if (edge <= shortEdge) return profile
        val scale = shortEdge.toDouble() / edge
        fun even(value: Int) = ((value * scale).roundToInt() / 2 * 2).coerceAtLeast(2)
        return profile.copy(captureWidthPx = even(profile.captureWidthPx), captureHeightPx = even(profile.captureHeightPx))
    }

    fun cadenceFloor(profile: CaptureProfile, motionActive: Boolean, nowMs: Long): Int {
        if (!motionActive) return 1

        // Keep at least 24 fps while a recent bandwidth-limited moving source
        // still has a cheaper pixel rung available. This is the Java-side
        // counterpart of MAINTAIN_FRAMERATE: do not hard-cap the source to 15
        // fps while 360/240-wide frames are still clogging the pacer.
        val bandwidthReliefActive =
            nowMs - lastBandwidthPressureAtMs in 0L..BANDWIDTH_PRESSURE_HOLD_MS
        if (bandwidthReliefActive && shortEdge > MIN_BANDWIDTH_SHORT_EDGE) {
            return minOf(BANDWIDTH_CADENCE_FLOOR_FPS, profile.motionFps)
        }

        // After every actual pixel step, give the new frame size a short window
        // to drain the old queue before cadence is allowed to fall. Once the
        // 180-wide emergency rung has settled, cadence may still step down if
        // the path genuinely cannot sustain fresh frames.
        return if (nowMs - changedAtMs < SETTLE_MS) minOf(30, profile.motionFps) else 1
    }

    fun bitrateCeiling(profile: CaptureProfile, motionActive: Boolean): Int {
        if (!motionActive && !holdingResolution) return profile.maxVideoBitrateBps
        val motionCeiling = when {
            shortEdge <= 180 -> 350_000
            shortEdge <= 240 -> 500_000
            shortEdge <= 360 -> 900_000
            shortEdge <= 540 -> 1_800_000
            else -> profile.maxVideoBitrateBps
        }
        return minOf(profile.maxVideoBitrateBps, motionCeiling)
    }

    private fun Double?.valid(): Double? = this?.takeIf { it.isFinite() && it >= 0.0 }

    private companion object {
        const val MOTION_WARM_START_SHORT_EDGE = 360
        const val SETTLE_MS = 3_000L
        const val BANDWIDTH_FAST_SETTLE_MS = 1_000L
        const val BANDWIDTH_PRESSURE_HOLD_MS = 2_500L
        const val MIN_MOVING_SOURCE_FPS = 8.0
        const val NETWORK_QUEUE_PRESSURE_MS = 90.0
        const val SEVERE_NETWORK_QUEUE_MS = 250.0
        const val MIN_BANDWIDTH_SHORT_EDGE = 180
        const val BANDWIDTH_CADENCE_FLOOR_FPS = 24
        const val IDLE_RESTORE_MS = 8_000L
    }
}
