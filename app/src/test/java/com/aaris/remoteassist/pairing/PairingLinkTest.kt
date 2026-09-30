package com.aaris.remoteassist.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingLinkTest {
    @Test
    fun buildsCanonicalJoinLink() {
        assertEquals(
            "aarisremote://connect?code=123456",
            PairingLink.uri("123 456")
        )
    }

    @Test
    fun parsesCanonicalJoinLink() {
        assertEquals(
            "123456",
            PairingLink.parse(
                "aarisremote://connect?code=123456"
            )
        )
    }

    @Test
    fun acceptsExtraQueryParameters() {
        assertEquals(
            "654321",
            PairingLink.parse(
                "aarisremote://connect?source=share&code=654321"
            )
        )
    }

    @Test
    fun rejectsWrongSchemeOrInvalidCode() {
        assertNull(
            PairingLink.parse(
                "https://example.com/connect?code=123456"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=12345"
            )
        )
    }
}
