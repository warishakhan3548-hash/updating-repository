package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class SignalingSequenceTrackerTest {
    @Test
    fun outOfOrderEventsDoNotAdvanceReconnectCursorPastGap() {
        val tracker = SignalingSequenceTracker()

        assertTrue(tracker.accept(2L))
        assertEquals(0L, tracker.reconnectAfter())

        assertTrue(tracker.accept(1L))
        assertEquals(2L, tracker.reconnectAfter())
    }

    @Test
    fun duplicateEventIsIgnored() {
        val tracker = SignalingSequenceTracker()

        assertTrue(tracker.accept(1L))
        assertFalse(tracker.accept(1L))
        assertEquals(1L, tracker.reconnectAfter())
    }

    @Test
    fun laterEventsCanArriveBeforeSeveralMissingEvents() {
        val tracker = SignalingSequenceTracker()

        assertTrue(tracker.accept(4L))
        assertTrue(tracker.accept(2L))
        assertEquals(0L, tracker.reconnectAfter())

        assertTrue(tracker.accept(1L))
        assertEquals(2L, tracker.reconnectAfter())

        assertTrue(tracker.accept(3L))
        assertEquals(4L, tracker.reconnectAfter())
    }
}
