package com.aaris.remoteassist.ui

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ControllerViewerLaunchPolicyTest {
    @Test
    fun waitsOnlyDuringPairing() {
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "PAIR_PENDING",
                alreadyLaunching = false
            )
        )
    }

    @Test
    fun launchesAsSoonAsHostApproves() {
        assertTrue(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "HOST_APPROVED",
                alreadyLaunching = false
            )
        )
        assertTrue(
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
    fun neverDoubleLaunchesViewer() {
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "HOST_APPROVED",
                alreadyLaunching = true
            )
        )
        assertFalse(
            ControllerViewerLaunchPolicy.shouldLaunch(
                "SCREEN_READY",
                alreadyLaunching = true
            )
        )
    }
}
