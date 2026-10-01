package com.aaris.remoteassist.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingLinkTest {
    @Test
    fun buildsCanonicalJoinLink() {
        assertEquals(
            "aarisremote://connect?code=123456789012",
            PairingLink.uri("1234 5678 9012")
        )
    }

    @Test
    fun parsesCanonicalJoinLink() {
        assertEquals(
            "123456789012",
            PairingLink.parse(
                "aarisremote://connect?code=123456789012"
            )
        )
    }

    @Test
    fun acceptsExtraQueryParameters() {
        assertEquals(
            "654321098765",
            PairingLink.parse(
                "aarisremote://connect?source=share&code=654321098765"
            )
        )
    }

    @Test
    fun rejectsWrongSchemeOrInvalidCode() {
        assertNull(
            PairingLink.parse(
                "https://example.com/connect?code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=12345678901"
            )
        )
    }
}
