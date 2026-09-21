package com.aaris.shield.network

import org.junit.Assert.assertEquals
import org.junit.Test

class DomainPolicyTest {
    @Test
    fun exactAndSubdomainMatchesAreBlockedWithoutSubstringFalsePositive() {
        val policy = DomainPolicy.fromLines(sequenceOf("blocked.example"), emptySequence())
        assertEquals(DomainDecision.BLOCK, policy.decide("blocked.example"))
        assertEquals(DomainDecision.BLOCK, policy.decide("cdn.blocked.example."))
        assertEquals(DomainDecision.ALLOW, policy.decide("notblocked.example"))
    }

    @Test
    fun allowlistWinsOverParentDenyRule() {
        val policy = DomainPolicy.fromLines(
            sequenceOf("blocked.example"),
            sequenceOf("medical.blocked.example"),
        )
        assertEquals(DomainDecision.ALLOW, policy.decide("medical.blocked.example"))
        assertEquals(DomainDecision.ALLOW, policy.decide("images.medical.blocked.example"))
    }

    @Test
    fun hostsAndAdblockStyleLinesAreNormalized() {
        val policy = DomainPolicy.fromLines(
            sequenceOf("0.0.0.0 hosts.example", "||filter.example^", "*.wild.example"),
            emptySequence(),
        )
        assertEquals(DomainDecision.BLOCK, policy.decide("hosts.example"))
        assertEquals(DomainDecision.BLOCK, policy.decide("filter.example"))
        assertEquals(DomainDecision.BLOCK, policy.decide("a.wild.example"))
    }
}
