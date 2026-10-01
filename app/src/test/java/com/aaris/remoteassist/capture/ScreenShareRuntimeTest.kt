package com.aaris.remoteassist.capture

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.After
import org.junit.Test

class ScreenShareRuntimeTest {
    @After
    fun tearDown() {
        ScreenShareRuntime.clear()
    }

    @Test
    fun onlyActiveHostSessionMatches() {
        ScreenShareRuntime.activate("host-session")

        assertTrue(ScreenShareRuntime.isActive("host-session"))
        assertFalse(ScreenShareRuntime.isActive("controller-session"))
        assertEquals(
            "host-session",
            ScreenShareRuntime.currentSessionId()
        )
    }

    @Test
    fun staleSessionCannotClearNewHostSession() {
        ScreenShareRuntime.activate("old")
        ScreenShareRuntime.activate("new")

        ScreenShareRuntime.clear("old")

        assertTrue(ScreenShareRuntime.isActive("new"))
        ScreenShareRuntime.clear("new")
        assertNull(ScreenShareRuntime.currentSessionId())
    }
}
