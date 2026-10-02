package com.aaris.remoteassist.ui

/**
 * The foreground ControllerConnectionService owns pairing/signaling/WebRTC.
 * The heavy remote-view Activity is presentation only and should open after
 * transport reaches LIVE, never as a prerequisite for establishing it.
 */
internal object ControllerViewerLaunchPolicy {
    fun shouldLaunch(
        backendState: String,
        alreadyLaunching: Boolean
    ): Boolean =
        !alreadyLaunching &&
            backendState == "LIVE"
}
