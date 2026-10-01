package com.aaris.remoteassist.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingCodeTest {
    @Test fun normalizesHumanFormatting() {
        assertEquals(
            "123456789012",
            PairingCode.normalize("1234 5678 9012")
        )
        assertEquals(
            "123456789012",
            PairingCode.normalize("1234-5678-9012")
        )
    }

    @Test fun rejectsWrongLength() {
        assertNull(PairingCode.normalize("12345678901"))
        assertNull(PairingCode.normalize("1234567890123"))
    }

    @Test
    fun extractsUniqueCodeFromWholeShareMessage() {
        val message =
            "Aaris Remote code: 123456789012\n" +
                "Tap to join: aarisremote://connect?code=123456789012"

        assertEquals("123456789012", PairingCode.extract(message))
    }

    @Test
    fun extractsHumanFormattedEmbeddedCode() {
        assertEquals(
            "654321098765",
            PairingCode.extract(
                "Friend code is 6543 2109 8765. Tap START."
            )
        )
    }

    @Test
    fun rejectsAmbiguousClipboardText() {
        assertNull(
            PairingCode.extract(
                "Old 123456789012, new 654321098765"
            )
        )
    }

    @Test
    fun displaysThreeReadableGroups() {
        assertEquals(
            "1234 5678 9012",
            PairingCode.display("123456789012")
        )
    }

    @Test
    fun parsesCanonicalAndNormalizedJoinLinks() {
        assertEquals(
            "123456789012",
            PairingLink.parse(
                "aarisremote://connect?code=123456789012"
            )
        )
        assertEquals(
            "123456789012",
            PairingLink.parse(
                "AARISREMOTE://CONNECT/?source=share&code=1234%205678%209012"
            )
        )
    }

    @Test
    fun rejectsJoinLinksForWrongDestination() {
        assertNull(
            PairingLink.parse(
                "https://connect?code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://other?code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect/unsafe?code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=abc123456789012xyz"
            )
        )
    }

    @Test
    fun rejectsAmbiguousOrUnexpectedJoinLinkAuthority() {
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=123456789012&code=654321098765"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=123456789012&code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect:443?code=123456789012"
            )
        )
        assertNull(
            PairingLink.parse(
                "aarisremote://connect?code=123456789012#unexpected"
            )
        )
    }

    @Test
    fun shareTextIsReadableAndClipboardRecoverable() {
        val message = PairingShareText.build("123456789012")

        assertEquals(
            "123456789012",
            PairingCode.extract(message)
        )
        org.junit.Assert.assertTrue(
            message.contains("1234 5678 9012")
        )
        org.junit.Assert.assertTrue(
            message.contains(
                "aarisremote://connect?code=123456789012"
            )
        )
    }
}
