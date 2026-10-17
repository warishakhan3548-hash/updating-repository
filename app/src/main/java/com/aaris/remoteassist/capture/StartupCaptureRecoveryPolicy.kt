package com.aaris.remoteassist.capture

/**
 * Decides whether a first-frame watchdog may rebind the existing projection
 * surface without consuming another Android MediaProjection grant.
 *
 * WebRTC's ScreenCapturerAndroid resizes/rebinds its current VirtualDisplay on
 * Android 12+, but recreates the VirtualDisplay on older releases. A repeated
 * same-format update on older devices risks breaking a valid projection.
 *
 * A producer callback also means the projection itself is alive: failure to
 * display that frame must be diagnosed downstream (VideoSource/codec/RTP/EGL),
 * not by repeatedly resetting a healthy capture surface.
 */
internal object StartupCaptureRecoveryPolicy {
    private const val SAFE_SURFACE_REBIND_API = 31 // Android 12 (S)

    fun shouldRebindVirtualDisplay(
        sdkInt: Int,
        started: Boolean,
        closed: Boolean,
        producerFrameSeen: Boolean
    ): Boolean =
        sdkInt >= SAFE_SURFACE_REBIND_API &&
            started &&
            !closed &&
            !producerFrameSeen
}
