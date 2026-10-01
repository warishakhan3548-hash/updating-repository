package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class RemoteCandidateBufferTest {
    @Test
    fun candidateWaitsUntilMatchingDescriptionIsReady() {
        val buffer = RemoteCandidateBuffer<String>(8)

        assertNull(buffer.offer("n1", "c1"))
        buffer.beginRemoteDescription("n1")
        assertEquals(
            listOf("c1"),
            buffer.markDescriptionReady()
        )
        assertEquals(
            "c2",
            buffer.offer("n1", "c2")
        )
    }

    @Test
    fun staleCandidatesAreDroppedWhenNewDescriptionBegins() {
        val buffer = RemoteCandidateBuffer<String>(8)

        assertNull(buffer.offer("old", "stale"))
        buffer.beginRemoteDescription("new")

        assertEquals(
            emptyList<String>(),
            buffer.markDescriptionReady()
        )
        assertNull(buffer.offer("old", "late-old"))
        assertEquals(
            "fresh",
            buffer.offer("new", "fresh")
        )
    }

    @Test
    fun futureCandidateCanArriveBeforeFutureDescription() {
        val buffer = RemoteCandidateBuffer<String>(8)

        buffer.beginRemoteDescription("n1")
        buffer.markDescriptionReady()

        assertNull(buffer.offer("n2", "future"))
        buffer.beginRemoteDescription("n2")

        assertEquals(
            listOf("future"),
            buffer.markDescriptionReady()
        )
    }

    @Test
    fun pendingMemoryIsBounded() {
        val buffer = RemoteCandidateBuffer<String>(2)

        assertNull(buffer.offer("n1", "c1"))
        assertNull(buffer.offer("n1", "c2"))
        assertNull(buffer.offer("n1", "c3"))

        buffer.beginRemoteDescription("n1")
        assertEquals(
            listOf("c2", "c3"),
            buffer.markDescriptionReady()
        )
    }
}
