package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class PeerConnectivityTrackerTest {
    @Test
    fun initialDisconnectIsIgnoredUntilPeerWasConnected() {
        val tracker = PeerConnectivityTracker()

        assertFalse(tracker.onDisconnected())
        assertFalse(tracker.hasEverConnected())
        assertTrue(tracker.onConnected())
        assertTrue(tracker.hasEverConnected())
    }

    @Test
    fun duplicateConnectivitySignalsAreDeduplicated() {
        val tracker = PeerConnectivityTracker()

        assertTrue(tracker.onConnected())
        assertFalse(tracker.onConnected())
        assertTrue(tracker.onDisconnected())
        assertFalse(tracker.onDisconnected())
        assertTrue(tracker.onConnected())
    }
}
