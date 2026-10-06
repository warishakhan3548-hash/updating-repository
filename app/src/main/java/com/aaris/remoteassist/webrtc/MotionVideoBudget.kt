package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureProfile
import kotlin.math.roundToInt

/**
 * Motion trades pixels before cadence. One-second interval telemetry drives a
 * 720 -> 540 -> 360 short-edge ladder; the MediaProjection surface never changes.
 * This budget owns motion resolution, while the cadence governor remains the
 * final escape hatch when even the smallest frame cannot be delivered promptly.
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
        val sourceUnderDelivery = sourceFps.valid()?.let { it >= goal * 0.8 } == true &&
            sender.fps < goal * 0.75 && outbound.qualityLimitationReason == "bandwidth"
        val pressured = encodePressure || queuePressure || decodePressure || presentationPressure ||
            sourceUnderDelivery || outbound.qualityLimitationReason == "cpu"

        if (pressured) {
            healthySamples = 0
            pressureSamples++
            val severe = (queueMs ?: 0.0) >= 150.0 ||
                (sender.frames >= 2 && sender.fps <= 10.0 && encodePressure)
            if ((severe || pressureSamples >= 2) && nowMs - changedAtMs >= SETTLE_MS) {
                val next = when (shortEdge) { 720 -> 540; else -> 360 }
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
                shortEdge = if (shortEdge == 360) 540 else 720
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
        val canReducePixels = minOf(shortEdge, profile.captureWidthPx, profile.captureHeightPx) > 360
        return if (canReducePixels || nowMs - changedAtMs < SETTLE_MS) minOf(30, profile.motionFps) else 1
    }

    private fun Double?.valid(): Double? = this?.takeIf { it.isFinite() && it >= 0.0 }

    private companion object {
        const val SETTLE_MS = 3_000L
        const val IDLE_RESTORE_MS = 8_000L
    }
}
