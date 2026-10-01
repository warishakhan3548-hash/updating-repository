package com.aaris.remoteassist.webrtc

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class NegotiationOrderGuardTest {
    @Test
    fun rejectsDuplicateAndOlderEpochsFromSameClient() {
        val guard = NegotiationOrderGuard()

        assertTrue(guard.accept("client-a:2"))
        assertFalse(guard.accept("client-a:2"))
        assertTrue(
            guard.accept(
                "client-a:2",
                allowCurrentDuplicate = true
            )
        )
        assertFalse(
            guard.accept(
                "client-a:1",
                allowCurrentDuplicate = true
            )
        )
        assertTrue(guard.accept("client-a:3"))
    }

    @Test
    fun acceptsNewClientInstance() {
        val guard = NegotiationOrderGuard()

        assertTrue(guard.accept("client-a:9"))
        assertTrue(guard.accept("client-b:1"))
        assertFalse(guard.accept("client-b:1"))
    }

    @Test
    fun retiredClientCannotBecomeCurrentAgain() {
        val guard = NegotiationOrderGuard()

        assertTrue(guard.accept("client-a:9"))
        assertTrue(guard.accept("client-b:1"))
        assertFalse(guard.accept("client-a:10"))
        assertTrue(guard.accept("client-b:2"))
    }

    @Test
    fun malformedNegotiationIdsFailClosed() {
        val guard = NegotiationOrderGuard()

        assertFalse(guard.accept(""))
        assertFalse(guard.accept("client"))
        assertFalse(guard.accept("client:not-a-number"))
        assertFalse(
            guard.accept(
                "x".repeat(65) + ":1"
            )
        )
    }

    @Test
    fun legacyIsAllowedOnlyBeforeModernNegotiation() {
        val guard = NegotiationOrderGuard()

        assertTrue(guard.accept(LEGACY_NEGOTIATION_ID))
        assertTrue(guard.accept("client-a:1"))
        assertFalse(guard.accept(LEGACY_NEGOTIATION_ID))
    }
}
