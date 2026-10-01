package com.aaris.remoteassist.pairing

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class PairingCodeTest {
    @Test fun normalizesHumanFormatting() {
        assertEquals("123456", PairingCode.normalize("123 456"))
        assertEquals("123456", PairingCode.normalize("123-456"))
    }

    @Test fun rejectsWrongLength() {
        assertNull(PairingCode.normalize("12345"))
        assertNull(PairingCode.normalize("1234567"))
    }

    @Test
    fun extractsUniqueCodeFromWholeShareMessage() {
        val message =
            "Aaris Remote code: 123456\n" +
                "Tap to join: aarisremote://connect?code=123456"

        assertEquals("123456", PairingCode.extract(message))
    }

    @Test
    fun extractsHumanFormattedEmbeddedCode() {
        assertEquals(
            "654321",
            PairingCode.extract("Friend code is 654 321. Tap START.")
        )
    }

    @Test
    fun rejectsAmbiguousClipboardText() {
        assertNull(
            PairingCode.extract(
                "Old code 123456, new code 654321"
            )
        )
    }
}
