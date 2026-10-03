package com.aaris.remoteassist.webrtc

import org.junit.Assert.*
import org.junit.Test

class FallbackClarityPolicyTest {
    @Test fun refinesOnceAfterSettlingAndOnlyWithAvailableBandwidth() {
        val policy = FallbackClarityPolicy()
        policy.changed(100)
        assertFalse(policy.shouldRefine(200, false, false))
        assertFalse(policy.shouldRefine(500, true, false))
        assertFalse(policy.shouldRefine(500, false, true))
        assertTrue(policy.shouldRefine(500, false, false))
        policy.sentRefinement()
        assertFalse(policy.shouldRefine(2000, false, false))
        policy.changed(2100)
        assertTrue(policy.shouldRefine(2500, false, false))
    }
}
