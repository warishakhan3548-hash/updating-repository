package com.aaris.remoteassist.ui

/**
 * Open the controller viewer as soon as the host explicitly approves.
 *
 * Waiting until SCREEN_READY created a real-device race: the controller user
 * could background the app while the host was accepting MediaProjection. The
 * host would then publish its SDP offer while no controller viewer/WebRTC
 * owner was alive. Opening at HOST_APPROVED keeps the lightweight viewer in
 * foreground; WebRTC itself still waits for authoritative SCREEN_READY.
 */
internal object ControllerViewerLaunchPolicy {
    fun shouldLaunch(
        backendState: String,
        alreadyLaunching: Boolean
    ): Boolean =
        !alreadyLaunching &&
            (
                backendState == "HOST_APPROVED" ||
                    backendState == "SCREEN_READY" ||
                    backendState == "LIVE"
                )
}
