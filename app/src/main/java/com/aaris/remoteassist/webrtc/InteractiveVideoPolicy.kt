package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier

/**
 * Use the native WebRTC degradation actuator for the content that is actually
 * on screen, instead of pinning the whole session to one policy.
 *
 * While interaction or passive screen motion is active, freshness remains the
 * priority, but MotionVideoBudget stays the single spatial owner. Native WebRTC
 * overuse may shed temporal cadence to bound encoder debt; measured app policy
 * decides if source pixels must change. Once the screen becomes quiet, preserve
 * resolution so text/forms/icons recover to the clearest sustainable result.
 *
 * MotionVideoBudget and VideoCadenceGovernor own the app's explicit
 * spatial/cadence envelopes. This policy only labels the current state for the
 * native overuse preference; it adds no queue, encoder, or frame copy.
 */
data class InteractiveVideoPolicy(
    val preserveResolution: Boolean,
    val motionPriority: Boolean
) {
    companion object {
        @Suppress("UNUSED_PARAMETER")
        fun forState(
            tier: CaptureTier,
            interactionActive: Boolean
        ): InteractiveVideoPolicy =
            if (interactionActive) {
                InteractiveVideoPolicy(
                    preserveResolution = false,
                    motionPriority = true
                )
            } else {
                InteractiveVideoPolicy(
                    preserveResolution = true,
                    motionPriority = false
                )
            }
    }
}
