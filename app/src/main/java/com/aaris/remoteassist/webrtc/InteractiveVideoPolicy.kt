package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier

/**
 * Chooses the sender degradation strategy for screen content.
 *
 * Screen sharing has different priorities from camera video: text must remain
 * readable while idle, but interaction must not turn into a slideshow. The
 * all capture tiers therefore use MAINTAIN_FRAMERATE during active
 * interaction. STANDARD/HIGH temporarily raise capture cadence as well; if the
 * encoder or network cannot sustain that burst, WebRTC may trade resolution for
 * fresh frames while the slower quality governor remains the safety backstop.
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
                        motionPriority = true
                    )
            }
        }
    }
}
