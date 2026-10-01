package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class ControlTransportTrackerTest {
    @Test
    fun peerThenChannelReportsReadyOnlyAfterBoth() {
        val tracker = ControlTransportTracker()

        assertNull(tracker.onPeerConnected())
        assertEquals(true, tracker.onControlChannelOpen())
    }

    @Test
    fun channelThenPeerReportsReadyOnlyAfterBoth() {
        val tracker = ControlTransportTracker()

        assertNull(tracker.onControlChannelOpen())
        assertEquals(true, tracker.onPeerConnected())
    }

    @Test
    fun losingEitherPlaneReportsNotReadyOnce() {
        val tracker = ControlTransportTracker()

        tracker.onPeerConnected()
        tracker.onControlChannelOpen()

        assertEquals(false, tracker.onControlChannelClosed())
        assertNull(tracker.onControlChannelClosed())
        assertNull(tracker.onControlChannelOpen())
        assertEquals(true, tracker.onPeerConnected())
    }

    @Test
    fun peerDropAndRecoveryNeedsBothPlanesAgain() {
        val tracker = ControlTransportTracker()

        tracker.onPeerConnected()
        tracker.onControlChannelOpen()

        assertEquals(false, tracker.onPeerDisconnected())
        assertNull(tracker.onPeerConnected())
        assertEquals(true, tracker.onControlChannelOpen())
    }
}
