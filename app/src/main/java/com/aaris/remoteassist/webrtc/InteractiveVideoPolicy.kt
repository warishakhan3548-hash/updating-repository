package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier

/**
 * Chooses the sender degradation strategy for screen content.
 *
 * Screen sharing has different priorities from camera video: text must remain
 * readable while idle, but interaction must not turn into a slideshow. The
 * strongest capture tiers therefore use WebRTC's BALANCED strategy during
 * motion instead of forcing MAINTAIN_FRAMERATE (which can create an abrupt
 * resolution/clarity cliff). Constrained tiers still favor frame freshness
 * because their capture resolution is already intentionally bounded.
 */
data class InteractiveVideoPolicy(
    val preserveResolution: Boolean,
    val motionPriority: Boolean
) {
    companion object {
        fun forState(
            tier: CaptureTier,
            interactionActive: Boolean
        ): InteractiveVideoPolicy {
            if (!interactionActive) {
                return InteractiveVideoPolicy(
                    preserveResolution =
                        tier == CaptureTier.STANDARD ||
                            tier == CaptureTier.HIGH,
                    motionPriority = false
                )
            }

            return when (tier) {
                CaptureTier.LOW,
                CaptureTier.BALANCED ->
                    InteractiveVideoPolicy(
                        preserveResolution = false,
                        motionPriority = true
                    )

                CaptureTier.STANDARD,
                CaptureTier.HIGH ->
                    InteractiveVideoPolicy(
                        preserveResolution = false,
                        motionPriority = false
                    )
            }
        }
    }
}
