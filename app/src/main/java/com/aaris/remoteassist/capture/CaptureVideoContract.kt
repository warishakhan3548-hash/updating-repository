package com.aaris.remoteassist.capture

/**
 * Cross-pipeline invariants shared by primary RTP capture and compatibility
 * video recovery.
 *
 * Keep hard media limits here instead of duplicating magic numbers across the
 * capture and WebRTC packages. A primary profile that exceeds the fallback
 * decoder/encoder envelope can turn a recoverable black-screen event into a
 * permanent blank controller, so the compiler-visible contract is deliberate.
 */
internal object CaptureVideoContract {
    const val MAX_FALLBACK_SAFE_LONG_SIDE_PX = 2560

    /*
     * Compatibility recovery must remain legible when primary RTP is unhealthy.
     * Keep the same product readability contract as the primary video ladder:
     * pressure may spend fallback cadence, but must not shrink the visible
     * screen below a 360 px short edge.
     */
    const val MIN_FALLBACK_READABLE_SHORT_SIDE_PX = 360
}
