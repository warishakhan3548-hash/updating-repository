package com.aaris.remoteassist.ui

internal object ControllerViewerLaunchPolicy {
    fun shouldLaunch(
        backendState: String,
        alreadyLaunching: Boolean
    ): Boolean =
        !alreadyLaunching &&
            (
                backendState == "SCREEN_READY" ||
                    backendState == "LIVE"
                )
}
