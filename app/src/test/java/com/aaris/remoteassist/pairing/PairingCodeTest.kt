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
}
