package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class CandidatePublishGateTest {
    @Test
    fun buffersCandidatesUntilDescriptionIsPublished() {
        val gate = CandidatePublishGate<String>(4)
        val epoch = gate.beginNegotiation()

        assertNull(gate.offer("c1"))
        assertNull(gate.offer("c2"))
        assertEquals(
            listOf("c1", "c2"),
            gate.markDescriptionPublished(epoch)
        )
        assertEquals("c3", gate.offer("c3"))
    }

    @Test
    fun staleDescriptionCompletionCannotOpenNewNegotiation() {
        val gate = CandidatePublishGate<String>(4)
        val oldEpoch = gate.beginNegotiation()
        assertNull(gate.offer("old"))

        val newEpoch = gate.beginNegotiation()
        assertNull(gate.offer("new"))

        assertEquals(
            emptyList<String>(),
            gate.markDescriptionPublished(oldEpoch)
        )
        assertNull(gate.offer("still-buffered"))
        assertEquals(
            listOf("new", "still-buffered"),
            gate.markDescriptionPublished(newEpoch)
        )
    }

    @Test
    fun boundsPendingCandidateMemory() {
        val gate = CandidatePublishGate<String>(2)
        val epoch = gate.beginNegotiation()

        gate.offer("c1")
        gate.offer("c2")
        gate.offer("c3")

        assertEquals(
            listOf("c2", "c3"),
            gate.markDescriptionPublished(epoch)
        )
    }
}
