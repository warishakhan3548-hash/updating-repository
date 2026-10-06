package com.aaris.remoteassist.webrtc

import com.aaris.remoteassist.capture.CaptureTier

/**
 * Remote control must permit native resolution adaptation before the first
 * touch and even when a stalled encoder cannot prove passive motion yet.
 * Clarity recovery belongs to the pixel budget, not a competing switch back
 * to MAINTAIN_RESOLUTION. A static producer still emits few/no frames.
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
        ): InteractiveVideoPolicy {
            return InteractiveVideoPolicy(preserveResolution = false, motionPriority = true)
        }
    }
}
