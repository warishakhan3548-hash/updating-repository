package com.aaris.remoteassist.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ControllerViewerLaunchPolicyTest {
    @Test
    fun viewerWaitsUntilTransportIsLive() {
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "PAIR_PENDING",
                alreadyLaunching = false
            )
        )
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "HOST_APPROVED",
                alreadyLaunching = false
            )
        )
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "SCREEN_READY",
                alreadyLaunching = false
            )
        )
        assertTrue(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "LIVE",
                alreadyLaunching = false
            )
        )
    }

    @Test
    fun viewerNeverDoubleLaunches() {
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "LIVE",
                alreadyLaunching = true
            )
        )
    }
}
